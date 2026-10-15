#!/usr/bin/env bash
#
# Surveille le géocodeur (lancé par cron toutes les 5 minutes, voir install.sh) :
# vérifie /health et une recherche à travers le proxy, et envoie une alerte Discord
# quand le géocodeur tombe en panne, puis quand il répond de nouveau.
#
# - 3 essais à 20 secondes d'intervalle avant de déclarer une panne (pas d'alerte pour un raté isolé)
# - une seule alerte par panne, avec un rappel toutes les HEALTH_REMIND_HOURS heures (6 par défaut)
# - ne vérifie rien pendant une mise à jour (update-data.sh envoie ses propres alertes)
# - n'écrit dans le journal (logs/health.log) que les changements d'état
#
# Usage : ./check-health.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_REMIND_HOURS="${HEALTH_REMIND_HOURS:-6}"
ATTEMPTS="${ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-20}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERREUR : $*" >&2; exit 1; }

# shellcheck source=lib/instance.sh
source "$PROJECT_DIR/lib/instance.sh"

STATE_FILE="$RUN_DIR/health-state"
HEALTH_URL="http://localhost:$ADDOK_PORT/health"

# Rien à surveiller tant qu'aucune instance n'est installée
[[ -n "$(active_slot)" ]] || exit 0
mkdir -p "$RUN_DIR"

# Une seule vérification à la fois
exec 8>"$RUN_DIR/.check-health.lock"
flock -n 8 || exit 0

# Mise à jour en cours : la coupure éventuelle est normale. Le verrou est relâché
# tout de suite pour ne pas bloquer update-data.sh.
exec 7>"$PROJECT_DIR/.update-data.lock"
if ! flock -n 7; then exit 0; fi
flock -u 7
exec 7>&-

# Renvoie 0 si tout va bien, sinon affiche la cause
check_once() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" 2>/dev/null || true)"
  case "$code" in
    200) ;;
    000) echo "le géocodeur ne répond pas sur le port $ADDOK_PORT (proxy arrêté ?)"; return 1 ;;
    502|504) echo "le proxy répond mais pas l'instance addok (code $code)"; return 1 ;;
    *) echo "/health renvoie le code $code"; return 1 ;;
  esac
  curl -sf --max-time 10 "$TEST_URL" 2>/dev/null | grep -q '"features": *\[ *{' \
    || { echo "/health répond mais la recherche de test ne renvoie aucune adresse"; return 1; }
}

failure=""
for (( i = 1; i <= ATTEMPTS; i++ )); do
  if failure="$(check_once)"; then failure=""; break; fi
  (( i < ATTEMPTS )) && sleep "$RETRY_DELAY"
done

read -r state since last_alert 2>/dev/null < "$STATE_FILE" || true
state="${state:-ok}"
now="$(date +%s)"
host="$(hostname)"

duration() {
  local s=$(( now - $1 ))
  if (( s >= 3600 )); then echo "$(( s / 3600 )) h $(( s % 3600 / 60 )) min"; else echo "$(( s / 60 )) min"; fi
}

if [[ -z "$failure" ]]; then
  if [[ "$state" == down ]]; then
    log "Le géocodeur répond de nouveau (panne de $(duration "$since"))"
    notify "🟢 **Le géocodeur répond de nouveau** sur \`$host\` (panne d'environ $(duration "$since"))" || true
  fi
  echo ok > "$STATE_FILE"
  exit 0
fi

containers="$(compose ps -a --format '{{.Service}} : {{.Status}}' 2>/dev/null || true)"
if [[ "$state" != down ]]; then
  log "PANNE : $failure"
  [[ -n "$containers" ]] && printf '%s\n' "$containers"
  notify "🔴 **Le géocodeur ne répond plus** sur \`$host\`
$failure
Conteneurs :
\`\`\`
${containers:-aucun conteneur}
\`\`\`
Journaux : \`docker compose logs --tail=50\`" || true
  echo "down $now $now" > "$STATE_FILE"
elif (( now - ${last_alert:-0} >= HEALTH_REMIND_HOURS * 3600 )); then
  log "Toujours en panne depuis $(duration "$since") : $failure"
  notify "🔴 Le géocodeur est **toujours en panne** sur \`$host\`, depuis $(duration "$since")
$failure" || true
  echo "down $since $now" > "$STATE_FILE"
fi
exit 1
