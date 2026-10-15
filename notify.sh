#!/usr/bin/env bash
#
# Envoie un message sur le salon Discord configuré dans alert.conf.
#
# Usage : ./notify.sh "message"
#         ./notify.sh --test     envoie un message de test

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "$*"; }
die() { echo "ERREUR : $*" >&2; exit 1; }
# shellcheck source=lib/instance.sh
source "$PROJECT_DIR/lib/instance.sh"

[[ $# -eq 1 ]] || die "usage : ./notify.sh \"message\" ou ./notify.sh --test"
[[ -n "$DISCORD_WEBHOOK_URL" ]] || die "aucun webhook Discord configuré (copiez alert.conf.example en alert.conf)"

msg="$1"
[[ "$msg" == --test ]] && msg="🔔 Test des alertes du géocodeur sur \`$(hostname)\` : les alertes fonctionnent."
notify "$msg" || exit 1
echo "Message envoyé."
