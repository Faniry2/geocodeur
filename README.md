# Géocodeur Infostat

Une instance [addok](https://github.com/addok/addok) prête à l'emploi dans Docker, alimentée par les données de la [Base Adresse Nationale](https://adresse.data.gouv.fr) (BAN) et mise à jour automatiquement.

Addok est le moteur de géocodage de l'API officielle api-adresse.data.gouv.fr :
- **géocodage** : une adresse devient des coordonnées GPS (`/search`) ;
- **géocodage inverse** : des coordonnées GPS deviennent une adresse (`/reverse`) ;
- **géocodage de fichiers CSV** (`/search/csv`, `/reverse/csv`).

Il tolère les fautes de frappe et fait de l'autocomplétion.

Ce projet est dérivé de [BaseAdresseNationale/addok-docker](https://github.com/BaseAdresseNationale/addok-docker), qui n'est plus maintenu depuis 2022. Le suivi du travail est dans [TODO.md](TODO.md).

## Fonctionnement

```
requêtes HTTP :7878 ──► addok (gunicorn) ──► redis (index en mémoire, chargé depuis dump.rdb)
                              │
                              └──► addok.db (SQLite : fiches complètes des adresses)
```

Chaque jour, la BAN publie un **bundle** (`addok-france-bundle.zip`, ~2,4 Go) qui contient l'index déjà calculé. Le script `update-data.sh` le télécharge dans `addok-data/` et redémarre l'instance.

| Élément | Rôle |
|---|---|
| `docker-compose.yml` | Instance principale : `addok` + `redis` |
| `addok/` | Image du serveur addok. Elle sert aussi d'importeur pour `build-package` |
| `addok-redis/` | Image Redis qui charge l'index |
| `addok-standalone/` | Variante tout-en-un (un seul conteneur) qui télécharge elle-même les données |
| `build-package/` | Construction de son propre bundle à partir de fichiers `.ndjson.gz` |
| `install.sh` | Installeur : prérequis, images, données, démarrage, cron |
| `update-data.sh` | Mise à jour automatique des données BAN |
| `tests/smoke.sh` | Tests fonctionnels d'une instance |

## Composants

| Composant | Version |
|---|---|
| Python | 3.14 (Debian 13 « trixie ») |
| Redis | 8.10 |
| addok | 1.3.2 |
| addok-fr | 1.1.0 |
| addok-france | 1.2.0 |
| addok-csv | 1.1.0 (plus maintenu, corrigé dans l'image pour addok 1.3) |
| addok-sqlite-store | 1.1.0 |
| gunicorn | 26.2.0 |

Les images fonctionnent sur `linux/amd64` et `linux/arm64` (Apple Silicon, Raspberry Pi 64 bits).

## Installation

### Prérequis

- Docker Engine 24 ou plus récent, avec le plugin Docker Compose v2 (`docker compose`)
- 6 Go de RAM disponibles
- 15 Go d'espace disque : les données, plus une copie temporaire pendant les mises à jour
- `curl`, `unzip` et `flock` (présents sur la plupart des distributions Linux)

### Installer et démarrer

```bash
./install.sh
```

L'installeur fait tout, dans l'ordre :
1. vérifie les prérequis : Docker, Compose v2, outils, RAM, disque ;
2. construit les images ;
3. télécharge ou met à jour les données BAN (~2,4 Go au premier lancement) ;
4. démarre l'instance et attend qu'elle réponde (30 secondes à 2 minutes de chargement en mémoire) ;
5. installe la tâche cron de mise à jour automatique (tous les jours à 5h30).

On peut le relancer sans risque, par exemple pour redémarrer après un `docker compose down` : il ne refait que ce qui manque.

| Option | Effet |
|---|---|
| `--cron=daily` | mise à jour tous les jours à 5h30 (défaut) |
| `--cron=weekly` | mise à jour tous les lundis à 5h30 |
| `--cron=none` | pas de mise à jour automatique (retire la tâche si elle existe) |
| `-y` | ne pose aucune question |

### Tester

```bash
curl "http://localhost:7878/search?q=1+rue+de+la+paix+paris"
curl "http://localhost:7878/reverse?lon=2.3316&lat=48.8687"
curl "http://localhost:7878/health"
tests/smoke.sh            # série de tests fonctionnels
```

## Garder les données à jour

`update-data.sh` :
1. compare la date du bundle publié par la BAN avec celle des données installées, et s'arrête s'il n'y a rien de nouveau ;
2. télécharge et vérifie le nouveau bundle pendant que l'instance continue de répondre ;
3. bascule sur les nouvelles données, redémarre et vérifie qu'une recherche fonctionne ;
4. **en cas de problème, remet automatiquement les anciennes données en place**.

```bash
./update-data.sh --check   # indique seulement si une mise à jour est disponible (code retour 10)
./update-data.sh --force   # réinstalle même si les données sont à jour
```

`install.sh` installe la tâche cron qui lance ce script automatiquement. La BAN publie vers 3h20 UTC, d'où l'horaire de 5h30. Le journal est dans `logs/update-data.log`. Le redémarrage coupe le service 1 à 2 minutes. L'utilisateur qui lance le script doit pouvoir utiliser Docker.

## Paramètres

À régler dans `docker-compose.yml` :

| Paramètre | Description | Défaut |
|---|---|---|
| `WORKERS` | Nombre de processus addok | `1` |
| `WORKER_TIMEOUT` | [Durée maximale d'une requête](https://gunicorn.org/reference/settings/#timeout), en secondes | `30` |
| `LOG_QUERIES` | `1` pour journaliser les requêtes dans `logs/queries.log` | `1` |
| `LOG_NOT_FOUND` | `1` pour journaliser les adresses non trouvées dans `logs/notfound.log` | `1` |
| `SLOW_QUERIES` | Journalise les requêtes plus lentes que cette durée (ms) dans `logs/slow_queries.log` | `200` |

Les conteneurs tournent avec l'utilisateur `1000` de l'hôte. Pour en utiliser un autre : `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d` (`update-data.sh` le fait automatiquement).

### Filtres

`type`, `citycode` et `postcode`, par exemple `/search?q=paris&type=street`. Depuis addok 1.3, un filtre accepte plusieurs valeurs : `type=street+municipality` ou `type=street&type=municipality`.

## Variante tout-en-un (standalone)

Un seul conteneur, qui télécharge le bundle au premier démarrage, puis seulement quand la BAN en a publié un nouveau :

```bash
docker compose build
docker build -t geocodeur-infostat/addok-standalone:1.3.2 addok-standalone
docker run -d -p 7878:7878 -v addok-data:/data geocodeur-infostat/addok-standalone:1.3.2
```

| Variable | Description | Défaut |
|---|---|---|
| `PRE_INDEXED_DATA_URL` | URL du bundle | bundle France de la BAN |
| `UPDATE_ON_START` | `0` pour ne pas vérifier les mises à jour au démarrage | `1` |

## Construire son propre bundle

À partir des fichiers `.ndjson.gz` de la BAN (France entière ou un département : `https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/adresses-addok-<département>.ndjson.gz`) ou de vos propres données au même format :

```bash
mkdir -p data
curl -o data/adresses-addok-75.ndjson.gz https://adresse.data.gouv.fr/data/ban/adresses/latest/addok/adresses-addok-75.ndjson.gz
./build-package/run.sh                                         # crée dist/prebuilt-bundle.zip
BUNDLE_URL="file://$PWD/dist/prebuilt-bundle.zip" ./update-data.sh   # l'installe
```

## Licences et attribution

- Données : **Base Adresse Nationale**, [Licence Ouverte Etalab 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/). L'attribution est obligatoire, par exemple « Source : Base Adresse Nationale ».
- addok, addok-fr, addok-france, addok-csv, addok-sqlite-store : licence MIT (Etalab / contributeurs addok).
- Redis 8 : licence AGPLv3, RSALv2 ou SSPLv1, au choix. Rien n'est à prévoir pour un usage interne.
