# Point d'entrée WSGI : l'application addok, avec deux ajouts pour le géocodage de fichiers CSV.
#
# 1. Taille maximale des fichiers relevée. Falcon refuse par défaut tout fichier envoyé de plus de 1 Mo
#    (« body part is too large »), soit environ 10 000 adresses : trop peu pour /search/csv et /reverse/csv.
#
# 2. Candidat à vérifier. addok-csv laisse vide une ligne dont la meilleure réponse a un score inférieur
#    au seuil (CSV_MIN_SCORE, 0,5) : ces réponses sont fausses le plus souvent (mesure du 19/10/2026 sur
#    le fichier OGRB : 22 % à moins de 50 m de la référence). Certaines sont pourtant justes, par exemple
#    une place renommée (« 4 place Charles Ginesy » → « 4 Place Thomas Guérin » à Péone, score 0,43).
#    Pour ces lignes, la meilleure réponse est donnée dans des colonnes à part (result_candidat_*),
#    sans remplir latitude/longitude : elle sert à corriger la ligne à la main, pas à la placer.
import os

import falcon
from addok.config import config
from addok.core import search
from addok.http.wsgi import application
from addok_csv import CSVSearch

CSV_MAX_SIZE_MB = int(os.environ.get("CSV_MAX_SIZE_MB", "50"))

multipart = application.req_options.media_handlers[falcon.MEDIA_MULTIPART]
multipart.parse_options.max_body_part_buffer_size = CSV_MAX_SIZE_MB * 1024 * 1024

CANDIDAT_HEADERS = [
    "result_candidat_label",
    "result_candidat_score",
    "result_candidat_type",
    "result_candidat_latitude",
    "result_candidat_longitude",
]


class CSVSearchAvecCandidat(CSVSearch):
    @property
    def base_headers(self):
        return config.CSV_HEADERS + CANDIDAT_HEADERS

    def process_row(self, req, row, filters, columns, index):
        super().process_row(req, row, filters, columns, index)
        if row.get("result_label"):
            return
        # Ligne restée vide : même requête que addok-csv, sans seuil
        q = " ".join([row[k] or "" for k in columns])
        row_filters = self.match_row_filters(row, filters)
        lat, lon = row.get(req.get_param("lat") or ""), row.get(req.get_param("lon") or "")
        if lat and lon:
            row_filters.update(lat=float(lat), lon=float(lon))
        results = search(q, autocomplete=False, limit=1, **row_filters)
        if results:
            result = results[0]
            row.update(
                {
                    "result_candidat_label": str(result),
                    "result_candidat_score": round(result.score, 2),
                    "result_candidat_type": result.type,
                    "result_candidat_latitude": result.lat,
                    "result_candidat_longitude": result.lon,
                }
            )


# Remplace la route enregistrée par addok-csv
application.add_route("/search/csv", CSVSearchAvecCandidat())
