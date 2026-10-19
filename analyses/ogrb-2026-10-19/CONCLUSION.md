# Comparaison du géocodage : fichier OGRB 2026 et géocodeur Infostat

Test du 19/10/2026, avec la BAN chargée le 15/10/2026 (addok 1.3.2, addok-fr 1.0.1, addok-france 1.2.0).

## En bref

Le géocodeur trouve **98,7 % des 35 711 points d'intérêt**, dont **81,3 % au numéro**, contre 81,0 % pour la référence. Quand le numéro est trouvé des deux côtés, la position est la même que dans la référence (écart médian : 0 m). Il est donc **utilisable en production pour la France métropolitaine**. Les écarts restants viennent surtout des communes fusionnées, de la Corse, des DOM et des adresses vagues.

La comparaison a fait apparaître **un défaut de notre géocodeur, corrigé le jour même** (voir plus bas) : la version d'addok-fr ne correspondait pas à celle qui a construit l'index de la BAN. Avant la correction, on n'était qu'à 77,5 % au numéro.

Le fichier se traite en **une seule requête d'environ 85 s** (environ 420 adresses par seconde), depuis la correction des limites de `/search/csv` faite le même jour (voir `TODO.md`).

## Données

- **Fichier :** `Donnees_ogrb_2026___france_entiere_ref_geo_2025___poi___n_OGRB.txt`, 35 711 points d'intérêt (La Poste, agences bancaires, courtiers…), France entière avec les DOM.
- **Format :** séparateur `;`, 43 colonnes, **encodage Windows-1252** (il contient des espaces insécables : ce n'est pas de l'ASCII pur).
- **Adresse géocodée :** `NUMVOIE` + `TYPEVOIE` + `NOMVOIE`, avec `depcom` (code INSEE), `code_postal` et `villenorm`. `COMPVOIE` est écarté : il contient des noms de centres commerciaux ou de lieux-dits, parfois une deuxième adresse.
- **Référence :** `longitude`, `latitude` et `qualitegeorue` (« géocodage 2025 »). La précision de la référence se répartit ainsi : numéro 81 %, rue 17 %, commune 1,7 %, lieu-dit 0,6 %. `qualitegeorue` reprend exactement les types d'addok : la référence a très probablement été faite avec le même moteur et la BAN de 2025.

## Méthode

1. **Passe 1 :** `q` = adresse, filtre `citycode` = `depcom`. 33 656 lignes trouvées.
2. **Passe 2**, sur les lignes restées vides : `q` = adresse + code postal + ville, sans filtre. Un résultat n'est gardé que s'il tombe dans la bonne commune (`citycode` ou `oldcitycode` égal à `depcom`). 1 602 lignes ont été récupérées de cette façon.
3. **Écart :** distance à vol d'oiseau entre la position trouvée et celle de la référence.

addok-csv laisse vide tout résultat de score inférieur à 0,5. Une ligne « sans résultat » est donc une ligne dont la meilleure réponse était trop douteuse, et pas forcément une adresse introuvable.

## Défaut trouvé et corrigé : version d'addok-fr

La ligne 4 (La Poste, 20 avenue du Général Sarrail, Ambérieu-en-Bugey) n'était trouvée qu'à la rue, alors que le géocodage inverse trouvait bien le n° 20, exactement au point de la référence.

- **Cause :** l'index de la BAN est construit avec **addok-fr 1.0.1**. La modernisation du 15/10/2026 avait installé **addok-fr 1.1.0** (novembre 2025), qui modifie une quinzaine de règles de phonétique et ajoute des synonymes.
- **Effet :** les numéros de 1 à 20 passent par les synonymes (20 → « vingt »). L'index range le n° 20 sous `ving`, mais la version 1.1.0 cherchait `vin`. De même, 16 était rangé sous `seiz` et cherché sous `sez`, et 13 rangé sous `treiz` et cherché sous `trez`. Le même décalage touchait des mots des noms de voie (vicomte : `vikomt` dans l'index, `vikont` dans la requête).
- **Correction :** addok-fr est revenu à 1.0.1, en gardant addok-france 1.2.0, qui reconnaît plus d'abréviations (`QUART`, `CHE`…). Trois combinaisons ont été comparées sur tout le fichier :

| Combinaison | Au numéro | Sans résultat | ≤ 10 m de la réf. | Moins précis que la réf. |
|---|---:|---:|---:|---:|
| addok-fr 1.1.0 + addok-france 1.2.0 (avant) | 77,5 % | 527 | 68,6 % | 2 865 |
| addok-fr 1.0.1 + addok-france 1.1.3 (versions d'origine) | 81,25 % | 485 | 71,6 % | 1 545 |
| **addok-fr 1.0.1 + addok-france 1.2.0 (retenue)** | **81,3 %** | **453** | **71,5 %** | **1 513** |

Entre l'ancienne et la nouvelle version, 1 314 lignes passent de la rue au numéro. La position se rapproche de la référence de plus de 50 m pour 699 lignes, et s'en éloigne pour 32. Un test (`tests/smoke.sh`, « numéro écrit en lettres ») détecte désormais ce problème.

## Résultats

| Précision trouvée | Lignes | % | Score médian |
|---|---:|---:|---:|
| Numéro | 29 027 | 81,3 % | 0,88 |
| Rue | 5 633 | 15,8 % | 0,77 |
| Lieu-dit | 312 | 0,9 % | 0,69 |
| Commune | 286 | 0,8 % | 0,62 |
| Sans résultat | 453 | 1,3 % | — |

| Écart avec la référence | Lignes | % des géocodées |
|---|---:|---:|
| ≤ 10 m | 25 226 | 71,5 % |
| 10 à 50 m | 5 820 | 16,5 % |
| 50 à 100 m | 1 176 | 3,3 % |
| 100 m à 1 km | 2 128 | 6,0 % |
| > 1 km | 908 | 2,6 % |

Sur les 28 068 lignes trouvées au numéro des deux côtés, 23 286 (83 %) sont à moins de 10 m et 551 (2 %) à plus de 100 m.

La passe 2 est nettement moins précise que la passe 1 :

| | Lignes | Écart médian | Écart > 1 km |
|---|---:|---:|---:|
| Passe 1 | 33 656 | 0 m | 478 (1,4 %) |
| Passe 2 | 1 602 | 200 m | 430 (27 %) |

Elle récupère beaucoup de lignes au niveau de la commune ou du lieu-dit. **Il faut s'en servir pour compléter, et la signaler comme telle** (colonne `passe` du fichier résultat).

### Comparaison des précisions

| Référence ↓ / trouvé → | Numéro | Rue | Lieu-dit | Commune | Aucun |
|---|---:|---:|---:|---:|---:|
| Numéro (28 917) | **28 068** | 766 | 28 | 2 | 53 |
| Rue (5 983) | 824 | **4 664** | 147 | 101 | 247 |
| Lieu-dit (221) | 31 | 89 | **60** | 16 | 25 |
| Commune (590) | 104 | 114 | 77 | **167** | 128 |

Notre géocodeur est moins précis que la référence sur 1 513 lignes, et plus précis sur 1 239 lignes : il trouve par exemple au numéro 824 adresses que la référence ne plaçait qu'à la rue, grâce à la BAN de 2026.

### Par région

| Région | Points | Au numéro | Sans résultat | Écart > 1 km |
|---|---:|---:|---:|---:|
| Île-de-France | 4 615 | 92,8 % | 0,3 % | 0,5 % |
| Grand Est | 2 977 | 91,9 % | 0,3 % | 1,0 % |
| Hauts-de-France | 2 733 | 88,6 % | 0,5 % | 1,0 % |
| Centre-Val de Loire | 1 640 | 87,6 % | 0,9 % | 1,2 % |
| Pays de la Loire | 2 043 | 85,7 % | 0,6 % | 2,6 % |
| Bourgogne-Franche-Comté | 2 006 | 84,6 % | 0,7 % | 1,2 % |
| Bretagne | 1 924 | 84,3 % | 1,3 % | 2,0 % |
| Normandie | 1 816 | 83,8 % | 0,8 % | 2,5 % |
| Nouvelle-Aquitaine | 4 149 | 78,3 % | 1,3 % | 3,1 % |
| Auvergne-Rhône-Alpes | 4 632 | 75,7 % | 1,5 % | 3,1 % |
| Occitanie | 3 801 | 71,2 % | 1,4 % | 4,1 % |
| Provence-Alpes-Côte d'Azur | 2 494 | 69,9 % | 1,9 % | 3,7 % |
| La Réunion | 232 | 87,1 % | 0,9 % | 8,6 % |
| Mayotte | 40 | 52,5 % | 22,5 % | 10,0 % |
| Guyane | 48 | 35,4 % | 14,6 % | 10,4 % |
| Martinique | 135 | 29,6 % | 9,6 % | 11,9 % |
| Guadeloupe | 127 | 18,1 % | 11,8 % | 11,8 % |
| **Corse** | 294 | **17,3 %** | **22,4 %** | **22,4 %** |

Plus une région est urbaine, meilleur est le résultat. Les régions rurales et montagneuses (Occitanie, PACA, Auvergne-Rhône-Alpes) ont plus d'adresses sans numéro ou en lieu-dit. **La Corse et les Antilles sont nettement en dessous** : la BAN y est moins complète, et beaucoup d'adresses sont des lieux-dits.

Par réseau, La Poste a le taux le plus bas au numéro (71,7 %, contre 81 à 92 % pour les banques) : beaucoup de bureaux sont en zone rurale et ont une adresse sans numéro.

### Lignes sans résultat : faut-il baisser le seuil ?

Exemple : « 4 PLACE CHARLES GINESY, PEONE » reste vide alors que le code postal et la commune sont bien dans la requête. La place a changé de nom : la BAN connaît « 4 Place Thomas Guérin », exactement au point de la référence. Le géocodeur l'a trouvée, mais avec un score de 0,43, sous le seuil de 0,5.

Sur les 453 lignes vides, la plupart des réponses sous le seuil sont pourtant **fausses** :

| Règle pour accepter une réponse sous 0,5 | Lignes | À moins de 50 m de la réf. | À plus de 1 km |
|---|---:|---:|---:|
| Toutes les réponses de 0,4 à 0,5 | 238 | 22 % | 123 |
| + dans la bonne commune | 192 | 28 % | 77 |
| + au numéro demandé (cas de Péone) | 15 | 67 % | 3 |

Le seuil de 0,5 est donc conservé. À la place, le géocodeur donne maintenant, pour chaque ligne vide, **un candidat à vérifier** dans des colonnes à part (`result_candidat_*`). Sur ce fichier, 1 761 lignes vides de la passe 1 en ont un : 559 sont à moins de 50 m de la référence, et 653 à plus de 1 km. Après la passe 2, il reste 453 lignes vides, dont 314 avec un candidat (45 à moins de 50 m de la référence, 140 à plus de 1 km). Ces 314 candidats se vérifient sur la carte, avec les boutons « Accepter » et « Rejeter », puis s'exportent en CSV.

## Causes des écarts restants

1. **Communes fusionnées :** par exemple Saint-Macaire-en-Mauges, devenue Sèvremoine, ou Campeaux, devenue Souleuvre en Bocage. Une adresse homonyme est trouvée ailleurs dans la nouvelle commune. Sur les 908 écarts de plus de 1 km, au moins 168 sont dans ce cas, où le libellé de la ville trouvée diffère de celui du fichier.
2. **DOM :** à La Réunion, Saint-Gilles-les-Bains et La Saline font partie de Saint-Paul, une commune très étendue où les homonymes sont nombreux. En Guyane, les villages isolés (Taluhen, Camopi, Apatou) sont placés au centre de la commune, à plusieurs dizaines de kilomètres.
3. **Adresses vagues :** sur les 453 lignes sans résultat, 334 n'ont pas de numéro (« CENTRE URBAIN », « LOTISSEMENT BOURG », « ROUTE MONTEE », « LIEU DIT… »).
4. **Filtre `citycode` :** avec le filtre, addok trouve parfois moins bien que si la ville est écrite dans la requête. C'est ce que corrige la passe 2.
5. **Différences entre la BAN de 2025 et celle de 2026 :** numéros ajoutés, déplacés ou renommés.

## Qui a raison quand les deux ne concordent pas ?

L'écart mesure la **concordance** entre les deux positions, pas leur **justesse** : la référence n'est pas une vérité terrain. Sur les critères mesurables, notre géocodeur est maintenant au niveau de la référence : 81,3 % au numéro contre 81,0 %. La référence place encore toutes les lignes, contre 98,7 % pour nous. Pour les positions qui diffèrent, il faut vérifier au cas par cas.

Cas vérifiés à la main :

| Ligne | Point d'intérêt | Écart | Plus juste | Vérification |
|---|---|---:|---|---|
| 2 | SG Auvergne-Rhône-Alpes, 1 avenue de Verdun, Ambérieu-en-Bugey | 340 m | **Géocodeur Infostat** | Notre point est le n° 1 de la BAN, au carrefour avec la rue Alexandre Bérard. L'agence s'y trouve bien (vérifié sur Google Maps). La référence est au milieu de l'avenue, où il n'y a aucun n° 1 |
| 4 | La Poste, 20 avenue du Général Sarrail, Ambérieu-en-Bugey | 203 m avant la correction, 0 m après | **Référence** avant la correction, **égalité** après | Le géocodeur ne trouvait que la rue (point au centre de l'avenue). C'est ce cas qui a révélé le défaut d'addok-fr. Depuis la correction, il trouve le n° 20, exactement au point de la référence |

| 6519 | BP, 1 rue Émile de Girardin, Bourganeuf | 120 m | **Référence** (erreur de la BAN) | L'agence est au point de la référence, et Google Maps y place aussi le n° 1 : l'adresse du fichier est juste. La BAN met le n° 1 à l'autre bout de la rue, et le point de la référence tombe entre ses n° 9 et 11. Les numéros impairs de la rue semblent inversés dans la BAN (le n° 1 devrait être au carrefour de l'avenue René Viviani, côté centre-ville). Notre géocodeur a trouvé le n° 1 de la BAN (score 0,95) : il ne peut pas corriger une erreur des données. À signaler sur adresse.data.gouv.fr ou à la mairie de Bourganeuf |

Trois cas ne permettent pas de conclure pour tout le fichier. Ils montrent cependant les trois situations possibles : notre position plus juste (référence approximative), égalité, et référence plus juste à cause d'une erreur dans la BAN. Dans ce dernier cas, la correction doit se faire dans la BAN : notre géocodeur la récupérera alors avec la mise à jour quotidienne des données. Pour trancher, il faudrait vérifier un échantillon tiré au hasard parmi les 3 036 écarts de plus de 100 m.

## Recommandations

- **Utiliser les résultats tels quels**, avec deux réserves :
  - garder la colonne `passe` et le type trouvé, pour distinguer un point au numéro d'un point au centre de la commune ;
  - vérifier à la main les 908 écarts de plus de 1 km, en commençant par ceux de la passe 2 (voir la carte).
- **Pour la Corse et les DOM**, garder la position de référence quand elle est plus précise que la nôtre.
- **Ne pas monter la version d'addok-fr** tant que la BAN construit son index avec la 1.0.1 (voir `addok/requirements.txt`).
- **Automatiser la méthode** dans un script (`geocode-file.sh` dans `TODO.md`) : conversion de l'encodage, passe 1, passe 2 contrôlée, bilan.
- **Pistes d'amélioration** (dans `TODO.md`) :
  - utiliser `oldcity` et `oldcitycode` pour les communes fusionnées ;
  - comprendre le comportement du filtre `citycode` ;

## Fichiers

| Fichier | Contenu |
|---|---|
| `carte-comparaison.html` | Deux cartes synchronisées (référence à gauche, géocodeur à droite), pins colorés selon l'écart et cliquables, filtres, liste des écarts, fonds photos aériennes IGN (par défaut), Plan IGN ou OSM. Candidats à vérifier en violet, avec les boutons « Accepter » et « Rejeter » et l'export des décisions en CSV. S'ouvre directement dans un navigateur ; les fonds de carte demandent internet |
| `generer_carte.py` + `gabarit.html` | Régénèrent la carte : `python3 -I analyses/ogrb-2026-10-19/generer_carte.py SOURCE.txt RESULTAT.csv` |
| `../../Donnees_ogrb_2026_resultat_geocodage.csv` | Résultat ligne par ligne, après correction (`;`, UTF-8) : adresse envoyée, référence, adresse trouvée, type, score, coordonnées, écart en mètres, passe |
