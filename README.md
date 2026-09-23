# PgPooler-Uma

Maintained fork of [`edoburu/docker-pgbouncer`](https://github.com/edoburu/docker-pgbouncer).

This repository tracks upstream `master` through real Git merges (both
histories preserved) and builds PgBouncer from source via the upstream
multi-stage Alpine `Dockerfile`, plus PgPooler-Uma-specific behavior:

* image built locally by this repository (`cr.umapps.net/umapps/pgpooler`)
* multi-architecture build (`linux/amd64`, `linux/arm64` via `compose.yaml`)
* `.envrc` derives `IMAGE_TAG` from the Git commit
* dynamic `LISTEN_PORT` healthcheck (`pg_isready` against
  `${LISTEN_PORT:-5432}`, compatible with `LISTEN_PORT=6432` deployments)
* optional independent PgBouncer frontend credentials (see below)

## PgPooler-Uma extension: independent frontend credentials

Upstream uses `DB_USER` / `DB_PASSWORD` both to populate `userlist.txt`
and to connect to PostgreSQL.

This fork adds an OPTIONAL second credential pair:

* `PGBOUNCER_USER`
* `PGBOUNCER_PASSWORD`

These authenticate applications connecting TO PgBouncer, while
`DB_USER` / `DB_PASSWORD` remain the credentials PgBouncer uses
FROM PgBouncer TO PostgreSQL:

```text
Application -- PGBOUNCER_USER / PGBOUNCER_PASSWORD --> PgBouncer
PgBouncer   -- DB_USER / DB_PASSWORD ----------------> PostgreSQL
```

### Traditional / upstream-compatible configuration

```sh
docker run --rm \
  -e DB_USER=user \
  -e DB_PASSWORD=pass \
  -e DB_HOST=postgres-host \
  -e DB_NAME=database \
  -p 5432:5432 \
  cr.umapps.net/umapps/pgpooler:beta
```

Without `PGBOUNCER_*`, behavior is exactly upstream.

### Split credentials

```sh
docker run --rm \
  -e DB_USER=neondb_owner \
  -e DB_PASSWORD='<database password>' \
  -e DB_HOST=postgres-host \
  -e DB_NAME=database \
  -e PGBOUNCER_USER=app_pooler \
  -e PGBOUNCER_PASSWORD='<proxy password>' \
  -e LISTEN_PORT=6432 \
  -p 6432:6432 \
  cr.umapps.net/umapps/pgpooler:beta
```

* application connects to PgBouncer as `app_pooler`
* PgBouncer connects to PostgreSQL as `neondb_owner`

```sh
PGPASSWORD='<proxy password>' psql -h 127.0.0.1 -p 6432 -U app_pooler -d database -c "SELECT current_user;"
# current_user
# --------------
#  neondb_owner
```

The pair is optional and backward-compatible. Implementation uses
PgBouncer's database-level forced-user feature (`user=<DB_USER>` in the
generated `[databases]` entry). It does NOT misuse `auth_user`
(`auth_user` is for `auth_query` lookup, not for forcing backend
connections). `DB_PASSWORD` is kept in `auth_file`, never written into
`pgbouncer.ini`, and never printed to logs. Existing `AUTH_FILE` and
`AUTH_TYPE` (`md5` / `plain` / `scram-sha-256`) behavior is preserved.

Validation (fail fast, no silent fallback):

* exactly one of `PGBOUNCER_USER` / `PGBOUNCER_PASSWORD` set → startup fails
* `PGBOUNCER_USER == DB_USER` but passwords differ → startup fails
  (one `auth_file` username cannot represent two passwords)
* identical username + password is treated as effectively legacy credentials

### DATABASE_URL / DATABASE_URLS

Upstream `DATABASE_URL`, `DATABASE_URLS`, and separate `DB_*` support is
preserved. Split frontend credentials are global PgBouncer client
credentials; each backend entry parsed from a URL keeps its own
backend username/password and gets its own forced `user=` when split
mode is active.

Limitation: when `DATABASE_URLS` is combined with split credentials,
use distinct database names per URL. Overlapping or wildcard (`*`)
entries sharing one dbname with different backend users are inherently
ambiguous in `pgbouncer.ini` and unsupported; the last matching entry
may win.

### Deployment notes

* `LISTEN_PORT` defaults to `5432` (upstream default). Set
  `LISTEN_PORT=6432` for current PgPooler-Uma deployments; the
  healthcheck follows `LISTEN_PORT` dynamically.
* Build locally: `docker build -t cr.umapps.net/umapps/pgpooler:beta .`
* Multi-arch config lives in `compose.yaml`
  (`linux/amd64`, `linux/arm64`).
* Tests: `./tests/test_pgpooler.sh` (builds image, runs config checks
  plus live PostgreSQL integration, cleans up containers/networks).

## Tracking upstream

Canonical upstream remote:

```sh
git remote add upstream https://github.com/edoburu/docker-pgbouncer.git
git fetch upstream --tags
```

Normal update workflow:

```sh
git fetch upstream
git merge --no-ff upstream/master
```

Do not rebase, squash, or rewrite either history. Preserve both
lineages through merge commits.

---

## Upstream documentation (preserved)

PgBouncer Docker image
======================

This is a minimal PgBouncer image, based on Alpine Linux.

Features:

* Very small, quick to pull (just 15MB)
* Configurable using environment variables
* Uses standard Postgres port 5432, to work transparently for applications.
* Includes PostgreSQL client tools such as ``psql``, ``pg_isready``
* MD5 authentication by default.
* `/etc/pgbouncer/pgbouncer.ini` and `/etc/pgbouncer/userlist.txt` are auto-created if they don't exist.

Why use PgBouncer
-----------------

PostgreSQL connections take up a lot of memory ([about 10MB per connection](http://hans.io/blog/2014/02/19/postgresql_connection)). There is also a significant startup cost to establish a connection with TLS, hence web applications gain performance by using persistent connections.

By placing PgBouncer in between the web application and the actual PostgreSQL database, the memory and start-up costs are reduced. The web application can keep persistent connections to PgBouncer, while PgBouncer only keeps a few connections to the actual PostgreSQL server. It can reuse the same connection for multiple clients.

Usage
-----

```sh
docker run --rm \
    -e DATABASE_URL="postgres://user:pass@postgres-host/database" \
    -p 5432:5432 \
    edoburu/pgbouncer
```

Or using separate variables:

```sh
docker run --rm \
    -e DB_USER=user \
    -e DB_PASSWORD=pass \
    -e DB_HOST=postgres-host \
    -e DB_NAME=database \
    -p 5432:5432 \
    edoburu/pgbouncer
```

During startup we'll generate the necessary `userlist.txt` & `pgbouncer.ini` entries to match this information. Connecting should work as expected:

```sh
psql 'postgresql://user:pass@localhost/dbname'
```

> [!NOTE]
> If you need quick multi-user setup you can use `DATABASE_URLS` (instead of `DATABASE_URL`) with a comma (`,`) separated list of URLs.
>
> ```sh
> docker run --rm \
>     -e DATABASE_URLS="postgres://foo:123@postgres-host/foo,postgres://bar:456@postgres-host/bar" \
>     -p 5432:5432 \
>     edoburu/pgbouncer
> ```

Configuration
-------------

Almost all settings found in the [pgbouncer.ini](https://pgbouncer.github.io/config.html) can be defined as environment variables, except a few that make little sense in a Docker environment (like port numbers, syslog and pid settings). See the [entrypoint script](https://github.com/edoburu/docker-pgbouncer/blob/master/entrypoint.sh) for details. For example:

```sh
docker run --rm \
    -e DATABASE_URL="postgres://user:pass@postgres-host/database" \
    -e POOL_MODE=session \
    -e SERVER_RESET_QUERY="DISCARD ALL" \
    -e MAX_CLIENT_CONN=100 \
    -p 5432:5432
    edoburu/pgbouncer
```

Kubernetes integration
----------------------

For example in Kubernetes, see the [examples/kubernetes folder](https://github.com/edoburu/docker-pgbouncer/tree/master/examples/kubernetes).

Docker Compose
--------------

For example in Docker Compose, see the [examples/docker-compose folder](https://github.com/edoburu/docker-pgbouncer/tree/master/examples/docker-compose).

PostgreSQL configuration
------------------------

Make sure PostgreSQL at least accepts connections from the machine where PgBouncer runs! Update `listen_addresses` in `postgresql.conf` and accept incoming connections from your IP range (e.g. `10.0.0.0/8`) in `pg_hba.conf`:

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             10.0.0.0/8              md5
```

Using a custom configuration
----------------------------

When the default `pgbouncer.ini` is not sufficient, or you'd like to let multiple users connect through a single PgBouncer instance, mount an updated configuration:

```sh
docker run --rm \
    -e DB_USER=user \
    -e DB_PASSWORD=pass \
    -e DB_HOST=postgres-host \
    -e DB_NAME=database \
    -v pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
    -p 5432:5432
    edoburu/pgbouncer
```

Or extend the `Dockerfile`:

```Dockerfile
FROM edoburu/pgbouncer:1.11.0
COPY pgbouncer.ini userlist.txt /etc/pgbouncer/
```

When the `pgbouncer.ini` file exists, the startup script will not override it. An extra entry will be written to `userlist.txt` when `DATABASE_URL` contains credentials, or `DB_USER` and `DB_PASSWORD` are defined.

The `userlist.txt` file uses the following format:

```txt
"username" "plaintext-password"
```

or:

```txt
"username" "md5<md5 of password + username>"
```

Use [examples/generate-userlist](https://github.com/edoburu/docker-pgbouncer/blob/master/examples/generate-userlist) to generate this file:

```sh
examples/generate-userlist >> userlist.txt
```

You can also connect with a single user to PgBouncer, and from there retrieve the actual database password
by setting ``AUTH_USER``. See the example from: <https://www.cybertec-postgresql.com/en/pgbouncer-authentication-made-easy/>

Connecting to the admin console
-------------------------------

When an *admin user* is defined, and it has a password in the `userlist.txt`, it can connect to the special `pgbouncer` database:

```sh
psql postgres://postgres@hostname-of-container/pgbouncer  # outside container
psql postgres://127.0.0.1/pgbouncer                       # inside container
```

Hence this requires a custom configuration, or a mount of a custom ``userlist.txt`` in the docker file.
Various [admin console commands](https://pgbouncer.github.io/usage.html#admin-console) can be executed, for example:

```sql
SHOW STATS;
SHOW SERVERS;
SHOW CLIENTS;
SHOW POOLS;
```

And it allows temporary disconnecting the backend database (e.g. for restarts) while the web applications keep a connection to PgBouncer:

```sql
PAUSE;
RESUME;
```
