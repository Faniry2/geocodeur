# Fonctions communes à install.sh et update-data.sh (à sourcer après avoir défini PROJECT_DIR) :
# - instances « blue » et « green » derrière le proxy (voir docker-compose.yml) ;
# - alertes Discord (voir alert.conf.example).
#
# Les scripts qui sourcent ce fichier doivent définir log() et die().

ENV_FILE="$PROJECT_DIR/.env"
RUN_DIR="$PROJECT_DIR/run"
ALERT_CONF="$PROJECT_DIR/alert.conf"
STAMP_NAME=".bundle-last-modified"

# Lit une variable dans .env (vide si absente)
env_get() { [[ -f "$ENV_FILE" ]] || return 0; sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }

# Écrit (ou remplace) une variable dans .env, sans toucher aux autres lignes
env_set() {
  local others
  others="$(grep -v "^$1=" "$ENV_FILE" 2>/dev/null || true)"
  { [[ -n "$others" ]] && printf '%s\n' "$others"; printf '%s=%s\n' "$1" "$2"; } > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
}

ADDOK_PORT="${ADDOK_PORT:-$(env_get ADDOK_PORT)}"
ADDOK_PORT="${ADDOK_PORT:-7878}"
TEST_QUERY="search?q=1+rue+de+la+paix+paris"
TEST_URL="${TEST_URL:-http://localhost:$ADDOK_PORT/$TEST_QUERY}"
START_TIMEOUT="${START_TIMEOUT:-600}"

if [[ -n "${COMPOSE:-}" ]]; then
  read -r -a COMPOSE_CMD <<< "$COMPOSE"
else
  COMPOSE_CMD=(docker compose)
fi
# Les conteneurs tournent avec l'utilisateur de l'hôte (voir docker-compose.yml)
export HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}"
compose() { "${COMPOSE_CMD[@]}" -f "$PROJECT_DIR/docker-compose.yml" --project-directory "$PROJECT_DIR" "$@"; }

# --- Instances blue / green ---

slot_dir() { echo "$PROJECT_DIR/addok-data-$1"; }
other_slot() { if [[ "$1" == blue ]]; then echo green; else echo blue; fi; }

# Instance active (vide si aucune n'a encore été installée)
active_slot() {
  local slot
  slot="$(env_get COMPOSE_PROFILES)"
  [[ "$slot" == blue || "$slot" == green ]] && echo "$slot"
  return 0
}

slot_has_data() {
  local f
  for f in addok.conf addok.db dump.rdb; do
    [[ -s "$(slot_dir "$1")/$f" ]] || return 1
  done
}

# Date des données BAN d'une instance (vide si inconnue)
slot_date() { cat "$(slot_dir "$1")/$STAMP_NAME" 2>/dev/null || true; }

slot_running() {
  [[ -n "$(compose --profile "$1" ps -q --status running "addok-$1" 2>/dev/null)" ]]
}

start_slot() {
  mkdir -p "$PROJECT_DIR/logs" "$RUN_DIR"
  compose --profile "$1" up -d "redis-$1" "addok-$1"
}

# Arrêt propre : gunicorn termine les requêtes en cours (jusqu'à 30 secondes)
stop_slot() {
  compose --profile "$1" stop -t 30 "addok-$1" "redis-$1" >/dev/null 2>&1 || true
  compose --profile "$1" rm -f "addok-$1" "redis-$1" >/dev/null 2>&1 || true
}

# Attend qu'une instance réponde à une recherche, en l'interrogeant directement (sans le proxy)
wait_slot_ready() {
  local deadline=$(( SECONDS + START_TIMEOUT ))
  local check="import json, sys, urllib.request
r = json.load(urllib.request.urlopen('http://localhost:7878/$TEST_QUERY', timeout=10))
sys.exit(0 if r['features'] else 1)"
  while (( SECONDS < deadline )); do
    compose --profile "$1" exec -T "addok-$1" python -c "$check" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

# Attend que le géocodeur réponde à une recherche à travers le proxy
wait_proxy_ready() {
  local deadline=$(( SECONDS + ${1:-$START_TIMEOUT} ))
  while (( SECONDS < deadline )); do
    curl -sf --max-time 10 "$TEST_URL" 2>/dev/null | grep -q '"features": *\[ *{' && return 0
    sleep 2
  done
  return 1
}

# Fait de <slot> l'instance active : proxy, .env (profil Compose) et lien addok-data
switch_to() {
  mkdir -p "$RUN_DIR"
  printf 'set $addok_upstream addok-%s;\n' "$1" > "$RUN_DIR/active.conf.tmp"
  mv "$RUN_DIR/active.conf.tmp" "$RUN_DIR/active.conf"
  env_set COMPOSE_PROFILES "$1"
  ln -sfn "addok-data-$1" "$PROJECT_DIR/addok-data"
  if [[ -n "$(compose ps -q --status running proxy 2>/dev/null)" ]]; then
    compose exec -T proxy nginx -s reload >/dev/null 2>&1
  else
    compose up -d proxy
  fi
}

# Mémoire nécessaire pour démarrer une 2e instance pendant que <slot> tourne : la mémoire
# de son Redis + 30 % (les nouvelles données peuvent être plus grosses) + 512 Mo de marge
second_slot_needed_kb() {
  local used
  used="$(compose --profile "$1" exec -T "redis-$1" redis-cli info memory 2>/dev/null \
    | tr -d '\r' | sed -n 's/^used_memory://p')"
  [[ -n "$used" ]] || return 1
  echo $(( used / 1024 * 13 / 10 + 512 * 1024 ))
}

mem_available_kb() { awk '/MemAvailable/ {print $2}' /proc/meminfo; }

# Passage de l'ancienne organisation (un seul dossier addok-data/, services addok et redis)
# à l'architecture bleu/vert. Ne fait rien si c'est déjà fait.
migrate_legacy() {
  if [[ -d "$PROJECT_DIR/addok-data" && ! -L "$PROJECT_DIR/addok-data" ]]; then
    [[ -e "$(slot_dir blue)" ]] && die "addok-data/ et addok-data-blue/ existent tous les deux, impossible de migrer"
    log "Migration vers l'architecture bleu/vert : addok-data/ devient addok-data-blue/"
    mv "$PROJECT_DIR/addok-data" "$(slot_dir blue)"
    mkdir -p "$RUN_DIR"
    printf 'set $addok_upstream addok-blue;\n' > "$RUN_DIR/active.conf"
    env_set COMPOSE_PROFILES blue
    ln -sfn addok-data-blue "$PROJECT_DIR/addok-data"
  fi
  rm -rf "$PROJECT_DIR/addok-data.new" "$PROJECT_DIR/addok-data.old"

  # Anciens conteneurs addok et redis : ils occupent le port 7878 du proxy
  local project old
  project="${COMPOSE_PROJECT_NAME:-geocodeur-infostat}"
  old="$(docker ps -aq --filter "label=com.docker.compose.project=$project" \
    --filter label=com.docker.compose.service=addok)
$(docker ps -aq --filter "label=com.docker.compose.project=$project" \
    --filter label=com.docker.compose.service=redis)"
  old="$(echo $old)"
  if [[ -n "$old" ]]; then
    log "Arrêt des conteneurs de l'ancienne organisation (coupure le temps du redémarrage)"
    # shellcheck disable=SC2086
    docker rm -f $old >/dev/null
  fi
}

# Démarre le proxy et l'instance active si besoin, puis attend qu'ils répondent
ensure_running() {
  migrate_legacy
  local slot
  slot="$(active_slot)"
  [[ -n "$slot" ]] || die "aucune instance installée (lancez ./update-data.sh)"
  slot_has_data "$slot" || die "données manquantes dans $(slot_dir "$slot")"
  [[ -f "$RUN_DIR/active.conf" ]] || switch_to "$slot"
  mkdir -p "$PROJECT_DIR/logs" "$RUN_DIR"
  compose up -d
  wait_proxy_ready
}

# --- Alertes Discord ---

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
ALERT_ON_SUCCESS="${ALERT_ON_SUCCESS:-}"
if [[ -f "$ALERT_CONF" ]]; then
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || DISCORD_WEBHOOK_URL="$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$ALERT_CONF" | tail -n1 | tr -d "\"'")"
  [[ -n "$ALERT_ON_SUCCESS" ]] || ALERT_ON_SUCCESS="$(sed -n 's/^ALERT_ON_SUCCESS=//p' "$ALERT_CONF" | tail -n1 | tr -d "\"'")"
fi
ALERT_ON_SUCCESS="${ALERT_ON_SUCCESS:-0}"

# notify "message" : envoie le message sur Discord (ne fait rien si aucun webhook n'est configuré).
# Code retour 1 si l'envoi a échoué (le message d'avertissement est déjà affiché).
notify() {
  [[ -n "$DISCORD_WEBHOOK_URL" ]] || return 0
  local msg="$1"
  (( ${#msg} > 1900 )) && msg="${msg:0:1900}…"
  # Échappement JSON
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  msg="${msg//$'\t'/ }"
  msg="${msg//$'\r'/}"
  msg="${msg//$'\n'/\\n}"
  msg="$(printf '%s' "$msg" | tr -d '\000-\037')"
  curl -sf --max-time 15 -o /dev/null -H "Content-Type: application/json" \
    -d "{\"username\": \"Géocodeur Infostat\", \"content\": \"$msg\"}" \
    "$DISCORD_WEBHOOK_URL" && return 0
  echo "Attention : l'alerte Discord n'a pas pu être envoyée" >&2
  return 1
}
