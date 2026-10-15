#!/usr/bin/env bash
#
# Construit un bundle addok à partir des fichiers data/*.ndjson.gz
# (par exemple https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/adresses-addok-france.ndjson.gz).
# Résultat : dist/prebuilt-bundle.zip, à décompresser dans addok-data/.
#
# Usage, depuis la racine du projet : ./build-package/run.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export HOST_UID HOST_GID
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
compose() { docker compose -f build-package/docker-compose-build.yml "$@"; }

shopt -s nullglob
inputs=(data/*.ndjson.gz)
(( ${#inputs[@]} > 0 )) || { echo "Aucun fichier data/*.ndjson.gz à importer" >&2; exit 1; }

echo "> Préparation du répertoire de travail"
compose down --remove-orphans
mkdir -p dist
rm -f dist/addok.db dist/dump.rdb dist/prebuilt-bundle.zip

echo "> Démarrage de Redis"
compose up -d --wait redis

echo "> Importation des données (${inputs[*]})"
gunzip -c "${inputs[@]}" | compose run --rm -T importer batch

echo "> Création des n-grammes"
compose run --rm -T importer ngrams

echo "> Écriture du dump Redis"
compose exec -T redis redis-cli save
compose down

echo "> Préparation de l'archive"
(cd dist && zip -q prebuilt-bundle.zip addok.db dump.rdb)
zip -q -j dist/prebuilt-bundle.zip build-package/addok.conf
rm -f dist/addok.db dist/dump.rdb

echo "Terminé : dist/prebuilt-bundle.zip"
