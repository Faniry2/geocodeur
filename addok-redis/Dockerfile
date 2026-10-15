ARG REDIS_VERSION=8.10

FROM redis:${REDIS_VERSION}-trixie

COPY redis.conf /usr/local/etc/redis/redis.conf

# Sans root, l'entrypoint officiel ne tente pas de changer le propriétaire des fichiers de /data
# (qui sont des fichiers de l'hôte montés en lecture seule)
USER redis

HEALTHCHECK --interval=10s --timeout=5s --start-period=5m --retries=3 \
    CMD redis-cli ping | grep -q PONG

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
