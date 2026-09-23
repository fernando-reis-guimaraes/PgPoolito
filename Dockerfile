FROM edoburu/pgbouncer:v1.25.2-p0

EXPOSE 6432

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=10s \
  CMD pg_isready -h 127.0.0.1 -p 6432
