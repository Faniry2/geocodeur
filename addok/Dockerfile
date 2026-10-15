ARG PYTHON_VERSION=3.14

# Compilation des dépendances qui n'ont pas de paquet binaire (python-geohash...)
FROM python:${PYTHON_VERSION}-slim-trixie AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r /tmp/requirements.txt

FROM python:${PYTHON_VERSION}-slim-trixie

RUN --mount=type=bind,from=build,source=/wheels,target=/wheels \
    pip install --no-cache-dir --no-index /wheels/*.whl

# addok-csv n'est plus maintenu : depuis addok 1.3, chaque filtre est une liste de colonnes
RUN f="$(python -c 'import addok_csv; print(addok_csv.__file__)')" \
    && old='return {k: row.get(v, "") for k, v in filters.items()}' \
    && new='return {k: row.get(v[0] if isinstance(v, list) else v, "") for k, v in filters.items()}' \
    && grep -qF "$old" "$f" \
    && sed -i "s/$old/$new/" "$f" \
    && grep -qF "$new" "$f"

RUN useradd --system --uid 1000 --user-group --no-create-home addok \
    && mkdir -p /etc/addok /data /logs \
    && chown addok:addok /data /logs

ENV ADDOK_CONFIG_MODULE=/etc/addok/addok.conf \
    REDIS_HOST=redis \
    REDIS_PORT=6379 \
    REDIS_DB_INDEXES=0 \
    ADDOK_DOCUMENT_STORE_PYPATH=addok_sqlite_store.SQLiteStore \
    ADDOK_SQLITE_DB_PATH=/data/addok.db \
    PYTHONUNBUFFERED=1

COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

USER addok
WORKDIR /data
EXPOSE 7878

HEALTHCHECK --interval=15s --timeout=5s --start-period=5m --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:7878/health', timeout=4)"

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["serve"]
