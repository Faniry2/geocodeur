# TODO – Géocodeur Infostat

Projet dérivé de `BaseAdresseNationale/addok-docker` (plus maintenu depuis le 31/10/2022), modernisé le 15/10/2026.

## Comment fonctionne le projet

**Addok** est un géocodeur libre développé par Etalab. Il transforme une adresse en coordonnées GPS (`/search?q=1 rue de la paix paris`) et des coordonnées GPS en adresse (`/reverse?lat=...&lon=...`). C'est le moteur de l'API officielle api-adresse.data.gouv.fr. Il tolère les fautes de frappe et fait de l'autocomplétion. Il est rapide parce que tout son index est chargé en mémoire dans Redis (environ 6 Go de RAM).

**Le principe :** chaque jour, la BAN rassemble les adresses de France, calcule l'index avec addok et publie le résultat sous forme de **bundle** (`addok-france-bundle.zip`, ~2,4 Go). Notre projet télécharge ce bundle (`update-data.sh`) et le sert avec addok. Addok n'est pas à nous, c'est une dépendance externe (licence MIT). Le projet, lui, est le nôtre.

```
           requêtes HTTP (port 7878)
                     │
              ┌──────▼──────┐
              │    proxy    │  envoie vers l'instance active : blue ou green
              │   (nginx)   │  (chaque instance = addok + redis + ses données)
              └──────┬──────┘
                     │
              ┌──────▼──────┐   lit l'index    ┌───────────────┐
              │    addok    │ ───────────────► │     redis     │
              │  (gunicorn) │                  │ (index en RAM)│
              └──────┬──────┘                  └───────▲───────┘
                     │ lit les fiches                  │ charge au démarrage
              ┌──────▼──────┐                  ┌───────┴───────┐
              │  addok.db   │                  │   dump.rdb    │
              │  (SQLite)   │                  │  (index)      │
              └─────────────┘                  └───────────────┘
                ▲ addok-data-blue/ ou addok-data-green/ = bundle BAN décompressé
                  (addok-data est un lien vers le dossier de l'instance active)
```

**Pourquoi les données sont à part :** le logiciel change rarement et les adresses changent chaque jour. Les données restent donc dans un dossier monté (`addok-data/`), et non dans les images. L'index est déjà calculé par la BAN, ce qui évite plusieurs heures de calcul.

**Les 3 fichiers du bundle :**
- `dump.rdb` : l'index de recherche, que Redis charge en mémoire ;
- `addok.db` : les fiches complètes des adresses (SQLite, sur disque, pour économiser la RAM) ;
- `addok.conf` : les règles qui ont servi à construire l'index (phonétique, synonymes…). Addok doit appliquer exactement les mêmes règles aux recherches.

| Dossier / fichier | Rôle |
|---|---|
| `docker-compose.yml` | Le proxy et les deux instances : `addok-blue` + `redis-blue`, `addok-green` + `redis-green`. L'instance active est choisie par `COMPOSE_PROFILES` dans `.env` |
| `proxy/` | Image nginx (sans root) devant les instances. `run/active.conf` (généré) indique l'instance active |
| `addok/` | Image du serveur : Python 3.14, addok et ses extensions, gunicorn. Elle sert aussi d'importeur (`docker-entrypoint.sh serve`, sinon commande `addok`). `infostat_wsgi.py` : point d'entrée gunicorn (taille maximale des CSV, colonnes candidat) |
| `addok-redis/` | Image Redis 8.10 avec une config minimale. Elle charge `dump.rdb` au démarrage |
| `addok-standalone/` | Variante tout-en-un (supervisord). Elle télécharge le bundle seulement s'il a changé |
| `build-package/` | Fabrication de son propre bundle à partir de fichiers `.ndjson.gz` |
| `addok-data-blue/`, `addok-data-green/` (non versionnés) | Les données de chaque instance ; seule celle de l'instance active existe en temps normal |
| `install.sh` | Installeur en une commande : prérequis, images, données, démarrage (même si les données sont à jour), cron, webhook Discord |
| `update-data.sh` | Mise à jour automatique des données BAN, sans coupure si la RAM le permet, alerte Discord en cas d'échec |
| `lib/instance.sh` | Fonctions communes aux scripts : instances, bascule du proxy, migration, alertes |
| `check-health.sh` | Surveillance toutes les 5 minutes (`/health` + recherche de test), alerte Discord en cas de panne et au retour |
| `notify.sh` | Envoi d'un message Discord (`./notify.sh --test`) |
| `alert.conf` (non versionné) | Webhook Discord, voir `alert.conf.example` |
| `tests/smoke.sh` | 12 tests fonctionnels (recherche, fautes, autocomplétion, inverse, filtres, numéro écrit en lettres, CSV, colonnes candidat, CSV de plus de 1 Mo) |
| `.github/workflows/ci.yml` | Tests à chaque modification, compatibilité BAN chaque semaine, publication des images |

Les extensions d'addok :
- `addok-fr` : phonétique française ;
- `addok-france` : règles des adresses françaises ;
- `addok-csv` : géocodage de fichiers CSV (plus maintenu) ;
- `addok-sqlite-store` : stockage des fiches dans SQLite.

## Journal de ce qui a été fait

**15/10/2026 : analyse**
- Analyse du projet. Résultat : identique au dépôt officiel, sans mise à jour depuis le 31/10/2022, images Docker Hub figées à la même date.
- Toutes les dépendances sont en retard : addok 1.0.3 (dernière : 1.3.2), gunicorn 20.1.0 avec des failles de sécurité, Python 3.10 en fin de vie.
- Source des données : le bundle BAN est mis à jour chaque jour, mais le projet ne le retéléchargeait jamais.
- Décision : ce projet devient notre propre projet, avec addok comme dépendance externe. Licences : addok, addok-fr et addok-france sont sous MIT ; addok-docker n'a pas de licence déclarée.

**15/10/2026 : mise à jour des données**
- Création de `update-data.sh`. Il ne télécharge que si la BAN a publié du nouveau, contrôle l'archive, prépare les données pendant que l'instance tourne, bascule, vérifie qu'une recherche répond et revient aux anciennes données en cas d'échec. Testé avec Docker : première installation, relance sans changement, bundle cassé suivi de la restauration.

**15/10/2026 : modernisation**
- `git init` et commit de l'état d'origine (permet de revenir en arrière).
- Inspection du bundle BAN à distance, sans le télécharger : `dump.rdb` au format Redis 7.0 (RDB v10), lisible par Redis 8.
- Versions :
  - Python 3.10 → **3.14** ;
  - Debian 12 → **13 « trixie »** ;
  - Redis 7 → **8.10** ;
  - addok 1.0.3 → **1.3.2** ;
  - addok-fr → 1.1.0 (**erreur, revenu à 1.0.1 le 19/10/2026** : voir plus bas) ;
  - addok-france → 1.2.0 ;
  - addok-csv → 1.1.0 ;
  - addok-sqlite-store → 1.1.0 ;
  - gunicorn 20.1.0 → **26.2.0**.
- Trois pièges trouvés et corrigés pendant les tests :
  1. **addok-sqlite-store 1.1.0 ne s'active plus tout seul.** Les recherches répondaient sans erreur mais ne renvoyaient aucune adresse. Correction : `ADDOK_DOCUMENT_STORE_PYPATH` dans l'image.
  2. **Le `addok.conf` du bundle BAN contient `SQLITE_DB_PATH = 'dist/addok.db'`**, qui écrasait le chemin de l'image. Correction : `ADDOK_SQLITE_DB_PATH`, appliquée en dernier.
  3. **addok-csv (abandonné en novembre 2025) plantait avec les filtres d'addok 1.3.** Correction d'une ligne, appliquée à la construction de l'image (la construction échoue si le correctif ne s'applique plus).
- Test de compatibilité : un index construit avec l'**ancienne** pile (addok 1.0.3 + Redis 7.0, comme la BAN) est lu correctement par la **nouvelle** (9 tests sur 9).
- Images :
  - construction en deux étapes, sur une base slim ;
  - utilisateur non-root ;
  - healthchecks sur `/health` et `redis-cli ping` ;
  - `exec` pour que les signaux d'arrêt arrivent bien ;
  - plus de `sudo` ni de fichiers appartenant à root sur l'hôte.
- `docker-compose.yml` :
  - suppression de `version` et `links` ;
  - images construites localement ;
  - `depends_on` sur l'état de santé de Redis ;
  - `restart: unless-stopped` ;
  - fichiers de données montés en lecture seule ;
  - Redis non exposé.
- Importeur : suppression du Dockerfile en double (on réutilise l'image `addok`), `redis:4` remplacé, `run.sh` réécrit (Compose v2, sans sudo). Testé : un bundle de Paris est construit en 10 secondes.
- `redis.conf` : le fichier d'exemple de 106 Ko est remplacé par une configuration de 15 lignes.
- Standalone : le bundle n'est retéléchargé que s'il a changé, utilisateur non-root, démarrage possible avec les données existantes si le téléchargement échoue. Testé.
- Ajout de `tests/smoke.sh` et de la CI GitHub Actions.
- README réécrit : fonctionnement, installation, mise à jour automatique, paramètres, licences.
- Validation finale sur une copie propre du projet : toutes les étapes du CI passent en local.

**15/10/2026 : installeur**
- Création de `install.sh`, qui fait tout en une commande :
  1. vérifie les prérequis ;
  2. construit les images ;
  3. télécharge ou met à jour les données ;
  4. démarre l'instance dans tous les cas et vérifie qu'elle répond ;
  5. installe la tâche cron.
- Options `--cron=daily|weekly|none` et `-y`. On peut le relancer sans risque : la tâche cron est remplacée, jamais dupliquée, et les autres tâches de l'utilisateur sont conservées.
- Testé (avec un faux crontab et le bundle de Paris) :
  - installation neuve ;
  - relance avec l'instance arrêtée et les données à jour (elle redémarre) ;
  - passage en hebdomadaire ;
  - retrait du cron ;
  - exécution de la ligne cron dans l'environnement minimal de cron.

**15/10/2026 : premier lancement réel (France entière)**
- `./install.sh` : bundle France téléchargé (16 minutes), mais le conteneur addok restait « unhealthy ». Cause : le `addok.conf` actuel de la BAN ne se termine pas par un saut de ligne, et la première option ajoutée par `docker-entrypoint.sh` était collée à sa dernière ligne (`SQLITE_DB_PATH = 'dist/addok.db'LOG_DIR = '/logs'`), ce qui fait une erreur de syntaxe Python. Les workers gunicorn plantaient en boucle. Le bug existait déjà dans addok-docker. Correction : un saut de ligne est ajouté après la copie.
- 9 tests sur 9 avec les données de France. Redis occupe environ 3,1 Go de RAM (et non 6).
- Fréquence choisie : **quotidienne** (cron tous les jours à 5h30).

**15/10/2026 : mise à jour sans coupure, alertes, licence**
- Architecture **bleu/vert** : un proxy nginx (image `nginx-unprivileged`, sans root) sur le port 7878 et deux instances `blue` et `green`, avec chacune son addok, son Redis et ses données (`addok-data-blue/`, `addok-data-green/`). Une seule tourne en temps normal.
- `update-data.sh` prépare les nouvelles données dans le dossier de l'instance arrêtée, la démarre, vérifie qu'elle répond, bascule le proxy (`nginx -s reload` : les requêtes en cours se terminent), puis arrête l'ancienne. Si les nouvelles données ne fonctionnent pas, l'ancienne instance n'a jamais cessé de répondre.
- **Garde-fou RAM** : deux instances demandent deux fois plus de mémoire pendant 1 à 2 minutes. Le script compare la mémoire de Redis + 30 % + 512 Mo avec la RAM disponible. S'il n'y en a pas assez, il fait la mise à jour avec coupure (arrêt de l'ancienne instance d'abord, puis redémarrage de l'ancienne si les nouvelles données échouent). Forçable avec `HOT_SWAP=always|never`. Sur la machine actuelle : 4,5 Go nécessaires pour environ 4,3 Go disponibles en journée, donc la bascule se fait aujourd'hui avec coupure. Libérer un peu de RAM suffit pour passer sans coupure.
- Migration automatique de l'ancienne organisation (`addok-data/` → `addok-data-blue/`, anciens conteneurs remplacés), faite par `install.sh` ou `update-data.sh`. Faite sur l'instance réelle (une coupure d'environ 20 secondes, une seule fois).
- **Alertes Discord** : en cas d'échec de mise à jour, un message donne la cause et l'état de l'instance. Webhook dans `alert.conf` (non versionné, droits 600), configurable avec `./install.sh --discord-webhook=URL`. `./notify.sh --test` pour tester ; `ALERT_ON_SUCCESS=1` pour être prévenu aussi des réussites.
- `ADDOK_PORT` dans `.env` pour changer le port.
- Testé sur une copie isolée avec les données de Paris :
  - migration depuis l'ancienne organisation : 9 tests sur 9 ;
  - mise à jour sans coupure sous requêtes continues : **0 requête en échec sur 63** ;
  - mise à jour avec coupure (`HOT_SWAP=never`) : 8 secondes de coupure avec Paris ;
  - bundle cassé, sans coupure : rejeté, 0 requête en échec, alerte envoyée ;
  - bundle cassé, avec coupure : retour automatique aux anciennes données, alerte envoyée ;
  - `docker compose down` / `up -d` ;
  - échappement JSON des messages (guillemets, antislash, retours à la ligne).
- Bug trouvé lors du déploiement réel : sans fichier `.env` (première exécution), `install.sh` s'arrêtait sans message. Corrigé.
- CI : construction avec `--profile '*'`, tests de la mise à jour sans coupure (0 échec exigé) et du bundle cassé, publication de l'image `proxy`.
- **Licence MIT** pour le projet (fichier `LICENSE`, au nom de Faniry2).
- **addok-csv conservé** avec notre correctif : il fonctionne, et la construction de l'image échoue si le correctif ne s'applique plus.

**15/10/2026 : surveillance de l'instance**
- `check-health.sh`, lancé par cron toutes les 5 minutes (installé par `install.sh`, `--watch=off` pour le retirer). Il interroge `/health` et fait une recherche de test à travers le proxy. Une panne est déclarée après 3 essais ratés à 20 secondes d'intervalle. L'alerte Discord donne la cause (proxy arrêté, instance injoignable (502), recherche vide) et l'état des conteneurs. Il n'y a qu'une alerte par panne, puis un rappel toutes les 6 heures, et un message au retour du service. Rien n'est vérifié pendant une mise à jour : le script teste le verrou de `update-data.sh` sans le garder. L'état est dans `run/health-state`.
- Testé avec un faux webhook : instance saine, panne, panne qui continue (pas de doublon), rappel après 6 h, retour du service, mise à jour en cours. Exécution testée aussi dans l'environnement minimal de cron. Le cas 502 (proxy en marche, addok arrêté) n'a pas été provoqué sur l'instance réelle.
- `install.sh` : les tâches cron sont gérées par une fonction commune (marqueur + ligne), la tâche de mise à jour et celle de surveillance sont indépendantes.
- **Bug trouvé : relancer `install.sh` redémarrait l'instance** (coupure d'environ 20 secondes), parce que les images changeaient d'identifiant à chaque construction. Deux causes : addok et Redis étaient construits deux fois sous le même nom (services blue et green, avec des étiquettes différentes), et BuildKit ajoute une attestation de provenance horodatée. Corrections : seuls les services blue construisent les images, les services green les réutilisent (`pull_policy: never`, pour ne jamais télécharger une image du même nom sur Docker Hub), et `install.sh` construit avec `BUILDX_NO_DEFAULT_ATTESTATIONS=1`. Vérifié : identifiants stables et conteneurs non recréés.

**19/10/2026 : test en conditions réelles (fichier OGRB, 35 711 points d'intérêt, France entière)**
- Fichier `Donnees_ogrb_2026___france_entiere_ref_geo_2025___poi___n_OGRB.txt` : séparateur `;`, **encodage Windows-1252** (espaces insécables), 43 colonnes. Adresse en `NUMVOIE` + `TYPEVOIE` + `NOMVOIE`, avec `code_postal`, `villenorm` et `depcom` (code INSEE). `COMPVOIE` (centres commerciaux, lieux-dits) écarté. Le fichier contient déjà un géocodage de référence (`longitude`, `latitude`, `qualitegeorue`), qui a servi de comparaison.
- Premier résultat (filtre `citycode=depcom`, puis seconde passe « adresse + code postal + ville » sur les lignes vides, en ne gardant que les résultats dans la bonne commune) : 98,5 % des lignes géocodées, mais seulement 77,5 % au numéro, contre 81 % pour la référence.
- Résultat après la correction d'addok-fr (voir plus bas) :
  - 98,7 % des lignes géocodées : 81,3 % au numéro, 15,8 % à la rue, 1,7 % au lieu-dit ou à la commune, 1,3 % sans résultat (453 lignes) ;
  - écart avec la référence : 71,5 % à moins de 10 m, 88 % à moins de 50 m, 97,3 % à moins de 1 km ; numéro trouvé des deux côtés : écart médian de 0 m ;
  - débit : environ 420 adresses par seconde (85 s pour le fichier complet).
- Constats sur la qualité :
  - le filtre `citycode` donne parfois de moins bons résultats que l'adresse complète en texte libre (« RUE VICOMTE » à Caudebec-en-Caux n'est trouvée qu'avec la ville dans la requête) ;
  - écarts de plus de 1 km : surtout des communes fusionnées (Saint-Macaire-en-Mauges → Sèvremoine, Campeaux → Souleuvre en Bocage) et La Réunion (Saint-Gilles-les-Bains, La Saline → Saint-Paul), où une adresse homonyme est trouvée ailleurs dans la nouvelle commune ;
  - addok-csv laisse vide tout résultat de score inférieur à 0,5 (`CSV_MIN_SCORE`) : c'est la cause des lignes sans résultat ;
  - les lignes sans résultat sont surtout des adresses vagues (« CENTRE URBAIN », « LOTISSEMENT BOURG »), plus nombreuses dans les DOM et en Corse.
- **Deux limites de `/search/csv` trouvées et corrigées** :
  1. **Tout fichier de plus de 1 Mo (environ 10 000 adresses) était refusé** (HTTP 400, « body part is too large ») : c'est la limite par défaut de Falcon pour un fichier envoyé, que `client_max_body_size 0` du proxy ne pouvait pas lever. Correction : nouveau point d'entrée `addok/infostat_wsgi.py`, qui relève la limite à `CSV_MAX_SIZE_MB` (50 Mo par défaut), sans toucher au code d'addok.
  2. **Un traitement de plus de 30 s échouait** (HTTP 500, `WORKER TIMEOUT` de gunicorn). Avec un seul worker, un gros fichier aurait en plus bloqué toutes les autres requêtes, le healthcheck et `check-health.sh` (fausses alertes Discord). Correction : `WORKER_TIMEOUT` passe à 300 s, comme `proxy_read_timeout`, et `WORKERS` passe de 1 à 4 (environ 55 Mo de RAM chacun).
- Testé sur l'instance réelle :
  - le nouveau test « CSV de plus de 1 Mo » échoue avant la correction et passe après (10 tests sur 10) ;
  - le fichier complet (3,1 Mo, 35 711 lignes) passe en une seule requête en 127 s ;
  - pendant ce traitement, 63 recherches ont répondu en 10 ms au plus, et le healthcheck est resté au vert ;
  - le redéploiement n'a recréé que le conteneur addok (environ 1 seconde de coupure).
- README : paramètres `WORKERS`, `WORKER_TIMEOUT`, `CSV_MAX_SIZE_MB`, et nouvelle section « Géocodage de fichiers CSV ».
- **Défaut de recherche trouvé et corrigé : mauvaise version d'addok-fr.** La ligne 4 (20 avenue du Général Sarrail, Ambérieu) n'était trouvée qu'à la rue, alors que le géocodage inverse trouvait le n° 20 exactement au point de la référence. Cause : l'index de la BAN est construit avec addok-fr 1.0.1, mais la modernisation du 15/10 avait installé addok-fr 1.1.0, qui change une quinzaine de règles de phonétique et ajoute des synonymes. Les numéros de 1 à 20 passent par les synonymes (20 → « vingt ») : l'index range le n° 20 sous `ving`, la 1.1.0 cherchait `vin`. Même chose pour 16 (`seiz`/`sez`), 13 (`treiz`/`trez`) et des mots des noms de voie (vicomte : `vikomt`/`vikont`). J'avais d'abord conclu à tort que ces numéros manquaient dans la BAN.
  - Trois combinaisons comparées sur tout le fichier, avec deux instances de test branchées sur le même Redis que la production : addok-fr 1.1.0 + addok-france 1.2.0 (avant) : 77,5 % au numéro ; addok-fr 1.0.1 + addok-france 1.1.3 (versions d'origine) : 81,25 % ; **addok-fr 1.0.1 + addok-france 1.2.0 : 81,3 %, 453 lignes sans résultat au lieu de 527 (retenue)**. addok-france 1.2.0 reconnaît plus d'abréviations (`QUART`, `CHE`…) : sur les 60 lignes où les deux dernières combinaisons diffèrent, elle est plus proche de la référence 45 fois sur 59.
  - 1 314 lignes passent de la rue au numéro ; la position se rapproche de la référence de plus de 50 m pour 699 lignes, et s'en éloigne pour 32.
  - `addok/requirements.txt` : addok-fr fixé à 1.0.1, avec un commentaire qui explique pourquoi.
  - addok-fr 1.0.1 garde la phonétique de chaque mot dans un cache sans limite. Les workers sont donc remplacés toutes les 20 000 requêtes (`WORKER_MAX_REQUESTS`, `--max-requests` de gunicorn).
  - Nouveau test « numéro écrit en lettres » dans `tests/smoke.sh` (20 avenue de Ségur doit être trouvé au numéro) : il échoue avec addok-fr 1.1.0 et passe avec 1.0.1 (11 tests sur 11). Le test de compatibilité de la CI (9 tests) ne voyait pas le problème : les recherches répondaient, mais au niveau de la rue.
  - Redéployé sur l'instance réelle (seul le conteneur addok est recréé, environ 1 seconde de coupure). Instances et images de test supprimées.
- **Lignes vides et seuil de score (0,5).** Cas de départ : « 4 PLACE CHARLES GINESY, PEONE » restait vide alors que le code postal et la commune étaient bien dans la requête. La place a changé de nom : la BAN connaît « 4 Place Thomas Guérin », exactement au point de la référence. Le géocodeur l'avait trouvée, mais avec un score de 0,43 (0,33 avec le filtre commune), sous le seuil d'addok-csv.
  - Mesure sur les 453 lignes vides, avec les réponses sous le seuil : la plupart sont fausses. Entre 0,4 et 0,5, seules 22 % sont à moins de 50 m de la référence (28 % dans la bonne commune). Même la règle la plus stricte (bonne commune + numéro demandé + score de 0,4 à 0,5) se trompe une fois sur trois (10 justes sur 15, 3 à plus de 1 km). **Le seuil de 0,5 est conservé.**
  - Le seuil existait déjà en réglage : `-F min_score=0.4` pour une requête, `ADDOK_CSV_MIN_SCORE` pour toute l'instance (lu par addok au démarrage). C'est maintenant documenté dans le README, avec la mesure qui le déconseille.
  - **Nouveau : colonnes « candidat à vérifier ».** Pour une ligne restée vide, `/search/csv` donne quand même la meilleure réponse dans `result_candidat_label`, `_score`, `_type`, `_latitude` et `_longitude`, sans remplir `latitude`/`longitude`. Codé dans `addok/infostat_wsgi.py` (sous-classe de la vue d'addok-csv, qui remplace sa route), sans toucher au code d'addok-csv. Sur le fichier OGRB : 1 761 des 2 055 lignes vides de la passe 1 ont un candidat ; 559 sont à moins de 50 m de la référence et 653 à plus de 1 km, d'où la vérification à la main. Coût : le fichier complet passe en 112 s au lieu de 85 s (une seconde recherche pour chaque ligne vide).
  - Nouveau test « CSV : colonnes candidat » (12 tests sur 12). Testé sur une instance à part, puis redéployé (environ 1 seconde de coupure).
- Analyse complète dans `analyses/ogrb-2026-10-19/` : `CONCLUSION.md` (chiffres par précision, par région, causes des écarts, recommandations) et `carte-comparaison.html` (référence et géocodeur sur deux cartes synchronisées).

## Reste à faire

### Projet
- [ ] Choisir le nom définitif du projet et renommer le dossier `addok-docker-master` (le nom provisoire est `geocodeur-infostat`, utilisé pour les images, les conteneurs et le marqueur cron). Attention : renommer le dossier casse la ligne cron, il faut relancer `./install.sh` après
- [ ] Créer le dépôt git distant (GitHub) et y pousser le projet. La CI n'a pas encore tourné sur GitHub, elle a seulement été rejouée en local
- [ ] Vérifier le titulaire du copyright dans `LICENSE` (Faniry2 ou l'organisation)
- [ ] Tester les images en `linux/arm64` sur une vraie machine ARM (la CI les construit sans les tester ; la machine actuelle n'a pas l'émulation ARM)

### Améliorations possibles
- [ ] Script de géocodage de fichiers (`geocode-file.sh`) : conversion de l'encodage, découpage des fichiers de plus de 50 000 lignes, seconde passe « adresse + code postal + ville » sur les lignes vides avec contrôle de la commune, puis bilan. C'est ce qui a été fait à la main pour le fichier OGRB le 19/10/2026
- [ ] Comprendre pourquoi le filtre `citycode` trouve moins bien que l'adresse complète en texte libre (comportement des filtres dans addok), et choisir la stratégie par défaut
- [ ] Communes fusionnées : utiliser `oldcity` et `oldcitycode` de la BAN pour mieux trouver les adresses dont la ville est l'ancienne commune
- [ ] Afficher les candidats à vérifier sur la carte d'analyse, avec un bouton « accepter » ou « rejeter » pour corriger les lignes vides à la main
- [ ] Vérifier un échantillon tiré au hasard parmi les 3 036 écarts de plus de 100 m (photos aériennes) pour savoir qui, de la référence ou de nous, est le plus juste
- [ ] Si la RAM manque souvent pour la bascule sans coupure, augmenter la RAM de la machine

### À surveiller
- [ ] Redis 8 est sous AGPLv3, RSALv2 ou SSPLv1. Rien à faire en interne ; si ça pose problème, Valkey (licence BSD) peut le remplacer
- [ ] La CI vérifie chaque semaine (`compat-ban`) que le bundle BAN du moment fonctionne toujours avec nos images : surveiller les échecs, par exemple si la BAN change de version de Redis ou d'addok
- [ ] Passer à Python 3.15 quand addok le prendra en charge
- [ ] Suivre les nouvelles versions d'addok : https://github.com/addok/addok/blob/master/CHANGELOG.md
- [ ] **Ne pas monter addok-fr** au-delà de 1.0.1 tant que la BAN construit son index avec cette version. Si la BAN change de version, le test « numéro écrit en lettres » de `compat-ban` échouera : passer alors à la même version qu'elle
