#!/usr/bin/env bash
#
# Télécharge le bundle BAN dans /data s'il est absent ou si une nouvelle version a été publiée,
# puis lance Redis et addok avec supervisord.
#
# PRE_INDEXED_DATA_URL : URL du bundle (par défaut, le bundle France de la BAN)
# UPDATE_ON_START      : 1 (défaut) pour vérifier à chaque démarrage, 0 pour garder les données présentes

set -euo pipefail

BUNDLE_URL="${PRE_INDEXED_DATA_URL:-https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/addok-france-bundle.zip}"
STAMP=/data/.bundle-last-modified
REQUIRED_FILES=(addok.conf addok.db dump.rdb)

log() { echo "[standalone] $*"; }

has_data() {
  local f
  for f in "${REQUIRED_FILES[@]}"; do [[ -s "/data/$f" ]] || return 1; done
}

download() {
  local remote_date tmp
  remote_date="$(curl -sfIL --max-time 60 "$BUNDLE_URL" | tr -d '\r' | grep -i '^last-modified:' | tail -n1 | cut -d' ' -f2- || true)"
  if has_data && [[ -n "$remote_date" && "$remote_date" == "$(cat "$STAMP" 2>/dev/null)" ]]; then
    log "Données déjà à jour ($remote_date)"
    return 0
  fi

  log "Téléchargement de $BUNDLE_URL"
  tmp="$(mktemp -d /data/.download.XXXXXX)"
  if curl -fL --retry 3 --retry-delay 30 --silent --show-error -o "$tmp/bundle.zip" "$BUNDLE_URL" \
     && unzip -tqq "$tmp/bundle.zip" \
     && unzip -qq -o -d "$tmp" "$tmp/bundle.zip"; then
    local f
    for f in "${REQUIRED_FILES[@]}"; do
      [[ -s "$tmp/$f" ]] || { log "Fichier $f absent du bundle"; rm -rf "$tmp"; return 1; }
    done
    for f in "${REQUIRED_FILES[@]}"; do mv -f "$tmp/$f" "/data/$f"; done
    [[ -n "$remote_date" ]] && printf '%s\n' "$remote_date" > "$STAMP"
    rm -rf "$tmp"
    log "Données installées ($remote_date)"
  else
    rm -rf "$tmp"
    return 1
  fi
}

if [[ "${UPDATE_ON_START:-1}" == "1" ]] || ! has_data; then
  if ! download; then
    if has_data; then
      log "Échec de la mise à jour, démarrage avec les données existantes"
    else
      log "Échec du téléchargement et aucune donnée disponible" >&2
      exit 1
    fi
  fi
fi

exec supervisord -c /etc/supervisor/addok-standalone.conf
