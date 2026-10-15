#!/usr/bin/env bash
#
# Installe et démarre le géocodeur en une commande :
#   1. vérifie les prérequis (Docker, Compose v2, outils, RAM, disque)
#   2. construit les images Docker
#   3. télécharge ou met à jour les données de la Base Adresse Nationale
#   4. démarre le proxy et l'instance active (même si les données étaient déjà à jour)
#      et vérifie que le géocodeur répond
#   5. installe les tâches cron : mise à jour automatique des données, surveillance de /health
#
# Peut être relancé sans risque : seul ce qui manque est refait.
#
# Usage : ./install.sh [options]
#   --cron=daily     mise à jour tous les jours à 5h30 (défaut)
#   --cron=weekly    mise à jour tous les lundis à 5h30
#   --cron=none      pas de mise à jour automatique (retire la tâche si elle existe)
#   --watch=off      pas de surveillance de /health toutes les 5 minutes (défaut : on)
#   --discord-webhook=URL  envoie les alertes (pannes, échecs de mise à jour) sur ce salon Discord
#                          (enregistré dans alert.conf, non versionné)
#   -y, --yes        ne pose aucune question (pour les scripts)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRONTAB_CMD="${CRONTAB_CMD:-crontab}"
CRON_MARKER="# geocodeur-infostat : mise à jour des données BAN"
WATCH_MARKER="# geocodeur-infostat : surveillance /health"
MIN_RAM_GB="${MIN_RAM_GB:-6}"
MIN_DISK_GB="${MIN_DISK_GB:-15}"

CRON_MODE=daily
ASSUME_YES=0
WEBHOOK=""
WATCH=on
for arg in "$@"; do
  case "$arg" in
    --cron=daily|--cron=weekly|--cron=none) CRON_MODE="${arg#--cron=}" ;;
    --watch=on|--watch=off) WATCH="${arg#--watch=}" ;;
    --discord-webhook=https://*) WEBHOOK="${arg#--discord-webhook=}" ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Option inconnue : $arg (voir ./install.sh --help)" >&2; exit 2 ;;
  esac
done

step() { echo; echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    ATTENTION : $*" >&2; }
die()  { echo; echo "ERREUR : $*" >&2; exit 1; }
log()  { info "$*"; }

# shellcheck source=lib/instance.sh
source "$PROJECT_DIR/lib/instance.sh"

confirm() {
  [[ $ASSUME_YES -eq 1 || ! -t 0 ]] && return 0
  local answer
  read -r -p "    $1 [o/N] " answer
  [[ "$answer" =~ ^[oOyY]$ ]]
}

cd "$PROJECT_DIR"

if [[ -n "$WEBHOOK" ]]; then
  # Remplace le webhook en gardant les autres réglages d'alert.conf
  { grep -v '^DISCORD_WEBHOOK_URL=' alert.conf 2>/dev/null || grep -v '^DISCORD_WEBHOOK_URL=' alert.conf.example; } > alert.conf.tmp
  printf 'DISCORD_WEBHOOK_URL=%s\n' "$WEBHOOK" >> alert.conf.tmp
  chmod 600 alert.conf.tmp
  mv alert.conf.tmp alert.conf
  DISCORD_WEBHOOK_URL="$WEBHOOK"
fi

# --- 1. Prérequis ---
step "1/5 Vérification des prérequis"

for cmd in docker curl unzip flock; do
  command -v "$cmd" >/dev/null || die "commande « $cmd » introuvable, installez-la puis relancez"
done
docker compose version >/dev/null 2>&1 \
  || die "Docker Compose v2 introuvable (paquet docker-compose-plugin)"
docker info >/dev/null 2>&1 \
  || die "impossible d'utiliser Docker sans sudo. Ajoutez votre utilisateur au groupe docker : sudo usermod -aG docker $USER (puis reconnectez-vous)"
info "Docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short | sed 's/^/Compose /')"

avail_ram_gb=$(awk '/MemAvailable/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)
running=$(compose ps -q 2>/dev/null | wc -l)
if (( avail_ram_gb < MIN_RAM_GB && running == 0 )); then
  warn "${avail_ram_gb} Go de RAM disponibles, il en faut environ ${MIN_RAM_GB} pour charger les adresses de France."
  warn "Arrêtez d'autres conteneurs ou applications, sinon le chargement risque d'échouer."
  confirm "Continuer quand même ?" || die "installation annulée"
else
  info "RAM disponible : ${avail_ram_gb} Go"
fi

avail_disk_gb=$(df -Pk "$PROJECT_DIR" | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')
if [[ -z "$(active_slot)" && ! -d addok-data ]] && (( avail_disk_gb < MIN_DISK_GB )); then
  die "${avail_disk_gb} Go libres sur le disque, il en faut ${MIN_DISK_GB}"
fi
info "Disque disponible : ${avail_disk_gb} Go"

# --- 2. Images ---
step "2/5 Construction des images Docker"
# Sans attestation de provenance (horodatée) : une image inchangée garde le même identifiant,
# et Compose ne recrée pas les conteneurs (pas de coupure en relançant l'installeur)
BUILDX_NO_DEFAULT_ATTESTATIONS=1 compose --profile '*' build --quiet
info "Images prêtes"

# --- 3. Données ---
step "3/5 Données de la Base Adresse Nationale"
if ! "$PROJECT_DIR/update-data.sh"; then
  [[ -f addok-data/addok.db && -f addok-data/dump.rdb && -f addok-data/addok.conf ]] \
    || die "aucune donnée disponible (voir les messages ci-dessus)"
  warn "la mise à jour a échoué, on continue avec les données déjà installées"
fi

# --- 4. Démarrage ---
step "4/5 Démarrage de l'instance"
info "Attente de la première réponse (chargement en mémoire, 1 à 2 minutes si l'instance était arrêtée)..."
if ! ensure_running; then
  compose logs --tail=30 >&2 || true
  die "le géocodeur ne répond pas après ${START_TIMEOUT} secondes"
fi
info "Le géocodeur répond (instance $(active_slot))"

# --- 5. Cron ---
step "5/5 Tâches automatiques (cron)"

# set_cron_task <marqueur> <ligne cron, vide pour retirer la tâche>
# Chaque tâche est notée « marqueur + ligne suivante » : elle est remplacée, jamais dupliquée,
# et les autres tâches de l'utilisateur sont conservées. Code retour 1 si rien n'a changé.
set_cron_task() {
  local current others
  current="$($CRONTAB_CMD -l 2>/dev/null || true)"
  others="$(printf '%s\n' "$current" | awk -v m="$1" '$0 == m {skip=1; next} skip {skip=0; next} {print}')"
  if [[ -n "$2" ]]; then
    { [[ -n "$others" ]] && printf '%s\n' "$others"; printf '%s\n%s\n' "$1" "$2"; } | $CRONTAB_CMD -
  elif [[ "$current" == *"$1"* ]]; then
    { [[ -n "$others" ]] && printf '%s\n' "$others"; true; } | $CRONTAB_CMD -
  else
    return 1
  fi
}

case "$CRON_MODE" in
  daily)  schedule="30 5 * * *"; label="tous les jours à 5h30" ;;
  weekly) schedule="30 5 * * 1"; label="tous les lundis à 5h30" ;;
  none)   schedule="" ;;
esac

if ! command -v "${CRONTAB_CMD%% *}" >/dev/null; then
  warn "cron n'est pas installé : ni mise à jour automatique, ni surveillance (paquet cron)"
else
  if [[ -n "$schedule" ]]; then
    set_cron_task "$CRON_MARKER" "$schedule cd \"$PROJECT_DIR\" && ./update-data.sh >> \"$PROJECT_DIR/logs/update-data.log\" 2>&1"
    info "Mise à jour des données : $label (journal : logs/update-data.log)"
  elif set_cron_task "$CRON_MARKER" ""; then
    info "Tâche de mise à jour retirée"
  else
    info "Pas de mise à jour automatique"
  fi

  if [[ "$WATCH" == on ]]; then
    set_cron_task "$WATCH_MARKER" "*/5 * * * * cd \"$PROJECT_DIR\" && ./check-health.sh >> \"$PROJECT_DIR/logs/health.log\" 2>&1"
    info "Surveillance de /health : toutes les 5 minutes (journal : logs/health.log)"
    [[ -n "$DISCORD_WEBHOOK_URL" ]] || warn "aucun webhook Discord : les pannes seront seulement notées dans logs/health.log"
  elif set_cron_task "$WATCH_MARKER" ""; then
    info "Surveillance retirée"
  else
    info "Pas de surveillance"
  fi
fi

data_date="$(slot_date "$(active_slot)")"
if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then alerts="Discord (alert.conf), test : ./notify.sh --test"; else alerts="aucune (./install.sh --discord-webhook=URL)"; fi
cat <<EOF

Installation terminée.

  Géocodeur   : http://localhost:$ADDOK_PORT/search?q=1+rue+de+la+paix+paris
  Données BAN : ${data_date:-inconnue}
  Alertes     : $alerts

  Arrêter       : docker compose down
  Redémarrer    : ./install.sh   (ou docker compose up -d)
  Journaux      : docker compose logs -f
  Tests         : tests/smoke.sh
EOF
