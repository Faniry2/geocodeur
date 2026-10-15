# TODO – Mise à jour d'addok-docker

État au 15/10/2026 : le projet est identique au dépôt officiel `BaseAdresseNationale/addok-docker`, qui n'est plus maintenu depuis le 31/10/2022 (images Docker Hub `etalab/addok` et `etalab/addok-redis` de la même date).

## Comment fonctionne le projet

**Addok** est un géocodeur libre développé par Etalab. Il transforme une adresse en coordonnées GPS (`/search?q=1 rue de la paix paris`) et des coordonnées GPS en adresse (`/reverse?lat=...&lon=...`). C'est le moteur de l'API officielle api-adresse.data.gouv.fr. Il tolère les fautes de frappe et fait de l'autocomplétion. Il est rapide parce que tout son index est chargé en mémoire dans Redis (environ 6 Go de RAM).

Ce projet le fait tourner dans Docker :

```
           requêtes HTTP (port 7878)
                     │
              ┌──────▼──────┐   lit l'index    ┌───────────────┐
              │    addok    │ ───────────────► │  addok-redis  │
              │  (gunicorn) │                  │ (index en RAM)│
              └──────┬──────┘                  └───────▲───────┘
                     │ lit les détails                 │ charge au démarrage
              ┌──────▼──────┐                  ┌───────┴───────┐
              │  addok.db   │                  │   dump.rdb    │
              │  (SQLite)   │                  │               │
              └─────────────┘                  └───────────────┘
                ▲ addok-data/ = bundle BAN décompressé (+ addok.conf)
```

| Dossier / fichier | Rôle |
|---|---|
| `docker-compose.yml` | Lance l'instance (`addok` + `addok-redis`) à partir des données de `addok-data/` |
| `addok/` | Image du serveur : Python, addok et ses extensions, gunicorn. `docker-entrypoint.sh` ajoute les options de logs à la config, puis lance gunicorn |
| `addok-redis/` | Image Redis avec sa configuration. Elle charge `dump.rdb` au démarrage |
| `addok-standalone/` | Variante expérimentale où tout tourne dans un seul conteneur (supervisord). Elle télécharge le bundle BAN à chaque démarrage |
| `addok-importer/` + `build-package/` | Fabrication de son propre bundle à partir de fichiers `.ndjson.gz` (import dans Redis, calcul des n-grammes, export en zip) |
| `addok-data/` (non versionné) | Les données : `addok.conf`, `addok.db`, `dump.rdb`, issues du bundle BAN |
| `update-data.sh` | Met à jour `addok-data/` automatiquement quand la BAN publie un nouveau bundle (voir 0 bis) |

Les extensions d'addok :
- `addok-fr` : phonétique française ;
- `addok-france` : règles des adresses françaises (numéros, bis/ter, abréviations) ;
- `addok-csv` : géocodage d'un fichier CSV entier ;
- `addok-sqlite-store` : stockage des données détaillées dans SQLite.

Le bundle BAN (`addok-france-bundle.zip`, ~2,4 Go) est regénéré chaque jour par la Base Adresse Nationale. Il contient l'index déjà calculé, donc il suffit de le décompresser dans `addok-data/` et de démarrer.

## Journal de ce qui a été fait

**15/10/2026**
- Analyse complète du projet. Résultat : identique au dépôt officiel, sans mise à jour depuis le 31/10/2022.
- Comparaison des versions avec PyPI. Toutes les dépendances sont en retard (addok 1.0.3 → 1.3.2, gunicorn 20.1.0 → 26.2.0, qui a des failles de sécurité, Python 3.10, qui arrive en fin de vie).
- Repérage de ce qui cassera lors de la mise à jour : `cython` retiré d'addok, `redis:4` dans l'importeur alors qu'il faut Redis 7.2 minimum, compatibilité du `dump.rdb`, `docker-compose` v1 abandonné.
- Vérification de la source des données : l'URL du bundle BAN fonctionne et le bundle est mis à jour chaque jour. En revanche, le projet ne le retélécharge jamais, et aucune donnée n'est encore installée sur cette machine.
- Création de cette TODO.
- Création de `update-data.sh` (mise à jour automatique des données, avec retour aux anciennes données en cas d'échec). Il a été testé en simulation ; aucune vraie mise à jour n'a été lancée, car il manque de RAM libre (5 Go disponibles pour environ 6 Go nécessaires).
- Ajout des fichiers temporaires du script au `.gitignore`.
- Aucun fichier d'origine du projet n'a été modifié, à part le `.gitignore`.
- Décision : ce projet devient notre propre projet, avec addok comme dépendance externe. Vérification des licences : addok, addok-fr et addok-france sont sous MIT ; addok-docker n'a pas de licence déclarée. Ajout de la section 0 ter.

## 0. Préparation

- [ ] `git init` + premier commit pour conserver l'état actuel avant modification
- [ ] Vérifier qu'au moins 6 Go de RAM et 8 Go de disque sont disponibles pour les tests

## 0 ter. Faire du projet le nôtre

Ce projet est maintenant notre propre projet, construit à partir d'addok-docker. Addok et ses extensions (licence MIT, Etalab) restent des dépendances externes.

- [ ] Donner un nom au projet et renommer le dossier `addok-docker-master`
- [ ] Construire nos propres images au lieu d'utiliser `etalab/addok` et `etalab/addok-redis` (figées depuis 2022) : `build:` dans `docker-compose.yml` ou nos propres noms d'images, et `FROM` à adapter dans `addok-standalone/Dockerfile`
- [ ] Licence : le dépôt `BaseAdresseNationale/addok-docker` n'a pas de licence déclarée. Demander à la BAN (ou réécrire les fichiers repris) avant toute diffusion publique, puis choisir la licence de notre projet
- [ ] Citer la source des données : BAN, sous Licence Ouverte Etalab 2.0 (attribution obligatoire)
- [ ] Réécrire le README pour notre projet (les liens `wget` pointent encore vers le dépôt de la BAN)
- [ ] Créer notre propre dépôt git distant (GitHub, GitLab…)

## 0 bis. Données BAN toujours à jour (prioritaire)

Le bundle BAN (`addok-france-bundle.zip`, ~2,4 Go) est regénéré chaque jour par la BAN, mais le projet ne le retélécharge jamais tout seul : les données locales vieillissent dès leur installation.

- [x] Écrire `update-data.sh` : ne télécharge que si la BAN a publié une nouvelle version, contrôle l'archive, prépare les données à côté de l'instance en service, bascule, redémarre, vérifie qu'une recherche répond et revient aux anciennes données en cas d'échec
- [x] Tester le script en simulation : mode `--check`, mise à jour réussie, relance sans changement, échec avec restauration
- [ ] Premier lancement réel : `./update-data.sh` (environ 6 Go de RAM et 13 Go de disque nécessaires pendant la bascule)
- [ ] Planifier l'exécution automatique avec cron, par exemple tous les jours à 5h30 (le bundle est publié vers 3h20 UTC) :
      `30 5 * * * /home/rapadango/geocodeur_infostat/addok-docker-master/update-data.sh >> /home/rapadango/geocodeur_infostat/addok-docker-master/logs/update-data.log 2>&1`
- [ ] Choisir la fréquence : quotidienne (2,4 Go téléchargés par jour) ou hebdomadaire
- [ ] Mettre en place une alerte en cas d'échec (e-mail ou supervision sur le code retour)
- [ ] Documenter le script dans le README
- [ ] Faire en sorte que `addok-standalone` ne télécharge le bundle que s'il a changé, comme `update-data.sh`
- [ ] Facultatif : supprimer la coupure de 1 à 2 minutes pendant le redémarrage, en démarrant une 2ᵉ instance et en basculant le trafic une fois qu'elle est prête

## 1. Bloquant (casse si on monte les versions)

- [ ] Retirer `cython` des `pip install` (`addok/Dockerfile`, `addok-importer/Dockerfile`), il n'est plus pris en charge depuis addok 1.2
- [ ] Remplacer `redis:4` par `redis:7.4` (ou 8.x) dans `build-package/docker-compose-build.yml` (addok 1.3 demande Redis 7.2 minimum)
- [ ] Tester le chargement du `dump.rdb` du bundle BAN avec la version de Redis choisie (un Redis ne lit pas un dump produit par une version plus récente que lui)
- [ ] Remplacer `docker-compose` (v1) par `docker compose` (v2) dans `build-package/run.sh` et le README

## 2. Versions des composants

- [ ] Python 3.10 → 3.13 (image `python:3.13-slim`)
- [ ] addok 1.0.3 → 1.3.2
- [ ] addok-fr 1.0.1 → 1.1.0
- [ ] addok-france 1.1.3 → 1.2.0
- [ ] addok-csv 1.0.1 → 1.1.0
- [ ] addok-sqlite-store 1.0.1 → 1.1.0
- [ ] gunicorn 20.1.0 → 26.2.0 (failles de sécurité CVE-2024-1135, CVE-2024-6827)
- [ ] Redis 7 → 7.4 ou 8.x (`addok-redis/Dockerfile`)

## 3. Docker Compose

- [ ] Supprimer `version: '2'` (obsolète)
- [ ] Remplacer `links` par le réseau par défaut (service nommé `redis`)
- [ ] Ajouter `restart: unless-stopped`
- [ ] Ajouter un `healthcheck` sur l'endpoint `/health` (disponible depuis addok 1.1)
- [ ] Ne pas exposer le port Redis à l'extérieur (pas de mot de passe, `protected-mode no`)

## 4. Dockerfiles et scripts

- [ ] `pip install --no-cache-dir`
- [ ] Syntaxe `ENV KEY=value` au lieu de `ENV KEY value`
- [ ] `CMD ["docker-entrypoint.sh"]` (forme JSON) au lieu de la forme shell
- [ ] Faire tourner les conteneurs avec un utilisateur non-root
- [ ] `addok/docker-entrypoint.sh` : ajouter `set -e` et lancer `exec gunicorn ...`
- [ ] Mettre en place une CI (GitHub Actions) pour construire les images amd64/arm64

## 5. addok-standalone

- [ ] Ne pas retélécharger les 2,4 Go à chaque démarrage (vérifier si les données sont déjà présentes)
- [ ] Ajouter `set -e` et des vérifications d'erreur (téléchargement, décompression)
- [ ] Installer `unzip` (et `wget` avec une image slim) au lieu de `zip`
- [ ] Lancer `exec /usr/bin/supervisord`

## 6. Configuration Redis

- [ ] Remplacer `addok-redis/redis.conf` (fichier d'exemple Redis 7.0 de 106 Ko) par une config minimale (`save ""`, `dir /data`, `protected-mode`, etc.)

## 7. Documentation (README)

- [ ] Mettre à jour le tableau des versions
- [ ] Remplacer « Docker CE 1.10+ / Docker Compose 1.10+ » par les prérequis actuels
- [ ] Remplacer `docker-compose up` par `docker compose up`
- [ ] Mettre à jour le lien vers la doc gunicorn (pointe vers la version 0.17.2)
- [ ] Documenter les filtres à plusieurs valeurs (addok 1.3 : `type=street+city`)

## 8. Validation finale

- [ ] Construire toutes les images
- [ ] Démarrer avec le bundle BAN et tester `curl "http://localhost:7878/search?q=1+rue+de+la+paix+paris"`
- [ ] Tester `/reverse` et `/health`
- [ ] Tester la reconstruction du bundle avec `build-package/run.sh`
