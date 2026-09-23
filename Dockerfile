FROM alpine:3.22 AS build
ARG VERSION=1.25.2

# Inspiration from https://github.com/gmr/alpine-pgbouncer/blob/master/Dockerfile
# hadolint ignore=DL3003,DL3018
RUN apk add --no-cache autoconf automake curl gcc libc-dev libevent-dev libtool make openssl-dev pkgconfig

# build version for release
RUN curl -sS -o /pgbouncer.tar.gz -L https://pgbouncer.github.io/downloads/files/$VERSION/pgbouncer-$VERSION.tar.gz && \
  tar -xzf /pgbouncer.tar.gz && mv /pgbouncer-$VERSION /pgbouncer

RUN cd /pgbouncer && ./configure --prefix=/usr && make -j$(nproc) pgbouncer && strip pgbouncer

FROM alpine:3.23

# Minimal runtime: libevent + client tools (preserved), plus openssl CLI
# for certificate validation, su-exec for privilege drop (PgBouncer never
# runs as root), and busybox-extras for the tiny documentation HTTP server.
RUN apk add --no-cache libevent postgresql-client openssl su-exec busybox-extras && \
  mkdir -p /etc/pgbouncer /var/log/pgbouncer /var/run/pgbouncer /run/pgbouncer/tls /var/www /usr/local/lib/pgpooler && \
  touch /etc/pgbouncer/userlist.txt && \
  chown -R postgres /var/log/pgbouncer /var/run/pgbouncer /run/pgbouncer /var/www /etc/pgbouncer && \
  chmod 0700 /run/pgbouncer/tls

COPY entrypoint.sh /entrypoint.sh
COPY lib/tls.sh /usr/local/lib/pgpooler/tls.sh
COPY lib/ui.sh /usr/local/lib/pgpooler/ui.sh
COPY healthcheck.sh /usr/local/bin/pgpooler-healthcheck.sh
COPY --from=build /pgbouncer/pgbouncer /usr/bin
COPY --from=build /pgbouncer/etc/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini.example
COPY --from=build /pgbouncer/etc/userlist.txt /etc/pgbouncer/userlist.txt.example
RUN chmod +x /entrypoint.sh /usr/local/bin/pgpooler-healthcheck.sh
# PgBouncer PostgreSQL ports plus the HTTP documentation UI.
EXPOSE 5432 6432 8080
# Run as root for privileged bootstrap (cert install, runtime perms);
# entrypoint drops to postgres via su-exec before running PgBouncer.
# Honor runtime LISTEN_PORT without PostgreSQL authentication (no pg_isready
# login, no auth noise). The check verifies the HTTP UI and, when PgBouncer
# is expected to run, its TCP liveness. Required+waiting (certificate
# pending) is healthy when the UI is reachable.
HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=10s \
  CMD /usr/local/bin/pgpooler-healthcheck.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
