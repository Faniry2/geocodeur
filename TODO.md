# TODO – Géocodeur Infostat

Projet dérivé de `BaseAdresseNationale/addok-docker` (plus maintenu depuis le 31/10/2022), modernisé le 15/10/2026.

## Comment fonctionne le projet

**Addok** est un géocodeur libre développé par Etalab. Il transforme une adresse en coordonnées GPS (`/search?q=1 rue de la paix paris`) et des coordonnées GPS en adresse (`/reverse?lat=...&lon=...`). C'est le moteur de l'API officielle api-adresse.data.gouv.fr. Il tolère les fautes de frappe et fait de l'autocomplétion. Il est rapide parce que tout son index est chargé en mémoire dans Redis (environ 6 Go de RAM).

**Le principe :** chaque jour, la BAN rassemble les adresses de France, calcule l'index avec addok et publie le résultat sous forme de **bundle** (`addok-france-bundle.zip`, ~2,4 Go). Notre projet télécharge ce bundle (`update-data.sh`) et le sert avec addok. Addok n'est pas à nous, c'est une dépendance externe (licence MIT). Le projet, lui, est le nôtre.

```
           requêtes HTTP (port 7878)
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
                ▲ addok-data/ = bundle BAN décompressé (+ addok.conf)
```

**Pourquoi les données sont à part :** le logiciel change rarement et les adresses changent chaque jour. Les données restent donc dans un dossier monté (`addok-data/`), et non dans les images. L'index est déjà calculé par la BAN, ce qui évite plusieurs heures de calcul.

**Les 3 fichiers du bundle :**
- `dump.rdb` : l'index de recherche, que Redis charge en mémoire ;
- `addok.db` : les fiches complètes des adresses (SQLite, sur disque, pour économiser la RAM) ;
- `addok.conf` : les règles qui ont servi à construire l'index (phonétique, synonymes…). Addok doit appliquer exactement les mêmes règles aux recherches.

| Dossier / fichier | Rôle |
|---|---|
| `docker-compose.yml` | Instance principale : services `addok` et `redis` |
| `addok/` | Image du serveur : Python 3.14, addok et ses extensions, gunicorn. Elle sert aussi d'importeur (`docker-entrypoint.sh serve`, sinon commande `addok`) |
| `addok-redis/` | Image Redis 8.10 avec une config minimale. Elle charge `dump.rdb` au démarrage |
| `addok-standalone/` | Variante tout-en-un (supervisord). Elle télécharge le bundle seulement s'il a changé |
| `build-package/` | Fabrication de son propre bundle à partir de fichiers `.ndjson.gz` |
| `addok-data/` (non versionné) | Les données installées |
| `install.sh` | Installeur en une commande : prérequis, images, données, démarrage (même si les données sont à jour), cron |
| `update-data.sh` | Mise à jour automatique des données BAN, avec retour aux anciennes données en cas d'échec |
| `tests/smoke.sh` | 9 tests fonctionnels (recherche, fautes, autocomplétion, inverse, filtres, CSV) |
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
  - addok-fr → 1.1.0 ;
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

## Reste à faire

### Prioritaire
- [ ] **Premier lancement réel avec le bundle France** : `./install.sh`. Il faut environ 6 Go de RAM libres ; l'installeur prévient s'il en manque. Seules les données de Paris ont été testées jusqu'ici. Ce lancement installe aussi le vrai cron.
- [ ] Choisir la fréquence : quotidienne (`./install.sh`, 2,4 Go par jour) ou hebdomadaire (`./install.sh --cron=weekly`)
- [ ] Alerte en cas d'échec de la mise à jour (e-mail ou supervision du code retour)

### Projet
- [ ] Choisir le nom définitif du projet et renommer le dossier `addok-docker-master` (le nom provisoire est `geocodeur-infostat`, utilisé pour les images)
- [ ] Créer le dépôt git distant (GitHub) et y pousser le projet. La CI n'a pas encore tourné sur GitHub, elle a seulement été rejouée en local
- [ ] Licence : il ne reste presque rien des fichiers d'addok-docker (seul `build-package/addok.conf` reprend la config BAN). Choisir la licence du projet
- [ ] Tester les images en `linux/arm64` (la CI les construit, mais elles n'ont pas été testées sur une vraie machine ARM)

### Décisions à prendre
- [ ] **addok-csv est abandonné.** Ses auteurs recommandent [addok-server](https://github.com/livingdata-co/addok-server), un serveur Node.js. Il faut choisir entre garder addok-csv avec notre correctif, qui fonctionne aujourd'hui, et migrer vers addok-server, ce qui change l'architecture
- [ ] Supprimer la coupure de 1 à 2 minutes pendant les mises à jour : démarrer une 2ᵉ instance, puis basculer le trafic quand elle est prête
- [ ] Redis 8 est sous AGPLv3, RSALv2 ou SSPLv1. Rien à faire en interne ; si ça pose problème, Valkey (licence BSD) peut le remplacer

### À surveiller
- [ ] La CI vérifie chaque semaine (`compat-ban`) que le bundle BAN du moment fonctionne toujours avec nos images : surveiller les échecs, par exemple si la BAN change de version de Redis ou d'addok
- [ ] Passer à Python 3.15 quand addok le prendra en charge
- [ ] Suivre les nouvelles versions d'addok : https://github.com/addok/addok/blob/master/CHANGELOG.md
