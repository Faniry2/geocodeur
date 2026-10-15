#!/bin/bash
#
# serve (par défaut) : lance le serveur HTTP addok avec gunicorn
# autre commande     : exécute la commande addok correspondante (batch, ngrams, shell...)

set -euo pipefail

if [[ ! -f "$ADDOK_CONFIG_MODULE" ]]; then
  echo "Fichier de configuration addok introuvable : $ADDOK_CONFIG_MODULE" >&2
  exit 1
fi

if [[ "${1:-serve}" != "serve" ]]; then
  exec addok "$@"
fi

# Copie de la configuration avec les options de logs, dans un emplacement accessible en écriture
PATCHED_CONFIG=/tmp/addok.patched.conf
cp "$ADDOK_CONFIG_MODULE" "$PATCHED_CONFIG"

LOG_DIR=${LOG_DIR:-/logs}
if [[ -w "$LOG_DIR" ]]; then
  echo "LOG_DIR = '$LOG_DIR'" >> "$PATCHED_CONFIG"
  if [[ "${LOG_QUERIES:-0}" == "1" ]]; then
    echo "Journalisation des requêtes activée"
    echo "LOG_QUERIES = True" >> "$PATCHED_CONFIG"
  fi
  if [[ "${LOG_NOT_FOUND:-0}" == "1" ]]; then
    echo "Journalisation des adresses non trouvées activée"
    echo "LOG_NOT_FOUND = True" >> "$PATCHED_CONFIG"
  fi
  if [[ -n "${SLOW_QUERIES:-}" ]]; then
    echo "Journalisation des requêtes lentes (> ${SLOW_QUERIES} ms) activée"
    echo "SLOW_QUERIES = ${SLOW_QUERIES}" >> "$PATCHED_CONFIG"
  fi
else
  echo "Attention : $LOG_DIR n'est pas accessible en écriture (uid $(id -u)), journaux addok désactivés" >&2
fi

export ADDOK_CONFIG_MODULE="$PATCHED_CONFIG"

exec gunicorn \
  --workers "${WORKERS:-1}" \
  --timeout "${WORKER_TIMEOUT:-30}" \
  --bind 0.0.0.0:7878 \
  --access-logfile - \
  --no-control-socket \
  addok.http.wsgi
