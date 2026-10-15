# Image tout-en-un : addok + Redis dans un seul conteneur, données BAN téléchargées au démarrage.
# Construire d'abord les images addok et addok-redis (docker compose build).
ARG ADDOK_IMAGE=geocodeur-infostat/addok:1.3.2
ARG REDIS_IMAGE=geocodeur-infostat/addok-redis:8.10

FROM ${REDIS_IMAGE} AS redis

FROM ${ADDOK_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends supervisor curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=redis /usr/local/bin/redis-server /usr/local/bin/redis-cli /usr/local/bin/
COPY --from=redis /usr/local/etc/redis/redis.conf /usr/local/etc/redis/redis.conf
COPY supervisord.conf /etc/supervisor/addok-standalone.conf
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/standalone-entrypoint.sh

ENV REDIS_HOST=localhost \
    ADDOK_CONFIG_MODULE=/data/addok.conf

USER addok
VOLUME ["/data", "/logs"]

HEALTHCHECK --interval=15s --timeout=5s --start-period=15m --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:7878/health', timeout=4)"

ENTRYPOINT ["standalone-entrypoint.sh"]
