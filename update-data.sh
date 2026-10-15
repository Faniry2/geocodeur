#!/usr/bin/env bash
#
# Met à jour les données pré-indexées de la Base Adresse Nationale utilisées par addok.
#
# - ne télécharge que si la BAN a publié un nouveau bundle (en-tête Last-Modified)
# - prépare les nouvelles données à côté pendant que l'instance actuelle continue de répondre
# - bascule, redémarre les conteneurs et vérifie qu'une recherche fonctionne
# - en cas d'échec, restaure les anciennes données automatiquement
#
# Usage : ./update-data.sh [--check] [--force]
#   --check  indique seulement si une mise à jour est disponible (code retour 10 si oui)
#   --force  met à jour même si les données locales semblent à jour

set -euo pipefail

BUNDLE_URL="${BUNDLE_URL:-https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/addok-france-bundle.zip}"
TEST_URL="${TEST_URL:-http://localhost:7878/search?q=1+rue+de+la+paix+paris}"
START_TIMEOUT="${START_TIMEOUT:-600}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$PROJECT_DIR/addok-data"
NEW_DIR="$PROJECT_DIR/addok-data.new"
OLD_DIR="$PROJECT_DIR/addok-data.old"
ZIP_FILE="$PROJECT_DIR/addok-france-bundle.zip.part"
STAMP_NAME=".bundle-last-modified"
REQUIRED_FILES=(addok.conf addok.db dump.rdb)

CHECK_ONLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERREUR : $*" >&2; exit 1; }

if [[ -n "${COMPOSE:-}" ]]; then
  read -r -a COMPOSE_CMD <<< "$COMPOSE"
elif docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
else
  COMPOSE_CMD=(docker-compose)
fi
# Les conteneurs tournent avec l'utilisateur de l'hôte (voir docker-compose.yml)
export HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}"
compose() { "${COMPOSE_CMD[@]}" -f "$PROJECT_DIR/docker-compose.yml" --project-directory "$PROJECT_DIR" "$@"; }

# Une seule exécution à la fois (cron + lancement manuel par exemple)
exec 9>"$PROJECT_DIR/.update-data.lock"
flock -n 9 || die "une mise à jour est déjà en cours"

# --- 1. Une nouvelle version est-elle disponible ? ---
headers="$(curl -sfIL --max-time 60 "$BUNDLE_URL")" || die "impossible de joindre $BUNDLE_URL"
remote_date="$(printf '%s\n' "$headers" | tr -d '\r' | grep -i '^last-modified:' | tail -n1 | cut -d' ' -f2- || true)"
remote_size="$(printf '%s\n' "$headers" | tr -d '\r' | grep -i '^content-length:' | tail -n1 | cut -d' ' -f2 || true)"
[[ -n "$remote_date" ]] || die "en-tête Last-Modified absent, impossible de savoir si les données ont changé"

local_date=""
[[ -f "$DATA_DIR/$STAMP_NAME" ]] && local_date="$(cat "$DATA_DIR/$STAMP_NAME")"

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

# --- 2. Téléchargement et vérification ---
if [[ -n "$remote_size" ]]; then
  # archive + données décompressées + marge
  needed_kb=$(( remote_size * 5 / 1024 ))
  avail_kb="$(df -Pk "$PROJECT_DIR" | awk 'NR==2 {print $4}')"
  (( avail_kb > needed_kb )) || die "espace disque insuffisant : $((avail_kb / 1024 / 1024)) Go libres, ~$((needed_kb / 1024 / 1024)) Go nécessaires"
fi

rm -rf "$NEW_DIR" "$ZIP_FILE"
trap 'rm -rf "$NEW_DIR" "$ZIP_FILE"' EXIT

log "Téléchargement du bundle..."
curl -fL --retry 3 --retry-delay 30 --silent --show-error -o "$ZIP_FILE" "$BUNDLE_URL" || die "échec du téléchargement"

if [[ -n "$remote_size" ]]; then
  actual_size="$(stat -c %s "$ZIP_FILE")"
  [[ "$actual_size" == "$remote_size" ]] || die "taille inattendue ($actual_size octets au lieu de $remote_size)"
fi

log "Vérification de l'archive..."
unzip -tqq "$ZIP_FILE" || die "archive corrompue"

log "Décompression..."
mkdir -p "$NEW_DIR"
unzip -qq -d "$NEW_DIR" "$ZIP_FILE"
for f in "${REQUIRED_FILES[@]}"; do
  [[ -s "$NEW_DIR/$f" ]] || die "fichier $f absent ou vide dans l'archive"
done
printf '%s\n' "$remote_date" > "$NEW_DIR/$STAMP_NAME"
rm -f "$ZIP_FILE"

# --- 3. Bascule et redémarrage ---
wait_until_ready() {
  local deadline=$(( SECONDS + START_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if curl -sf --max-time 10 "$TEST_URL" 2>/dev/null | grep -q '"features": *\[ *{'; then
      return 0
    fi
    sleep 5
  done
  return 1
}

restart() {
  mkdir -p "$PROJECT_DIR/logs"
  compose up -d --force-recreate
}

log "Bascule vers les nouvelles données..."
rm -rf "$OLD_DIR"
[[ -d "$DATA_DIR" ]] && mv "$DATA_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$DATA_DIR"
trap - EXIT

log "Redémarrage des conteneurs (chargement en mémoire, 1 à 2 minutes)..."
if restart && wait_until_ready; then
  rm -rf "$OLD_DIR"
  log "Mise à jour terminée : données BAN du $remote_date."
  exit 0
fi

log "L'instance ne répond pas correctement avec les nouvelles données."
compose logs --tail=30 >&2 || true
if [[ -d "$OLD_DIR" ]]; then
  log "Restauration des anciennes données..."
  rm -rf "$DATA_DIR"
  mv "$OLD_DIR" "$DATA_DIR"
  if restart && wait_until_ready; then
    die "mise à jour annulée, l'instance tourne avec les données du ${local_date:-inconnu}"
  fi
  die "mise à jour annulée, mais l'instance ne répond pas non plus avec les anciennes données"
fi
die "aucune ancienne donnée à restaurer"
