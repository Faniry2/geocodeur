ARG NGINX_VERSION=1.30

# Variante de l'image officielle qui tourne sans root (utilisateur nginx, uid 101)
FROM nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine

COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 7878

HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
    CMD wget -qO /dev/null http://127.0.0.1:7878/proxy-health || exit 1
