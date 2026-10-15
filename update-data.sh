#!/usr/bin/env bash
#
# Met à jour les données pré-indexées de la Base Adresse Nationale utilisées par addok.
#
# - ne télécharge que si la BAN a publié un nouveau bundle (en-tête Last-Modified)
# - prépare les nouvelles données dans l'instance inactive (blue ou green) pendant que
#   l'instance active continue de répondre
# - sans coupure s'il y a assez de RAM pour faire tourner les deux instances : démarre la
#   nouvelle, bascule le proxy dès qu'elle répond, puis arrête l'ancienne
# - sinon, arrête l'ancienne avant de démarrer la nouvelle (coupure de 1 à 2 minutes)
# - en cas d'échec, l'ancienne instance reste (ou redevient) active
# - envoie une alerte Discord en cas d'échec (voir alert.conf.example)
#
# Usage : ./update-data.sh [--check] [--force]
#   --check  indique seulement si une mise à jour est disponible (code retour 10 si oui)
#   --force  met à jour même si les données locales semblent à jour
#
# Variables : HOT_SWAP=auto (défaut) | always | never, BUNDLE_URL, START_TIMEOUT (secondes)

set -euo pipefail

BUNDLE_URL="${BUNDLE_URL:-https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/addok-france-bundle.zip}"
HOT_SWAP="${HOT_SWAP:-auto}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIP_FILE="$PROJECT_DIR/addok-france-bundle.zip.part"

CHECK_ONLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done
case "$HOT_SWAP" in
  auto|always|never) ;;
  *) echo "HOT_SWAP doit valoir auto, always ou never" >&2; exit 2 ;;
esac

LAST_ERROR=""
log() { echo "[$(date '+%F %T')] $*"; }
die() { LAST_ERROR="$*"; log "ERREUR : $*" >&2; exit 1; }

# shellcheck source=lib/instance.sh
source "$PROJECT_DIR/lib/instance.sh"

TARGET_DIR=""
on_exit() {
  local rc=$?
  rm -f "$ZIP_FILE"
  # Données préparées mais jamais mises en service
  [[ -n "$TARGET_DIR" ]] && rm -rf "$TARGET_DIR"
  if (( rc != 0 && rc != 10 )); then
    notify "🔴 **Échec de la mise à jour des données BAN** sur \`$(hostname)\`
${LAST_ERROR:-erreur inattendue (code $rc)}
Détails : $PROJECT_DIR/logs/update-data.log" || true
  fi
}
trap on_exit EXIT

# Une seule exécution à la fois (cron + lancement manuel par exemple)
exec 9>"$PROJECT_DIR/.update-data.lock"
flock -n 9 || die "une mise à jour est déjà en cours"

migrate_legacy

# --- 1. Une nouvelle version est-elle disponible ? ---
headers="$(curl -sfIL --max-time 60 "$BUNDLE_URL")" || die "impossible de joindre $BUNDLE_URL"
remote_date="$(printf '%s\n' "$headers" | tr -d '\r' | grep -i '^last-modified:' | tail -n1 | cut -d' ' -f2- || true)"
remote_size="$(printf '%s\n' "$headers" | tr -d '\r' | grep -i '^content-length:' | tail -n1 | cut -d' ' -f2 || true)"
[[ -n "$remote_date" ]] || die "en-tête Last-Modified absent, impossible de savoir si les données ont changé"

active="$(active_slot)"
local_date=""
[[ -n "$active" ]] && local_date="$(slot_date "$active")"

log "Version BAN en ligne : $remote_date"
log "Version locale       : ${local_date:-aucune}"

if [[ "$remote_date" == "$local_date" && $FORCE -eq 0 ]]; then
  log "Les données sont déjà à jour."
  exit 0
fi
if [[ $CHECK_ONLY -eq 1 ]]; then
  log "Une mise à jour est disponible."
  exit 10
fi

# --- 2. Téléchargement et vérification, dans le dossier de l'instance inactive ---
if [[ -n "$active" ]]; then target="$(other_slot "$active")"; else target=blue; fi

if [[ -n "$remote_size" ]]; then
  # archive + données décompressées + marge
  needed_kb=$(( remote_size * 5 / 1024 ))
  avail_kb="$(df -Pk "$PROJECT_DIR" | awk 'NR==2 {print $4}')"
  (( avail_kb > needed_kb )) || die "espace disque insuffisant : $((avail_kb / 1024 / 1024)) Go libres, ~$((needed_kb / 1024 / 1024)) Go nécessaires"
fi

# Restes éventuels d'une mise à jour interrompue
stop_slot "$target"
TARGET_DIR="$(slot_dir "$target")"
rm -rf "$TARGET_DIR" "$ZIP_FILE"

log "Téléchargement du bundle..."
curl -fL --retry 3 --retry-delay 30 --silent --show-error -o "$ZIP_FILE" "$BUNDLE_URL" || die "échec du téléchargement"

if [[ -n "$remote_size" ]]; then
  actual_size="$(stat -c %s "$ZIP_FILE")"
  [[ "$actual_size" == "$remote_size" ]] || die "taille inattendue ($actual_size octets au lieu de $remote_size)"
fi

log "Vérification de l'archive..."
unzip -tqq "$ZIP_FILE" || die "archive corrompue"

log "Décompression..."
mkdir -p "$TARGET_DIR"
unzip -qq -d "$TARGET_DIR" "$ZIP_FILE"
slot_has_data "$target" || die "addok.conf, addok.db ou dump.rdb absent ou vide dans l'archive"
printf '%s\n' "$remote_date" > "$TARGET_DIR/$STAMP_NAME"
rm -f "$ZIP_FILE"

# --- 3. Mise en service ---
success() {
  [[ -n "$active" ]] && rm -rf "$(slot_dir "$active")"
  log "Mise à jour terminée : données BAN du $remote_date (instance $target, $1)."
  if [[ "$ALERT_ON_SUCCESS" == 1 ]]; then
    notify "🟢 Données BAN mises à jour sur \`$(hostname)\` : $remote_date ($1)" || true
  fi
  exit 0
}

reject_new_data() {
  log "L'instance $target ne répond pas correctement avec les nouvelles données."
  compose --profile "$target" logs --tail=30 "addok-$target" "redis-$target" >&2 || true
  stop_slot "$target"
}

# Sans coupure si l'instance active tourne et qu'il reste assez de RAM pour une 2e instance
hot=0
if [[ -n "$active" ]] && slot_running "$active"; then
  case "$HOT_SWAP" in
    always) hot=1 ;;
    never)  hot=0 ;;
    auto)
      if needed_kb="$(second_slot_needed_kb "$active")"; then
        avail_kb="$(mem_available_kb)"
        if (( avail_kb >= needed_kb )); then
          hot=1
        else
          log "RAM insuffisante pour faire tourner deux instances ($((avail_kb / 1024)) Mo disponibles, $((needed_kb / 1024)) Mo nécessaires) : mise à jour avec coupure"
        fi
      fi
      ;;
  esac
fi

if (( hot )); then
  log "Démarrage de l'instance $target avec les nouvelles données (l'instance $active continue de répondre)..."
  if start_slot "$target" && wait_slot_ready "$target"; then
    log "Bascule du proxy vers l'instance $target..."
    TARGET_DIR=""
    switch_to "$target"
    wait_proxy_ready 60 || log "ATTENTION : le proxy ne répond pas encore après la bascule"
    log "Arrêt de l'instance $active..."
    stop_slot "$active"
    success "sans coupure"
  fi
  reject_new_data
  die "nouvelles données rejetées, l'instance $active continue de répondre avec les données du ${local_date:-inconnu} (aucune coupure)"
fi

if [[ -n "$active" ]]; then
  log "Arrêt de l'instance $active pour libérer la mémoire (début de la coupure)..."
  stop_slot "$active"
fi
cut_start=$SECONDS
log "Démarrage de l'instance $target (chargement en mémoire, 1 à 2 minutes)..."
if start_slot "$target" && wait_slot_ready "$target"; then
  TARGET_DIR=""
  switch_to "$target"
  wait_proxy_ready 60 || log "ATTENTION : le proxy ne répond pas encore après la bascule"
  success "coupure de $(( SECONDS - cut_start )) secondes"
fi

reject_new_data
[[ -n "$active" ]] || die "les nouvelles données ne fonctionnent pas et il n'y a pas d'anciennes données à restaurer"
log "Redémarrage de l'instance $active avec les anciennes données..."
if start_slot "$active" && wait_slot_ready "$active"; then
  die "nouvelles données rejetées, l'instance $active tourne de nouveau avec les données du ${local_date:-inconnu}"
fi
die "nouvelles données rejetées, et l'instance $active ne répond pas non plus avec les anciennes données : LE GÉOCODEUR EST HORS SERVICE"
