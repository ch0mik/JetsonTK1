FROM nginx:1.28.3-alpine

COPY nginx.conf /etc/nginx/nginx.conf

RUN rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /srv/files /tmp/nginx \
    && chown -R nginx:nginx /srv/files /tmp/nginx

USER nginx

VOLUME ["/srv/files"]

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=3s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
