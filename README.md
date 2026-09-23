# PgPooler-Uma

Maintained fork of [`edoburu/docker-pgbouncer`](https://github.com/edoburu/docker-pgbouncer).

This repository tracks upstream `master` through real Git merges (both
histories preserved) and builds PgBouncer from source via the upstream
multi-stage Alpine `Dockerfile`, plus PgPooler-Uma-specific behavior:

* image built locally by this repository (`cr.umapps.net/umapps/pgpooler`)
* multi-architecture build (`linux/amd64`, `linux/arm64` via `compose.yaml`)
* `.envrc` derives `IMAGE_TAG` from the Git commit
* credential-free healthcheck (HTTP UI on `8080` plus TCP liveness on
  `${LISTEN_PORT:-5432}`, no `pg_isready` login, no auth noise)
* optional independent PgBouncer frontend credentials (see below)
* CapRover-friendly automatic frontend TLS + documentation UI (see below)

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
PgBouncer's native database parameters (`user=<DB_USER>` and
`password=<DB_PASSWORD>` in the generated `[databases]` entry), for
example:

```ini
[databases]
mydb = host=postgres.example port=5432 dbname=mydb user=neondb_owner password=database-secret
```

It does NOT misuse `auth_user` (`auth_user` is for `auth_query` lookup,
not for forcing backend connections). In split mode the frontend
`auth_file` holds ONLY `PGBOUNCER_USER`; `DB_USER` is never inserted
there, and the generated per-database entry omits `auth_user`
(otherwise PgBouncer would still accept the backend user as a frontend
login), so backend credentials cannot authenticate TO PgBouncer.
Generated `pgbouncer.ini`/`userlist.txt` are mode `0600`, startup
diagnostics print only a password-redacted config, and passwords are
never logged. Existing `AUTH_FILE` behavior is preserved; frontend
`PGBOUNCER_USER` encoding follows existing `AUTH_TYPE`
(`md5` / `plain` / `scram-sha-256`), while backend `DB_PASSWORD` is
independent of `AUTH_TYPE`.

Validation (fail fast, no silent fallback):

* exactly one of `PGBOUNCER_USER` / `PGBOUNCER_PASSWORD` set → startup fails
* `PGBOUNCER_USER` / `PGBOUNCER_PASSWORD` containing CR/LF → startup fails
  (auth-file is line-oriented; values are never truncated or normalized)

### Connection-string quoting

In split mode string-valued `[databases]` parameters (`host`, `user`,
`password`; `port` stays numeric) are serialized with PgBouncer/libpq
single-quote quoting: wrapped in `'...'`, each literal `'` doubled.
For example `abc def'ghi` becomes `'abc def''ghi'`.

### Auth-file quoting

Frontend `auth_file` fields use PgBouncer's double-quote serialization:
surrounded by `"..."`, each literal `"` doubled (`abc"def` →
`"abc""def"`). Usernames/passwords with `"` round-trip exactly under
`plain` / `scram-sha-256` (md5 hashes are hex and unaffected but routed
through the same serializer).

### DATABASE_URL / DATABASE_URLS

Upstream `DATABASE_URL`, `DATABASE_URLS`, and separate `DB_*` support is
preserved. Split frontend credentials are global PgBouncer client
credentials; each backend entry parsed from a URL keeps its own
backend username/password and generates its own `user=` + `password=`
(safely quoted on output).
Backend users are never added to the frontend `auth_file`. Take care
not to log URLs containing passwords.

URL parser limitation (upstream behavior, preserved): credentials are
split naively on `:`, `@`, `/`, `,`. Passwords containing those
characters, or requiring percent-encoding, may misparse from
`DATABASE_URL`/`DATABASE_URLS`; prefer separate `DB_*` variables for
such credentials. `DB_*` values with spaces, `'`, `#`, `;`, `=`, `\`
are supported via quoting.

Limitation: when `DATABASE_URLS` is combined with split credentials,
use distinct database names per URL. Overlapping or wildcard (`*`)
entries sharing one dbname with different backend users are inherently
ambiguous in `pgbouncer.ini` and unsupported; the last matching entry
may win.

### Deployment notes

* `LISTEN_PORT` defaults to `5432` (upstream default). Set
  `LISTEN_PORT=6432` for current PgPooler-Uma deployments; the
  healthcheck follows `LISTEN_PORT` dynamically without logging in.
* Build locally: `docker build -t cr.umapps.net/umapps/pgpooler:beta .`
* Multi-arch config lives in `compose.yaml`
  (`linux/amd64`, `linux/arm64`).
* Tests: `./tests/test_pgpooler.sh` (builds image, runs config checks
  plus live PostgreSQL integration, cleans up containers/networks).

## CapRover-friendly TLS + documentation UI

PgPooler-Uma exposes two interfaces on the same hostname:

```text
https://pgpooler.example.com
        |
        | HTTPS :443 handled by CapRover nginx
        v
PgPooler-Uma HTTP documentation UI :8080


postgresql://pgpooler.example.com:6432
        |
        | PostgreSQL protocol, optionally/mandatorily TLS
        v
PgBouncer :6432
        |
        | existing backend TLS configuration
        v
PostgreSQL
```

The plain HTTP UI exists so the CapRover application can be deployed as
a normal web application, CapRover can obtain and manage a Let's Encrypt
certificate for the hostname, and PgBouncer can reuse that same
certificate on its PostgreSQL TCP port. Certificate validity is by
hostname, not by port. No ACME client or Certbot is bundled; CapRover
remains the certificate orchestrator.

### Web UI on port 8080

A minimal static page (served by `busybox-extras httpd`, no framework,
no login, no database API) is available on port `8080`. It shows:

```text
PgPooler-Uma

PostgreSQL Connection Pooler

Host
<public hostname>

Port
<LISTEN_PORT>

Database
<DB_NAME>

TLS
<current frontend TLS state>

Connection string
postgresql://<USERNAME>:<PASSWORD>@<HOST>:<PORT>/<DATABASE>?sslmode=<appropriate mode>
```

`<USERNAME>` and `<PASSWORD>` are always literal placeholders. Real
`PGBOUNCER_USER`, `PGBOUNCER_PASSWORD`, `DB_USER`, or `DB_PASSWORD`
values never appear in visible text, HTML source, comments, attributes,
or generated files. Backend host credentials are never displayed. The
database name is shown because it is not a secret. All displayed values
are HTML-escaped.

TLS status strings include:

```text
Disabled
Not available - plaintext currently enabled
Available and required
Required - waiting for certificate
```

When TLS is active the page recommends `sslmode=verify-full`. When no
certificate is active it shows `sslmode=disable` and never misleads with
`verify-full`. When `PUBLIC_HOST` is absent the page derives the display
host from the browser request hostname (`window.location.hostname`);
automatic certificate selection never guesses in that case.

### CapRover deployment model

Recommended CapRover settings:

* Container HTTP Port: `8080`
* Enable HTTPS for the application hostname when a public domain is used.
* Force HTTPS for the Web UI is recommended.
* Separate public port mapping for PostgreSQL, for example `6432 -> 6432`
  (CapRover port mapping / Docker publish to PgBouncer `LISTEN_PORT`).

Read-only bind mount for the host Let's Encrypt tree:

```text
/captain/data/letencrypt/etc:/caprover-letsencrypt:ro
```

The container never mutates, chmods, or chowns anything under
`/caprover-letsencrypt`. No Docker socket, no CapRover API, and no
config parsing are required.

### PUBLIC_HOST

```text
PUBLIC_HOST=pgpooler.example.com
```

Single canonical explicit hostname. Used for Web UI examples, locating
the matching certificate at
`/caprover-letsencrypt/live/${PUBLIC_HOST}/fullchain.pem` and
`privkey.pem`, and validating hostname ownership. No separate TLS domain
variable exists. When absent (for example local deployments without a
domain) automatic certificate discovery is inactive and the UI derives
the display host from the request. The value is treated as untrusted
input and strictly validated as a single DNS hostname.

### PGPOOLER_SSL_MODE

```text
PGPOOLER_SSL_MODE=disabled|prefer|required
```

Default: `prefer`. This is a PgPooler-Uma policy setting and is NOT
equivalent to PgBouncer native `client_tls_sslmode=prefer`.

* `disabled`: never automatically enable frontend TLS. Certificate
  presence is ignored for automatic purposes. Effective frontend
  behavior is `client_tls_sslmode = disable`. No watcher is required.

* `prefer`: operate without TLS only while TLS is unavailable; once a
  valid certificate is available, require TLS. Without a certificate
  PgBouncer starts plaintext. With a valid certificate PgBouncer uses
  `client_tls_sslmode = require` and plaintext is rejected. If a
  certificate appears later (for example after enabling HTTPS in
  CapRover) it is detected automatically, installed, and PgBouncer is
  switched to `require` without restarting the container. This does NOT
  mean native `prefer` (which would keep accepting plaintext).

* `required`: frontend TLS is mandatory. Without a valid certificate the
  HTTP UI still runs but PgBouncer does not expose a PostgreSQL
  listener; plaintext is never temporarily exposed. The container stays
  stable (not crash-looping) and logs that it is waiting. When a valid
  certificate appears it is prepared automatically, PgBouncer starts
  with `client_tls_sslmode = require`, and the first PostgreSQL
  connection already requires TLS. There is no plaintext window.

Once automatic TLS is active, both `prefer` and `required` result in
native `client_tls_sslmode = require`.

### Frontend vs backend TLS

Frontend (client to PgBouncer) and backend (PgBouncer to PostgreSQL) are
independent hops:

```text
application -- frontend TLS (CLIENT_TLS_*/automatic) --> PgBouncer
PgBouncer   -- SERVER_TLS_SSLMODE=verify-full ----------> PostgreSQL
```

Existing `SERVER_TLS_*` semantics are unchanged. Existing manual
`CLIENT_TLS_*` support remains for advanced and non-CapRover users.

Precedence: `PGPOOLER_SSL_MODE` controls automatic CapRover behavior.
Manually specifying `CLIENT_TLS_CERT_FILE`, `CLIENT_TLS_KEY_FILE`, or
`CLIENT_TLS_SSLMODE` together with `PUBLIC_HOST` automatic discovery
fails fast with a clear error instead of silently mixing sources.
`CLIENT_TLS_CA_FILE`, `CLIENT_TLS_PROTOCOLS`, `CLIENT_TLS_CIPHERS`,
`CLIENT_TLS_ECDHCURVE`, and `CLIENT_TLS_DHEPARAMS` may accompany
automatic TLS as hardening extras. Without `PUBLIC_HOST`, default
`prefer` stays plaintext unless manual `CLIENT_TLS_*` is provided, so
upgrading the image does not break existing manual deployments. In
`disabled` mode automatic discovery is off and manual settings pass
through. In `required` mode without `PUBLIC_HOST`, manual TLS must
already enforce `require` or stricter.

### Certificate validation

Filenames alone are never sufficient. Before activation the privileged
bootstrap and watcher validate with OpenSSL (no fragile parsing, no
secret output):

* both files exist and are readable,
* certificate is parseable (`openssl x509 -noout`),
* currently valid (`-checkend 0` plus `notBefore` comparison without GNU
  date dependency),
* hostname matches `PUBLIC_HOST` (`openssl x509 -checkhost`, SAN and
  wildcard aware),
* private key corresponds to the certificate (public-part comparison,
  never printed).

Invalid certificates: in `prefer` mode plaintext continues with a clear
log reason; in `required` mode PostgreSQL stays unavailable while
waiting. An active TLS state is never automatically downgraded to
plaintext.

### Runtime copies and renewal

Source files stay untouched. Validated certificates are copied to a
private runtime directory:

```text
/run/pgbouncer/tls/fullchain.pem
/run/pgbouncer/tls/privkey.pem
```

Files are `0600` owned by `postgres`, the directory is `0700`, replacement
is atomic (`tmp` plus `mv`), and PgBouncer never runs as root (dropped
via `su-exec`). A polling watcher (default 300 seconds,
`PGPOOLER_TLS_POLL_INTERVAL` override for tests and tuning) uses
content fingerprints (`sha256sum`, following `live/* -> archive/*`
symlinks) to detect initial appearance and renewal without container
restarts, Certbot hooks, or inotify. On renewal the new pair is
validated first, atomically installed, and PgBouncer is reloaded with
`SIGHUP` (`RELOAD`); existing client connections stay alive per PgBouncer
semantics and new TLS handshakes receive the renewed certificate.
Changing TLS settings triggers an automatic server-side `RECONNECT`;
verified live against PgBouncer 1.25.2 that `disable -> require` applies
via `SIGHUP` with new plaintext rejected and no container restart.

### Production example

```env
PUBLIC_HOST=pgpooler.example.com
PGPOOLER_SSL_MODE=required

LISTEN_PORT=6432

PGBOUNCER_USER=...
PGBOUNCER_PASSWORD=...

DB_HOST=...
DB_PORT=5432
DB_NAME=crud
DB_USER=...
DB_PASSWORD=...

AUTH_TYPE=scram-sha-256

SERVER_TLS_SSLMODE=verify-full
```

CapRover volume plus ports:

```text
/captain/data/letencrypt/etc:/caprover-letsencrypt:ro
Container HTTP Port: 8080 (HTTPS via CapRover nginx)
Public port mapping: 6432 -> 6432 (PostgreSQL/TLS direct to PgBouncer)
```

Connection documentation (placeholders only):

```text
postgresql://<USERNAME>:<PASSWORD>@pgpooler.example.com:6432/crud?sslmode=verify-full
```

### Local example (no domain)

```env
PGPOOLER_SSL_MODE=prefer
LISTEN_PORT=6432
PGBOUNCER_USER=...
PGBOUNCER_PASSWORD=...
DB_HOST=...
DB_NAME=crud
DB_USER=...
DB_PASSWORD=...
```

No `PUBLIC_HOST`, no certificate mount. UI on `http://localhost:8080`,
plaintext PostgreSQL with `sslmode=disable` in examples.

### Manual TLS example (non-CapRover)

```env
PGPOOLER_SSL_MODE=disabled
LISTEN_PORT=6432
CLIENT_TLS_SSLMODE=require
CLIENT_TLS_CERT_FILE=/certs/fullchain.pem
CLIENT_TLS_KEY_FILE=/certs/privkey.pem
```

Mount custom certificates read-only and manage renewal externally with a
container restart or `SIGHUP`. Do not combine manual identity settings
with `PUBLIC_HOST` automatic discovery.

### Healthcheck

No `pg_isready` login and no credential noise. The check verifies the
HTTP UI on `8080` and, when PgBouncer is expected to run, TCP liveness
on `LISTEN_PORT` via `nc -z` (no PostgreSQL handshake). In
`required` waiting state UI availability alone is healthy; the container
is not marked broken while CapRover has not issued the first
certificate.

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
