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
                              ┌─► instance blue  : addok ──► redis   (addok-data-blue/)
requêtes HTTP :7878 ──► proxy ┤
                              └─► instance green : addok ──► redis   (addok-data-green/)
```

Chaque instance = addok (gunicorn) + redis (index en mémoire, chargé depuis `dump.rdb`) + `addok.db` (SQLite : fiches complètes des adresses). Une seule instance tourne en temps normal ; le proxy nginx lui envoie les requêtes.

Chaque jour, la BAN publie un **bundle** (`addok-france-bundle.zip`, ~2,4 Go) qui contient l'index déjà calculé. Le script `update-data.sh` le télécharge dans le dossier de l'instance arrêtée, la démarre, puis bascule le proxy vers elle dès qu'elle répond : **la mise à jour se fait sans coupure** (voir [Garder les données à jour](#garder-les-données-à-jour)). `addok-data` est un lien vers le dossier de l'instance active.

| Élément | Rôle |
|---|---|
| `docker-compose.yml` | Le proxy et les deux instances `blue` et `green` (`addok-*` + `redis-*`) |
| `proxy/` | Image du proxy (nginx sans root) qui envoie les requêtes à l'instance active |
| `addok/` | Image du serveur addok. Elle sert aussi d'importeur pour `build-package` |
| `addok-redis/` | Image Redis qui charge l'index |
| `addok-standalone/` | Variante tout-en-un (un seul conteneur) qui télécharge elle-même les données |
| `build-package/` | Construction de son propre bundle à partir de fichiers `.ndjson.gz` |
| `install.sh` | Installeur : prérequis, images, données, démarrage, cron |
| `update-data.sh` | Mise à jour automatique des données BAN, sans coupure |
| `check-health.sh` | Surveillance du géocodeur toutes les 5 minutes, avec alerte en cas de panne |
| `notify.sh` | Envoi d'un message sur Discord (alertes) |
| `lib/instance.sh` | Fonctions communes aux scripts : instances, proxy, alertes |
| `tests/smoke.sh` | Tests fonctionnels d'une instance |

## Composants

| Composant | Version |
|---|---|
| Python | 3.14 (Debian 13 « trixie ») |
| Redis | 8.10 |
| addok | 1.3.2 |
| addok-fr | 1.0.1 (version qui a servi à construire l'index de la BAN : la 1.1.0 change la phonétique et fait rater des recherches) |
| addok-france | 1.2.0 |
| addok-csv | 1.1.0 (plus maintenu, corrigé dans l'image pour addok 1.3) |
| addok-sqlite-store | 1.1.0 |
| gunicorn | 26.2.0 |
| nginx (proxy) | 1.30 |

Les images fonctionnent sur `linux/amd64` et `linux/arm64` (Apple Silicon, Raspberry Pi 64 bits).

## Installation

### Prérequis

- Docker Engine 24 ou plus récent, avec le plugin Docker Compose v2 (`docker compose`)
- 6 Go de RAM disponibles (France entière : environ 3 Go pour Redis). Pour les mises à jour sans coupure, il faut de quoi faire tourner une 2e instance pendant 1 à 2 minutes (environ 4,5 Go de plus) ; sinon la mise à jour se fait avec une coupure
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
4. démarre le proxy et l'instance active, et attend qu'ils répondent (30 secondes à 2 minutes de chargement en mémoire) ;
5. installe les tâches cron : mise à jour automatique (tous les jours à 5h30) et surveillance (toutes les 5 minutes).

On peut le relancer sans risque, par exemple pour redémarrer après un `docker compose down` : il ne refait que ce qui manque.

| Option | Effet |
|---|---|
| `--cron=daily` | mise à jour tous les jours à 5h30 (défaut) |
| `--cron=weekly` | mise à jour tous les lundis à 5h30 |
| `--cron=none` | pas de mise à jour automatique (retire la tâche si elle existe) |
| `--watch=off` | pas de surveillance toutes les 5 minutes (retire la tâche si elle existe) |
| `--discord-webhook=URL` | envoie les alertes sur ce salon Discord (voir [Alertes](#alertes)) |
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
2. télécharge et vérifie le nouveau bundle dans le dossier de l'instance arrêtée (par exemple `addok-data-green/` si `blue` est active), pendant que l'instance active continue de répondre ;
3. démarre l'autre instance avec les nouvelles données et vérifie qu'une recherche fonctionne ;
4. bascule le proxy vers elle (les requêtes en cours se terminent sur l'ancienne), puis arrête l'ancienne instance et supprime ses données ;
5. **en cas de problème, l'ancienne instance reste active** et une [alerte](#alertes) est envoyée.

Faire tourner deux instances demande deux fois plus de RAM pendant 1 à 2 minutes. Avant de commencer, le script compare la mémoire de Redis (+ 30 % + 512 Mo de marge) avec la RAM disponible. S'il n'y en a pas assez, il arrête d'abord l'ancienne instance : la mise à jour coupe alors le service 1 à 2 minutes, et si les nouvelles données ne fonctionnent pas, l'ancienne instance est redémarrée.

```bash
./update-data.sh --check          # indique seulement si une mise à jour est disponible (code retour 10)
./update-data.sh --force          # réinstalle même si les données sont à jour
HOT_SWAP=never ./update-data.sh   # toujours avec coupure (always : toujours sans coupure, sans vérifier la RAM)
```

`install.sh` installe la tâche cron qui lance ce script automatiquement. La BAN publie vers 3h20 UTC, d'où l'horaire de 5h30. Le journal est dans `logs/update-data.log`. L'utilisateur qui lance le script doit pouvoir utiliser Docker.

L'instance active est notée dans `.env` (`COMPOSE_PROFILES=blue` ou `green`) : `docker compose up -d`, `down`, `ps` et `logs` s'appliquent au proxy et à l'instance active.

### Alertes

Un message est envoyé sur un salon Discord :
- **quand une mise à jour échoue** : la cause, l'état de l'instance (« continue de répondre avec les données du… ») et l'emplacement du journal ;
- **quand le géocodeur tombe en panne**, puis quand il répond de nouveau. `check-health.sh`, lancé par cron toutes les 5 minutes, interroge `/health` et fait une recherche de test à travers le proxy. Une panne est déclarée après 3 essais ratés à 20 secondes d'intervalle. L'alerte indique la cause (proxy arrêté, instance addok injoignable, recherche sans résultat) et l'état des conteneurs. Il n'y a qu'une alerte par panne, puis un rappel toutes les 6 heures (`HEALTH_REMIND_HOURS`). Rien n'est vérifié pendant une mise à jour. Le journal `logs/health.log` ne contient que les changements d'état.

Un `docker compose down` volontaire déclenche donc aussi une alerte ; pour arrêter le géocodeur durablement, retirer d'abord la surveillance : `./install.sh --watch=off`.

```bash
./install.sh --discord-webhook=https://discord.com/api/webhooks/...   # enregistre le webhook dans alert.conf
./notify.sh --test                                                    # envoie un message de test
```

`alert.conf` n'est pas versionné : l'URL du webhook suffit pour écrire dans le salon, elle doit rester secrète. Voir `alert.conf.example` ; `ALERT_ON_SUCCESS=1` prévient aussi des mises à jour réussies.

## Paramètres

Le port se règle dans `.env` : `ADDOK_PORT=7878` (défaut). Le reste se règle dans `docker-compose.yml` (`x-addok-env`, commun aux deux instances) :

| Paramètre | Description | Défaut |
|---|---|---|
| `WORKERS` | Nombre de processus addok (environ 55 Mo de RAM chacun). Un fichier CSV occupe un worker pendant tout son traitement : les autres continuent de répondre | `4` |
| `WORKER_TIMEOUT` | [Durée maximale d'une requête](https://gunicorn.org/reference/settings/#timeout), en secondes (le proxy coupe aussi à 300 s) | `300` |
| `WORKER_MAX_REQUESTS` | Nombre de requêtes après lequel un worker est remplacé (limite la mémoire du cache de phonétique d'addok-fr 1.0.1) | `20000` |
| `CSV_MAX_SIZE_MB` | Taille maximale d'un fichier envoyé à `/search/csv` ou `/reverse/csv`, en Mo | `50` |
| `LOG_QUERIES` | `1` pour journaliser les requêtes dans `logs/queries.log` | `1` |
| `LOG_NOT_FOUND` | `1` pour journaliser les adresses non trouvées dans `logs/notfound.log` | `1` |
| `SLOW_QUERIES` | Journalise les requêtes plus lentes que cette durée (ms) dans `logs/slow_queries.log` | `200` |

Les conteneurs tournent avec l'utilisateur `1000` de l'hôte. Pour en utiliser un autre : `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d` (`update-data.sh` le fait automatiquement).

### Géocodage de fichiers CSV

```bash
curl -X POST http://localhost:7878/search/csv/ -F data=@adresses.csv -F columns=adresse -F citycode=depcom -o resultat.csv
```

- `columns` : la ou les colonnes qui forment l'adresse (`-F columns=numero -F columns=voie`) ; les filtres (`postcode`, `citycode`, `type`) prennent le nom d'une colonne ;
- le fichier doit être en UTF-8 (sinon `-F encoding=cp1252`) ; le séparateur est détecté (sinon `-F delimiter=';'`) ;
- un résultat dont le score est inférieur à 0,5 est laissé vide. Le seuil se règle pour une requête (`-F min_score=0.4`) ou pour toute l'instance (`ADDOK_CSV_MIN_SCORE: 0.4` dans `x-addok-env`). Le baisser est déconseillé : sur le fichier OGRB (19/10/2026), seules 22 % des réponses entre 0,4 et 0,5 tombaient à moins de 50 m de la position de référence ;
- pour une ligne restée vide, la meilleure réponse est quand même donnée dans les colonnes `result_candidat_label`, `result_candidat_score`, `result_candidat_type`, `result_candidat_latitude` et `result_candidat_longitude`, **à vérifier à la main** : `latitude` et `longitude` restent vides. Exemple : « 4 place Charles Ginesy, Péone » → candidat « 4 Place Thomas Guérin » (la place a changé de nom) ;
- débit mesuré : environ 240 adresses par seconde. Au-delà de 300 s de traitement (environ 50 000 adresses), découper le fichier.

### Filtres

`type`, `citycode` et `postcode`, par exemple `/search?q=paris&type=street`. Depuis addok 1.3, un filtre accepte plusieurs valeurs : `type=street+municipality` ou `type=street&type=municipality`.

## Variante tout-en-un (standalone)

Un seul conteneur, qui télécharge le bundle au premier démarrage, puis seulement quand la BAN en a publié un nouveau :

```bash
docker compose --profile '*' build
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

- Ce projet : licence MIT, voir [LICENSE](LICENSE).
- Données : **Base Adresse Nationale**, [Licence Ouverte Etalab 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/). L'attribution est obligatoire, par exemple « Source : Base Adresse Nationale ».
- addok, addok-fr, addok-france, addok-csv, addok-sqlite-store : licence MIT (Etalab / contributeurs addok).
- Redis 8 : licence AGPLv3, RSALv2 ou SSPLv1, au choix. Rien n'est à prévoir pour un usage interne.
