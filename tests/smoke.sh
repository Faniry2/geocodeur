#!/bin/bash
# Tests fonctionnels d'une instance addok (données de Paris au minimum)
# Usage : tests/smoke.sh [URL de l'instance, par défaut http://localhost:7878]
B=${1:-http://localhost:7878}
ok=0; ko=0
check() { if eval "$2" >/dev/null 2>&1; then echo "OK  $1"; ok=$((ok+1)); else echo "KO  $1"; ko=$((ko+1)); fi; }
j() { curl -sf "$B$1" | python3 -c "import sys,json;d=json.load(sys.stdin);$2" 2>/dev/null; }

echo "health: $(curl -s $B/health)"
echo "search: $(j '/search?q=1+rue+de+la+paix+paris&limit=1' 'p=d["features"][0]["properties"];print(p["label"],round(p["score"],2))')"
echo "faute : $(j '/search?q=8+bd+du+port+royal+pari&limit=1' 'print(d["features"][0]["properties"]["label"])')"
echo "revers: $(j '/reverse?lon=2.3316&lat=48.8687' 'print(d["features"][0]["properties"]["label"])')"
check "recherche adresse"        "j '/search?q=1+rue+de+la+paix+paris' 'assert \"Rue de la Paix\" in d[\"features\"][0][\"properties\"][\"label\"]'"
check "tolérance fautes"         "j '/search?q=ru+de+la+pai+75002' 'assert \"Paix\" in d[\"features\"][0][\"properties\"][\"label\"]'"
check "autocomplétion"           "j '/search?q=avenue+des+champs+ely&autocomplete=1' 'assert \"Champs\" in d[\"features\"][0][\"properties\"][\"label\"]'"
check "géocodage inverse"        "j '/reverse?lon=2.3316&lat=48.8687' 'assert d[\"features\"]'"
check "filtre type"              "j '/search?q=paris&type=street' 'assert d[\"features\"] and all(f[\"properties\"][\"type\"]==\"street\" for f in d[\"features\"])'"
check "filtre multi-valeurs"     "j '/search?q=paris&type=street+municipality&limit=20' 'assert d[\"features\"]'"
check "filtre postcode"          "j '/search?q=rue&postcode=75007' 'assert all(f[\"properties\"][\"postcode\"]==\"75007\" for f in d[\"features\"])'"
# Les numéros de 1 à 20 passent par les synonymes (20 → vingt) puis la phonétique : ce test échoue si
# la version d'addok-fr ne correspond pas à celle qui a construit l'index (numéro trouvé seulement à la rue)
check "numéro écrit en lettres"  "j '/search?q=20+avenue+de+segur+75007' 'assert d[\"features\"][0][\"properties\"][\"type\"]==\"housenumber\"'"
check "champs BAN (citycode)"    "j '/search?q=1+rue+de+la+paix+paris' 'assert d[\"features\"][0][\"properties\"][\"citycode\"]'"
csv=$(mktemp); printf 'adresse,cp\n"20 avenue de ségur",75007\n"1 rue de la paix",75002\n' > "$csv"
out=$(curl -sf -F data=@"$csv" -F columns=adresse -F postcode=cp "$B/search/csv/"); rm -f "$csv"
echo "csv   : $(echo "$out" | tail -1)"
check "géocodage CSV"            "echo \"\$out\" | grep -q 'Avenue de Ségur'"
check "CSV : colonnes candidat"  "echo \"\$out\" | head -1 | grep -q result_candidat_label"
# Fichier de plus de 1 Mo (limite par défaut de Falcon, relevée par CSV_MAX_SIZE_MB)
big=$(mktemp); python3 -c "
pad = 'x' * 100000
print('adresse,cp,pad')
for _ in range(12): print('\"1 rue de la paix\",75002,' + pad)" > "$big"
big_out=$(curl -sf -F data=@"$big" -F columns=adresse -F postcode=cp "$B/search/csv/" | grep -c 'Rue de la Paix'); rm -f "$big"
check "CSV de plus de 1 Mo"      "[[ '$big_out' == 12 ]]"
echo "--- $ok OK, $ko KO"
[[ $ko -eq 0 ]]
