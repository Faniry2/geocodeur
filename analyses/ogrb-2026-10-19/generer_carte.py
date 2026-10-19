"""Génère carte-comparaison.html : référence OGRB et géocodeur Infostat sur deux cartes synchronisées.

Usage (depuis la racine du projet) :
    python3 -I analyses/ogrb-2026-10-19/generer_carte.py SOURCE.txt RESULTAT.csv

SOURCE.txt   : fichier OGRB d'origine (séparateur ;, encodage Windows-1252)
RESULTAT.csv : résultat du géocodage (séparateur ;, UTF-8), colonnes ligne, adresse, ... dist_m, passe,
               et pour les lignes vides, si présentes : candidat_label, candidat_type, candidat_score,
               candidat_longitude, candidat_latitude, candidat_dist_m (candidat à vérifier, score < 0,5)
"""
import csv
import json
import os
import sys


def main(source, resultat):
    texte = open(source, "rb").read().decode("cp1252").replace("\xa0", " ")
    meta = {str(i): d for i, d in enumerate(csv.DictReader(texte.splitlines(), delimiter=";"), 2)}

    points = []
    with open(resultat, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter=";"):
            m = meta[r["ligne"]]
            geocode = bool(r["result_type"])
            candidat = bool(r.get("candidat_label"))
            points.append([
                int(r["ligne"]),
                m["NOM"],
                r["adresse"],
                r["code_postal"],
                r["ville"],
                r["ref_qualite"],
                round(float(r["ref_lon"]), 6),
                round(float(r["ref_lat"]), 6),
                r["result_label"],
                r["result_type"],
                round(float(r["result_score"]), 2) if geocode else None,
                round(float(r["longitude"]), 6) if geocode else None,
                round(float(r["latitude"]), 6) if geocode else None,
                int(r["dist_m"]) if geocode else None,
                int(r["passe"]) if r["passe"] else 0,
                r["candidat_label"] if candidat else None,
                r["candidat_type"] if candidat else None,
                round(float(r["candidat_score"]), 2) if candidat else None,
                round(float(r["candidat_longitude"]), 6) if candidat else None,
                round(float(r["candidat_latitude"]), 6) if candidat else None,
                int(r["candidat_dist_m"]) if candidat else None,
            ])

    gabarit = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "gabarit.html"), encoding="utf-8").read()
    donnees = json.dumps(points, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    sortie = os.path.join(os.path.dirname(os.path.abspath(__file__)), "carte-comparaison.html")
    with open(sortie, "w", encoding="utf-8") as f:
        f.write(gabarit.replace("/*__DONNEES__*/[]", donnees))
    print(f"{sortie} : {len(points)} points, {os.path.getsize(sortie) / 1e6:.1f} Mo")


if __name__ == "__main__":
    main(*sys.argv[1:3])
