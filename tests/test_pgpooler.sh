#!/bin/sh
# PgPooler-Uma integration + config tests.
# Split mode isolates frontend auth (auth_file holds ONLY PGBOUNCER_USER)
# from backend auth (native user=/password= in [databases]).
# Legacy mode (no PGBOUNCER_*) remains upstream-compatible.
#
# Security: passwords are generated per-run (never committed) and never
# printed. Test output only shows usernames, ports, and pass/fail markers.
# Do not run with `set -x` / `sh -x`.
#
# Usage: ./tests/test_pgpooler.sh [--image <name>] [--keep]
# Requires: docker, psql (postgresql-client)

set -eu

# Single POSIX arg parse (supports --image NAME, --image=NAME, --keep).
IMAGE="pgpooler-test:local"
KEEP=0
_prev=""
for _a in "$@"; do
  if [ "${_prev}" = "--image" ]; then
    IMAGE="${_a}"
    _prev=""
    continue
  fi
  case "${_a}" in
    --image) _prev="--image" ;;
    --image=*) IMAGE="${_a#--image=}" ;;
    --keep) KEEP=1 ;;
  esac
done

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${REPO_ROOT}"

BACKEND_USER="backend_user"
FRONTEND_USER="app_user"
TESTDB="testdb"

# Per-run random secrets (never committed, never printed).
if command -v openssl >/dev/null 2>&1; then
  BACKEND_PASSWORD="be-$(openssl rand -hex 10)"
  FRONTEND_PASSWORD="fe-$(openssl rand -hex 10)"
  WRONG_PASSWORD="wr-$(openssl rand -hex 10)"
  SPECIAL_BACKEND_PASSWORD="sp-$(openssl rand -hex 4) pa'ss#with;special=and\\slash"
  SPECIAL_FRONTEND_PASSWORD="fr-$(openssl rand -hex 4) pa\"ss'with#special;chars=and\\slash"
else
  BACKEND_PASSWORD="be-$$-$(date +%s)-test"
  FRONTEND_PASSWORD="fe-$$-$(date +%s)-test"
  WRONG_PASSWORD="wr-$$-$(date +%s)-test"
  SPECIAL_BACKEND_PASSWORD="sp-$$-$(date +%s) pa'ss#with;special=and\\slash"
  SPECIAL_FRONTEND_PASSWORD="fr-$$-$(date +%s) pa\"ss'with#special;chars=and\\slash"
fi

SUFFIX="$(date +%s)-$$"
NET="pgpooler-test-net-${SUFFIX}"
PG="pgpooler-test-pg-${SUFFIX}"
PASS_COUNT=0
FAIL_COUNT=0

log() { printf '%s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); log "PASS: $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); log "FAIL: $*"; }

cleanup() {
  if [ "${KEEP}" = "1" ]; then
    log "KEEP=1: leaving containers/network for inspection: ${PG} ${NET}"
    return 0
  fi
  for _c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "${SUFFIX}" || true); do
    docker rm -f "${_c}" >/dev/null 2>&1 || true
  done
  docker rm -f "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Wait for postgres to accept connections (inside its container).
wait_pg() {
  _tries=0
  while [ "${_tries}" -lt 30 ]; do
    if docker exec "${PG}" pg_isready -U "${BACKEND_USER}" >/dev/null 2>&1; then
      return 0
    fi
    _tries=$((_tries + 1))
    sleep 1
  done
  return 1
}

# Wait until host psql can connect through pgbouncer.
# Args: host_port user password
wait_pgbouncer() {
  _hp="$1"; _u="$2"; _p="$3"
  _tries=0
  while [ "${_tries}" -lt 30 ]; do
    if PGPASSWORD="${_p}" psql -X -q -h 127.0.0.1 -p "${_hp}" -U "${_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1; then
      return 0
    fi
    _tries=$((_tries + 1))
    sleep 1
  done
  return 1
}

# Query current_user via pgbouncer without printing secrets.
# Args: host_port user password
query_current_user() {
  _hp="$1"; _u="$2"; _p="$3"
  PGPASSWORD="${_p}" psql -X -q -h 127.0.0.1 -p "${_hp}" -U "${_u}" -d "${TESTDB}" -tA -c "SELECT current_user;" 2>/dev/null
}

# Attempt a connection; returns 0 on success, 1 on failure (no output).
# Args: host_port user password
try_connect() {
  _hp="$1"; _u="$2"; _p="$3"
  PGPASSWORD="${_p}" psql -X -q -h 127.0.0.1 -p "${_hp}" -U "${_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1
}

log "=== PgPooler-Uma tests (image: ${IMAGE}) ==="

# ---------------------------------------------------------------- build
log "--- Test 0: build image locally ---"
if docker build -t "${IMAGE}" . >/tmp/pgpooler-build-${SUFFIX}.log 2>&1; then
  pass "docker build ${IMAGE}"
else
  fail "docker build ${IMAGE} (see /tmp/pgpooler-build-${SUFFIX}.log)"
  exit 1
fi

log "--- Test 0b: Dockerfile builds PgBouncer (no FROM edoburu/pgbouncer) ---"
if grep -q "^FROM edoburu/pgbouncer" Dockerfile; then
  fail "Dockerfile still depends on FROM edoburu/pgbouncer"
else
  pass "Dockerfile does not depend on FROM edoburu/pgbouncer"
fi
if grep -q "LISTEN_PORT" Dockerfile && grep -q "HEALTHCHECK" Dockerfile; then
  pass "Dockerfile healthcheck honors LISTEN_PORT"
else
  fail "Dockerfile healthcheck missing LISTEN_PORT"
fi
if grep -q "linux/amd64" compose.yaml && grep -q "linux/arm64" compose.yaml; then
  pass "compose.yaml keeps linux/amd64 + linux/arm64 platforms"
else
  fail "compose.yaml missing multi-arch platforms"
fi

# ------------------------------------------------- config-only checks
log "--- Test A: frontend auth_file isolation (split mode) ---"
docker run --rm --name "pgpooler-isolation-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && ! grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && echo ISOLATION_OK' \
  >/tmp/pgpooler-isolation-${SUFFIX}.log 2>&1 || true
if grep -q "ISOLATION_OK" /tmp/pgpooler-isolation-${SUFFIX}.log 2>/dev/null; then
  pass "split auth_file holds frontend only (no backend_user)"
else
  fail "split auth_file isolation broken"
fi
# Startup logs must not contain either password.
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-isolation-${SUFFIX}.log 2>/dev/null; then
  fail "backend password leaked into startup logs"
else
  pass "no backend password in startup logs"
fi
if grep -F -q "${FRONTEND_PASSWORD}" /tmp/pgpooler-isolation-${SUFFIX}.log 2>/dev/null; then
  fail "frontend password leaked into startup logs"
else
  pass "no frontend password in startup logs"
fi
# Redacted config output must not contain raw password.
if grep -q "password=\*\*\*REDACTED\*\*\*" /tmp/pgpooler-isolation-${SUFFIX}.log 2>/dev/null; then
  pass "startup config output redacts password"
else
  fail "startup config output missing redaction marker"
fi
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-isolation-${SUFFIX}.log 2>/dev/null; then
  fail "raw backend password in startup output"
else
  pass "no raw backend password in startup output"
fi

log "--- Test A2: legacy auth_file holds backend (upstream-compatible) ---"
docker run --rm --name "pgpooler-legacy-auth-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && echo LEGACY_AUTH_OK' \
  >/tmp/pgpooler-legacyauth-${SUFFIX}.log 2>&1 || true
if grep -q "LEGACY_AUTH_OK" /tmp/pgpooler-legacyauth-${SUFFIX}.log 2>/dev/null; then
  pass "legacy auth_file holds backend_user"
else
  fail "legacy auth_file missing backend_user"
fi

log "--- Test 7: generated database config uses native user=/password= ---"
docker run --rm --name "pgpooler-dbconf-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q backend_user && grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q " password=" && ! grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q app_user && ! grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q auth_user && echo DBCONF_OK' \
  >/tmp/pgpooler-dbconf-${SUFFIX}.log 2>&1 || true
if grep -q "DBCONF_OK" /tmp/pgpooler-dbconf-${SUFFIX}.log 2>/dev/null; then
  pass "pgbouncer.ini forces backend user with password, omits auth_user"
else
  fail "pgbouncer.ini missing forced backend user/password or leaks auth_user"
fi

log "--- Test 7-legacy: legacy config has no forced user=/password= ---"
docker run --rm --name "pgpooler-dbconf-legacy-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c '! grep -q " user=backend_user" /etc/pgbouncer/pgbouncer.ini && ! grep -q " password=" /etc/pgbouncer/pgbouncer.ini && echo LEGACY_DBCONF_OK' \
  >/tmp/pgpooler-dbconf-legacy-${SUFFIX}.log 2>&1 || true
if grep -q "LEGACY_DBCONF_OK" /tmp/pgpooler-dbconf-legacy-${SUFFIX}.log 2>/dev/null; then
  pass "legacy pgbouncer.ini unchanged (no forced user/password)"
else
  fail "legacy pgbouncer.ini should not force user/password"
fi

log "--- Test G: generated file permissions are 0600 ---"
docker run --rm --name "pgpooler-perms-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'test "$(stat -c %a /etc/pgbouncer/pgbouncer.ini)" = "600" && test "$(stat -c %a /etc/pgbouncer/userlist.txt)" = "600" && echo PERMS_OK' \
  >/tmp/pgpooler-perms-${SUFFIX}.log 2>&1 || true
if grep -q "PERMS_OK" /tmp/pgpooler-perms-${SUFFIX}.log 2>/dev/null; then
  pass "pgbouncer.ini and userlist.txt are mode 0600"
else
  fail "generated files are not mode 0600"
fi

log "--- Test 4: partial credential pair must fail startup ---"
if docker run --rm --name "pgpooler-partial-1-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-partial1-${SUFFIX}.log 2>&1; then
  fail "startup with only PGBOUNCER_USER should fail"
else
  if grep -qi "must be set together" /tmp/pgpooler-partial1-${SUFFIX}.log 2>/dev/null; then
    pass "startup fails clearly with only PGBOUNCER_USER"
  else
    fail "startup failed but without clear error (only USER)"
  fi
fi
if docker run --rm --name "pgpooler-partial-2-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-partial2-${SUFFIX}.log 2>&1; then
  fail "startup with only PGBOUNCER_PASSWORD should fail"
else
  if grep -qi "must be set together" /tmp/pgpooler-partial2-${SUFFIX}.log 2>/dev/null; then
    pass "startup fails clearly with only PGBOUNCER_PASSWORD"
  else
    fail "startup failed but without clear error (only PASSWORD)"
  fi
fi

log "--- Test 5: same username is isolated (backend not in auth_file) ---"
docker run --rm --name "pgpooler-sameuser-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGBOUNCER_USER="${BACKEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'test "$(grep -c "\"backend_user\"" /etc/pgbouncer/userlist.txt)" = "1" && echo SAMEUSER_OK' \
  >/tmp/pgpooler-sameuser-${SUFFIX}.log 2>&1 || true
if grep -q "SAMEUSER_OK" /tmp/pgpooler-sameuser-${SUFFIX}.log 2>/dev/null; then
  pass "same frontend/backend username yields single isolated auth entry"
else
  fail "same-username isolation check failed"
fi

log "--- Test 7b: DATABASE_URL split isolates backend, forces user/password ---"
docker run --rm --name "pgpooler-url-${SUFFIX}" \
  -e "DATABASE_URL=postgres://${BACKEND_USER}:${BACKEND_PASSWORD}@fakehost:5432/${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c '! grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q " user=" && grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q backend_user && grep "^testdb" /etc/pgbouncer/pgbouncer.ini | grep -q " password=" && echo URL_OK' \
  >/tmp/pgpooler-url-${SUFFIX}.log 2>&1 || true
if grep -q "URL_OK" /tmp/pgpooler-url-${SUFFIX}.log 2>/dev/null; then
  pass "DATABASE_URL split entry isolates backend and forces user/password"
else
  fail "DATABASE_URL split entry broken"
fi
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-url-${SUFFIX}.log 2>/dev/null; then
  fail "backend password leaked via DATABASE_URL run"
else
  pass "no backend password in DATABASE_URL startup output"
fi

log "--- Test 7b2: DATABASE_URLS split isolates each backend ---"
docker run --rm --name "pgpooler-urls-${SUFFIX}" \
  -e "DATABASE_URLS=postgres://foo:foopass@fakehost/foo,postgres://bar:barpass@fakehost/bar" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c '! grep -q "\"foo\"" /etc/pgbouncer/userlist.txt && ! grep -q "\"bar\"" /etc/pgbouncer/userlist.txt && grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && grep "^foo" /etc/pgbouncer/pgbouncer.ini | grep -q " user=" && grep "^bar" /etc/pgbouncer/pgbouncer.ini | grep -q " user=" && echo URLS_OK' \
  >/tmp/pgpooler-urls-${SUFFIX}.log 2>&1 || true
if grep -q "URLS_OK" /tmp/pgpooler-urls-${SUFFIX}.log 2>/dev/null; then
  pass "DATABASE_URLS split isolates backends and forces each user"
else
  fail "DATABASE_URLS split handling broken"
fi

log "--- Test 7c: AUTH_TYPE variants preserve frontend auth, isolate backend ---"
for _at in md5 plain scram-sha-256; do
  if docker run --rm --name "pgpooler-authtype-${SUFFIX}" \
    -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
    -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
    -e AUTH_TYPE="${_at}" \
    --entrypoint /entrypoint.sh "${IMAGE}" \
    sh -c 'grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && ! grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && echo AUTHTYPE_OK' \
    >/tmp/pgpooler-authtype-${SUFFIX}-${_at}.log 2>&1; then
    if grep -q "AUTHTYPE_OK" /tmp/pgpooler-authtype-${SUFFIX}-${_at}.log 2>/dev/null; then
      pass "AUTH_TYPE=${_at} isolates frontend, encodes per AUTH_TYPE"
    else
      fail "AUTH_TYPE=${_at} isolation broken"
    fi
  else
    fail "AUTH_TYPE=${_at} container run failed"
  fi
done

log "--- Test Q: connstr quoting (space, quote, specials) ---"
# Q1: password with space + single quote must serialize as 'abc def''ghi'.
docker run --rm --name "pgpooler-quote1-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e "DB_PASSWORD=abc def'ghi" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c "grep -F \"password='abc def''ghi'\" /etc/pgbouncer/pgbouncer.ini && echo QUOTE1_OK" \
  >/tmp/pgpooler-quote1-${SUFFIX}.log 2>&1 || true
if grep -q "QUOTE1_OK" /tmp/pgpooler-quote1-${SUFFIX}.log 2>/dev/null; then
  pass "quoting serializes password with space+quote"
else
  fail "quoting failed for password with space+quote"
fi
# Q2/Q3: backend usernames requiring quoting (config-level).
docker run --rm --name "pgpooler-quote2-${SUFFIX}" \
  -e DB_HOST=fakehost -e "DB_USER=user name" -e DB_PASSWORD=x -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c "grep -F \"user='user name'\" /etc/pgbouncer/pgbouncer.ini && echo QUOTE2_OK" \
  >/tmp/pgpooler-quote2-${SUFFIX}.log 2>&1 || true
if grep -q "QUOTE2_OK" /tmp/pgpooler-quote2-${SUFFIX}.log 2>/dev/null; then
  pass "quoting serializes username with space"
else
  fail "quoting failed for username with space"
fi
docker run --rm --name "pgpooler-quote3-${SUFFIX}" \
  -e DB_HOST=fakehost -e "DB_USER=user'name" -e DB_PASSWORD=x -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c "grep -F \"user='user''name'\" /etc/pgbouncer/pgbouncer.ini && echo QUOTE3_OK" \
  >/tmp/pgpooler-quote3-${SUFFIX}.log 2>&1 || true
if grep -q "QUOTE3_OK" /tmp/pgpooler-quote3-${SUFFIX}.log 2>/dev/null; then
  pass "quoting serializes username with single quote"
else
  fail "quoting failed for username with single quote"
fi
# Q4: full specials vector a b'c#d;e=f\g.
docker run --rm --name "pgpooler-quote4-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e "DB_PASSWORD=a b'c#d;e=f\\g" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c "grep -F \"password='a b''c#d;e=f\\\\g'\" /etc/pgbouncer/pgbouncer.ini && echo QUOTE4_OK" \
  >/tmp/pgpooler-quote4-${SUFFIX}.log 2>&1 || true
if grep -q "QUOTE4_OK" /tmp/pgpooler-quote4-${SUFFIX}.log 2>/dev/null; then
  pass "quoting serializes full specials vector"
else
  fail "quoting failed for full specials vector"
fi

log "--- Test Q-auth: auth-file double-quote serialization ---"
# Uses fixed non-secret vectors (not credentials): abc"def must be stored
# as "app_user" "abc""def" under plaintext-style storage.
docker run --rm --name "pgpooler-quoteauth1-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e "PGBOUNCER_PASSWORD=abc\"def" -e AUTH_TYPE=plain \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -F "\"app_user\" \"abc\"\"def\"" /etc/pgbouncer/userlist.txt && echo QUOTEAUTH1_OK' \
  >/tmp/pgpooler-quoteauth1-${SUFFIX}.log 2>&1 || true
if grep -q "QUOTEAUTH1_OK" /tmp/pgpooler-quoteauth1-${SUFFIX}.log 2>/dev/null; then
  pass "auth-file doubles literal double quotes in password"
else
  fail "auth-file quoting failed for password with double quote"
fi
# Username vector user"name must be stored as "user""name".
# Live username test omitted: PostgreSQL roles with embedded double quotes
# require quoted identifiers at creation and psql -U handling adds
# ambiguity; serializer/config coverage plus PgBouncer's documented ""
# collapsing is sufficient for usernames.
docker run --rm --name "pgpooler-quoteauth2-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e "PGBOUNCER_USER=user\"name" -e PGBOUNCER_PASSWORD=y -e AUTH_TYPE=plain \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -F "\"user\"\"name\"" /etc/pgbouncer/userlist.txt && echo QUOTEAUTH2_OK' \
  >/tmp/pgpooler-quoteauth2-${SUFFIX}.log 2>&1 || true
if grep -q "QUOTEAUTH2_OK" /tmp/pgpooler-quoteauth2-${SUFFIX}.log 2>/dev/null; then
  pass "auth-file doubles literal double quotes in username"
else
  fail "auth-file quoting failed for username with double quote"
fi
log "--- Test Q-auth-CRLF: line breaks must fail fast ---"
if docker run --rm --name "pgpooler-crlf-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e "PGBOUNCER_PASSWORD=ab
cd" --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-crlf-${SUFFIX}.log 2>&1; then
  fail "startup with LF in frontend password should fail"
else
  if grep -qi "PGBOUNCER_PASSWORD.*newline or carriage return" /tmp/pgpooler-crlf-${SUFFIX}.log 2>/dev/null; then
    pass "LF in frontend password fails fast with named error"
  else
    fail "LF rejection failed without clear named error"
  fi
fi

log "--- Test LIT: literal auth-file username dedup (no regex) ---"
# Exercises the real write_user_entry() path: outer entrypoint is inert
# (no PGBOUNCER_*/DB creds that would pre-add users); the inner call
# prepopulates userlist.txt with safe dummy credentials, then invokes the
# real entrypoint once with the candidate frontend credential.
# Case 1: dot must not behave as regex wildcard.
docker run --rm --name "pgpooler-lit1-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'printf "\"appXuser\" \"dummy\"\n" > /etc/pgbouncer/userlist.txt; PGBOUNCER_USER="app.user" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; grep -F -q "\"appXuser\"" /etc/pgbouncer/userlist.txt && grep -F -q "\"app.user\"" /etc/pgbouncer/userlist.txt && echo LIT1_OK' \
  >/tmp/pgpooler-lit1-${SUFFIX}.log 2>&1 || true
if grep -q "LIT1_OK" /tmp/pgpooler-lit1-${SUFFIX}.log 2>/dev/null; then
  pass "dot: app.user added distinctly alongside appXuser"
else
  fail "dot deduplication broken (app.user vs appXuser)"
fi
# Case 2: star must be literal.
docker run --rm --name "pgpooler-lit2-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'printf "\"user123\" \"dummy\"\n" > /etc/pgbouncer/userlist.txt; PGBOUNCER_USER="user.*" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; grep -F -q "\"user123\"" /etc/pgbouncer/userlist.txt && grep -F -q "\"user.*\"" /etc/pgbouncer/userlist.txt && echo LIT2_OK' \
  >/tmp/pgpooler-lit2-${SUFFIX}.log 2>&1 || true
if grep -q "LIT2_OK" /tmp/pgpooler-lit2-${SUFFIX}.log 2>/dev/null; then
  pass "star: user.* added distinctly alongside user123"
else
  fail "star deduplication broken (user.* vs user123)"
fi
# Case 3: character class must be literal.
docker run --rm --name "pgpooler-lit3-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'printf "\"user1\" \"dummy\"\n" > /etc/pgbouncer/userlist.txt; PGBOUNCER_USER="user[123]" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; grep -F -q "\"user1\"" /etc/pgbouncer/userlist.txt && grep -F -q "\"user[123]\"" /etc/pgbouncer/userlist.txt && echo LIT3_OK' \
  >/tmp/pgpooler-lit3-${SUFFIX}.log 2>&1 || true
if grep -q "LIT3_OK" /tmp/pgpooler-lit3-${SUFFIX}.log 2>/dev/null; then
  pass "class: user[123] added distinctly alongside user1"
else
  fail "class deduplication broken (user[123] vs user1)"
fi
# Case 4: exact duplicate must not create a second entry.
docker run --rm --name "pgpooler-lit4-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'printf "\"app.user\" \"dummy\"\n" > /etc/pgbouncer/userlist.txt; PGBOUNCER_USER="app.user" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; test "$(grep -F -c "\"app.user\"" /etc/pgbouncer/userlist.txt)" = "1" && echo LIT4_OK' \
  >/tmp/pgpooler-lit4-${SUFFIX}.log 2>&1 || true
if grep -q "LIT4_OK" /tmp/pgpooler-lit4-${SUFFIX}.log 2>/dev/null; then
  pass "exact duplicate app.user detected (single entry)"
else
  fail "exact duplicate app.user not detected"
fi
# Case 5: embedded double quote (serialized "user""name") dedups exactly.
docker run --rm --name "pgpooler-lit5-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'printf "\"user\"\"name\" \"dummy\"\n" > /etc/pgbouncer/userlist.txt; PGBOUNCER_USER="user\"name" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; test "$(grep -F -c "\"user\"\"name\"" /etc/pgbouncer/userlist.txt)" = "1" && echo LIT5_OK' \
  >/tmp/pgpooler-lit5-${SUFFIX}.log 2>&1 || true
if grep -q "LIT5_OK" /tmp/pgpooler-lit5-${SUFFIX}.log 2>/dev/null; then
  pass "embedded quote: user\"name duplicate detected"
else
  fail "embedded quote deduplication broken"
fi
# Case 6: backslash is literal (distinct from similar names, dedups exactly).
docker run --rm --name "pgpooler-lit6-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_NAME="${TESTDB}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'printf "\"userXname\" \"dummy\"\n" > /etc/pgbouncer/userlist.txt; PGBOUNCER_USER="user\\name" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; grep -F -q "\"userXname\"" /etc/pgbouncer/userlist.txt && grep -F -q "\"user\\name\"" /etc/pgbouncer/userlist.txt && PGBOUNCER_USER="user\\name" PGBOUNCER_PASSWORD=y AUTH_TYPE=plain /entrypoint.sh true >/dev/null 2>&1; test "$(grep -F -c "\"user\\name\"" /etc/pgbouncer/userlist.txt)" = "1" && echo LIT6_OK' \
  >/tmp/pgpooler-lit6-${SUFFIX}.log 2>&1 || true
if grep -q "LIT6_OK" /tmp/pgpooler-lit6-${SUFFIX}.log 2>/dev/null; then
  pass "backslash: user\\name literal and deduplicated"
else
  fail "backslash deduplication broken"
fi

# ------------------------------------------------- live integration
log "--- Live integration: starting temporary PostgreSQL ---"
docker network create "${NET}" >/dev/null 2>&1 || true
docker run -d --name "${PG}" --network "${NET}" \
  -e "POSTGRES_USER=${BACKEND_USER}" -e "POSTGRES_PASSWORD=${BACKEND_PASSWORD}" -e "POSTGRES_DB=${TESTDB}" \
  postgres:17 >/dev/null
if wait_pg; then
  pass "temporary PostgreSQL is ready"
else
  fail "temporary PostgreSQL did not become ready"
  exit 1
fi

log "--- Test H: legacy behavior (DB_* only, upstream-compatible) ---"
LEGACY_PORT=16431
docker run -d --name "pgpooler-legacy-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${LEGACY_PORT}:5432" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e LISTEN_PORT=5432 -e AUTH_TYPE=scram-sha-256 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${LEGACY_PORT}" "${BACKEND_USER}" "${BACKEND_PASSWORD}"; then
  _u="$(query_current_user "${LEGACY_PORT}" "${BACKEND_USER}" "${BACKEND_PASSWORD}")"
  if [ "${_u}" = "${BACKEND_USER}" ]; then
    pass "legacy client auth works, current_user=${BACKEND_USER}"
  else
    fail "legacy current_user mismatch (got '${_u}')"
  fi
else
  fail "legacy pgbouncer did not become ready"
  docker logs "pgpooler-legacy-live-${SUFFIX}" 2>&1 | head -20 || true
fi
docker rm -f "pgpooler-legacy-live-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Tests B/C/F: split frontend works, backend identity correct ---"
SPLIT_PORT=16432
docker run -d --name "pgpooler-split-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${SPLIT_PORT}:6432" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${SPLIT_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "frontend app_user/app_password ACCEPTs (B)"
  _u="$(query_current_user "${SPLIT_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}")"
  if [ "${_u}" = "${BACKEND_USER}" ]; then
    pass "SELECT current_user=${BACKEND_USER} via frontend (C+F)"
  else
    fail "split current_user mismatch (got '${_u}', want '${BACKEND_USER}')"
  fi
else
  fail "split pgbouncer did not become ready (frontend ACCEPT failed)"
  docker logs "pgpooler-split-live-${SUFFIX}" 2>&1 | head -20 || true
fi

log "--- Test D: backend credentials MUST NOT authenticate to PgBouncer ---"
if try_connect "${SPLIT_PORT}" "${BACKEND_USER}" "${BACKEND_PASSWORD}"; then
  fail "backend DB_USER/DB_PASSWORD authenticated to PgBouncer (isolation broken)"
else
  pass "backend DB_USER/DB_PASSWORD REJECTed as frontend (D)"
fi
log "--- Acceptance matrix: DB_USER with wrong password ---"
if try_connect "${SPLIT_PORT}" "${BACKEND_USER}" "${WRONG_PASSWORD}"; then
  fail "backend user with wrong password should be rejected"
else
  pass "backend user with wrong password REJECTed"
fi

log "--- Test E: wrong frontend password fails ---"
if try_connect "${SPLIT_PORT}" "${FRONTEND_USER}" "${WRONG_PASSWORD}"; then
  fail "wrong frontend password should not authenticate"
else
  pass "wrong frontend password is rejected (E)"
fi

log "--- Test G: no secret leakage in live logs + restrictive perms ---"
docker logs "pgpooler-split-live-${SUFFIX}" >/tmp/pgpooler-live-logs-${SUFFIX}.log 2>&1 || true
_LEAK=0
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-live-logs-${SUFFIX}.log 2>/dev/null; then
  fail "backend password leaked into live container logs"
  _LEAK=1
else
  pass "no backend password in live logs"
fi
if grep -F -q "${FRONTEND_PASSWORD}" /tmp/pgpooler-live-logs-${SUFFIX}.log 2>/dev/null; then
  fail "frontend password leaked into live container logs"
  _LEAK=1
else
  pass "no frontend password in live logs"
fi
if [ "${_LEAK}" = "0" ]; then
  : # both passed above
fi
if docker exec "pgpooler-split-live-${SUFFIX}" sh -c 'test "$(stat -c %a /etc/pgbouncer/pgbouncer.ini)" = "600"' >/dev/null 2>&1; then
  pass "live pgbouncer.ini is mode 0600"
else
  fail "live pgbouncer.ini is not mode 0600"
fi
docker rm -f "pgpooler-split-live-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test S: special-character backend password live ---"
PG_SPECIAL="pgpooler-special-pg-${SUFFIX}"
SPECIAL_PORT=16433
docker run -d --name "${PG_SPECIAL}" --network "${NET}" \
  -e "POSTGRES_USER=${BACKEND_USER}" -e "POSTGRES_PASSWORD=${SPECIAL_BACKEND_PASSWORD}" -e "POSTGRES_DB=${TESTDB}" \
  postgres:17 >/dev/null
_SPECIAL_READY=0
_tries=0
while [ "${_tries}" -lt 30 ]; do
  if docker exec "${PG_SPECIAL}" pg_isready -U "${BACKEND_USER}" >/dev/null 2>&1; then
    _SPECIAL_READY=1
    break
  fi
  _tries=$((_tries + 1))
  sleep 1
done
if [ "${_SPECIAL_READY}" = "1" ]; then
  pass "special-char PostgreSQL is ready"
else
  fail "special-char PostgreSQL did not become ready"
fi
docker run -d --name "pgpooler-special-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${SPECIAL_PORT}:6432" \
  -e DB_HOST="${PG_SPECIAL}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${SPECIAL_BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${SPECIAL_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "special-char frontend ACCEPTs"
  _u="$(query_current_user "${SPECIAL_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}")"
  if [ "${_u}" = "${BACKEND_USER}" ]; then
    pass "special-char SELECT current_user=${BACKEND_USER}"
  else
    fail "special-char current_user mismatch (got '${_u}')"
  fi
else
  fail "special-char pgbouncer did not become ready"
  docker logs "pgpooler-special-live-${SUFFIX}" 2>&1 | head -20 || true
fi
if try_connect "${SPECIAL_PORT}" "${BACKEND_USER}" "${SPECIAL_BACKEND_PASSWORD}"; then
  fail "special-char backend creds authenticated to PgBouncer (must reject)"
else
  pass "special-char backend creds REJECTed as frontend"
fi
docker logs "pgpooler-special-live-${SUFFIX}" >/tmp/pgpooler-special-logs-${SUFFIX}.log 2>&1 || true
if grep -F -q "${SPECIAL_BACKEND_PASSWORD}" /tmp/pgpooler-special-logs-${SUFFIX}.log 2>/dev/null; then
  fail "special-char backend password leaked into logs"
else
  pass "no special-char backend password in logs"
fi
if grep -F -q "${FRONTEND_PASSWORD}" /tmp/pgpooler-special-logs-${SUFFIX}.log 2>/dev/null; then
  fail "frontend password leaked into special-char logs"
else
  pass "no frontend password in special-char logs"
fi
docker rm -f "pgpooler-special-live-${SUFFIX}" "${PG_SPECIAL}" >/dev/null 2>&1 || true

log "--- Test FS: special-character frontend password live (scram) ---"
FRONT_SPECIAL_PORT=16434
docker run -d --name "pgpooler-frontspecial-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${FRONT_SPECIAL_PORT}:6432" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${SPECIAL_FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${FRONT_SPECIAL_PORT}" "${FRONTEND_USER}" "${SPECIAL_FRONTEND_PASSWORD}"; then
  pass "special-char frontend password ACCEPTs"
  _u="$(query_current_user "${FRONT_SPECIAL_PORT}" "${FRONTEND_USER}" "${SPECIAL_FRONTEND_PASSWORD}")"
  if [ "${_u}" = "${BACKEND_USER}" ]; then
    pass "special-char frontend SELECT current_user=${BACKEND_USER}"
  else
    fail "special-char frontend current_user mismatch (got '${_u}')"
  fi
else
  fail "special-char frontend pgbouncer did not become ready"
  docker logs "pgpooler-frontspecial-live-${SUFFIX}" 2>&1 | head -20 || true
fi
if try_connect "${FRONT_SPECIAL_PORT}" "${FRONTEND_USER}" "${WRONG_PASSWORD}"; then
  fail "wrong frontend password should be rejected (special frontend live)"
else
  pass "wrong frontend password rejected (special frontend live)"
fi
if try_connect "${FRONT_SPECIAL_PORT}" "${BACKEND_USER}" "${BACKEND_PASSWORD}"; then
  fail "backend creds authenticated to special-frontend PgBouncer (must reject)"
else
  pass "backend creds REJECTed at special-frontend PgBouncer"
fi
docker logs "pgpooler-frontspecial-live-${SUFFIX}" >/tmp/pgpooler-frontspecial-logs-${SUFFIX}.log 2>&1 || true
if grep -F -q "${SPECIAL_FRONTEND_PASSWORD}" /tmp/pgpooler-frontspecial-logs-${SUFFIX}.log 2>/dev/null; then
  fail "special-char frontend password leaked into logs"
else
  pass "no special-char frontend password in logs"
fi
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-frontspecial-logs-${SUFFIX}.log 2>/dev/null; then
  fail "backend password leaked into special-frontend logs"
else
  pass "no backend password in special-frontend logs"
fi
if docker exec "pgpooler-frontspecial-live-${SUFFIX}" sh -c 'test "$(stat -c %a /etc/pgbouncer/userlist.txt)" = "600"' >/dev/null 2>&1; then
  pass "special-frontend userlist.txt is mode 0600"
else
  fail "special-frontend userlist.txt is not mode 0600"
fi
docker rm -f "pgpooler-frontspecial-live-${SUFFIX}" >/dev/null 2>&1 || true

# ================================================================ TLS/UI
# CapRover-friendly frontend TLS (PGPOOLER_SSL_MODE) + HTTP docs UI.
# All TLS tests use per-run temp CAs/certs (never committed, never printed).
# Poll interval is shortened to 5s for test speed (default 300s in prod).

log "--- TLS helpers: temp CA infrastructure ---"
TLS_BASE="/tmp/pgpooler-tls-${SUFFIX}"
mkdir -p "${TLS_BASE}" 2>/dev/null || true

# Generate a test CA + server cert for $1=hostname, outputs in $2=dir.
# Sets no globals, prints nothing secret.
make_test_cert() {
  _m_host="$1"; _m_dir="$2"
  mkdir -p "${_m_dir}" 2>/dev/null || true
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${_m_dir}/ca.key" -out "${_m_dir}/ca.crt" \
    -days 2 -subj "/CN=Test CA ${SUFFIX}" >/dev/null 2>&1 || return 1
  cat > "${_m_dir}/openssl.cnf" <<EOF2
[req]
distinguished_name = dn
req_extensions = ext
[dn]
[ext]
subjectAltName = DNS:${_m_host},DNS:localhost,IP:127.0.0.1
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF2
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${_m_dir}/srv.key" -out "${_m_dir}/srv.csr" \
    -subj "/CN=${_m_host}" >/dev/null 2>&1 || return 1
  openssl x509 -req -in "${_m_dir}/srv.csr" \
    -CA "${_m_dir}/ca.crt" -CAkey "${_m_dir}/ca.key" -CAcreateserial \
    -out "${_m_dir}/srv.crt" -days 2 \
    -extensions ext -extfile "${_m_dir}/openssl.cnf" >/dev/null 2>&1 || return 1
  cat "${_m_dir}/srv.crt" "${_m_dir}/ca.crt" > "${_m_dir}/fullchain.pem" 2>/dev/null || return 1
  cp "${_m_dir}/srv.key" "${_m_dir}/privkey.pem" 2>/dev/null || return 1
  chmod 644 "${_m_dir}/fullchain.pem" 2>/dev/null || true
  chmod 600 "${_m_dir}/privkey.pem" "${_m_dir}/srv.key" "${_m_dir}/ca.key" 2>/dev/null || true
  return 0
}

# Install a generated cert dir into a CapRover tree for $1=host.
install_test_cert() {
  _i_src="$1"; _i_tree="$2"; _i_host="$3"
  mkdir -p "${_i_tree}/live/${_i_host}" 2>/dev/null || true
  cp "${_i_src}/fullchain.pem" "${_i_tree}/live/${_i_host}/fullchain.pem" 2>/dev/null || return 1
  cp "${_i_src}/privkey.pem" "${_i_tree}/live/${_i_host}/privkey.pem" 2>/dev/null || return 1
  chmod 644 "${_i_tree}/live/${_i_host}/fullchain.pem" 2>/dev/null || true
  chmod 600 "${_i_tree}/live/${_i_host}/privkey.pem" 2>/dev/null || true
  return 0
}

# TLS psql helpers (no secrets printed). Use PGSSLMODE env (libpq-native)
# to force the wire mode; passing sslmode as a psql positional arg would
# be misinterpreted as dbname/user instead of a connection parameter.
tls_require_connect() {
  _t_hp="$1"; _t_u="$2"; _t_p="$3"
  PGSSLMODE=require PGPASSWORD="${_t_p}" psql -X -q -h 127.0.0.1 -p "${_t_hp}" -U "${_t_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1
}
tls_disable_connect() {
  _t_hp="$1"; _t_u="$2"; _t_p="$3"
  PGSSLMODE=disable PGPASSWORD="${_t_p}" psql -X -q -h 127.0.0.1 -p "${_t_hp}" -U "${_t_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1
}
tls_verify_full_localhost() {
  _t_hp="$1"; _t_u="$2"; _t_p="$3"; _t_ca="$4"
  PGSSLMODE=verify-full PGSSLROOTCERT="${_t_ca}" PGPASSWORD="${_t_p}" psql -X -q -h localhost -p "${_t_hp}" -U "${_t_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1
}
fetch_ui() {
  _f_port="$1"; _f_out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -s -m 5 "http://127.0.0.1:${_f_port}/" -o "${_f_out}" 2>/dev/null || return 1
  else
    wget -q -O "${_f_out}" "http://127.0.0.1:${_f_port}/" 2>/dev/null || return 1
  fi
  return 0
}
wait_ui() {
  _w_port="$1"
  _w_tries=0
  while [ "${_w_tries}" -lt 30 ]; do
    if fetch_ui "${_w_port}" "/tmp/pgpooler-uiwait-${SUFFIX}.tmp" 2>/dev/null; then
      if grep -q "PgPooler-Uma" "/tmp/pgpooler-uiwait-${SUFFIX}.tmp" 2>/dev/null; then
        rm -f "/tmp/pgpooler-uiwait-${SUFFIX}.tmp" 2>/dev/null || true
        return 0
      fi
    fi
    _w_tries=$((_w_tries + 1))
    sleep 1
  done
  return 1
}
wait_tls_state() {
  # Args: container expected_state timeout_secs
  _ws_c="$1"; _ws_exp="$2"; _ws_timeout="${3:-30}"
  _ws_t=0
  while [ "${_ws_t}" -lt "${_ws_timeout}" ]; do
    _ws_got=$(docker exec "${_ws_c}" cat /run/pgbouncer/pgpooler.state 2>/dev/null | grep '^TLS_STATE=' | cut -d= -f2- || printf '')
    if [ "${_ws_got}" = "${_ws_exp}" ]; then
      return 0
    fi
    sleep 1
    _ws_t=$((_ws_t + 1))
  done
  return 1
}
tls_fingerprint() {
  _fp_port="$1"; _fp_host="${2:-localhost}"
  (echo | openssl s_client -connect "127.0.0.1:${_fp_port}" -servername "${_fp_host}" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || printf '') | tr -d '\n'
}

log "--- Test P0: PGPOOLER_SSL_MODE policy validation ---"
if docker run --rm --name "pgpooler-mode-invalid-${SUFFIX}" \
  -e DB_HOST=fakehost -e PGPOOLER_SSL_MODE=bogus \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-mode-invalid-${SUFFIX}.log 2>&1; then
  fail "invalid PGPOOLER_SSL_MODE should fail startup"
else
  if grep -qi "invalid PGPOOLER_SSL_MODE" /tmp/pgpooler-mode-invalid-${SUFFIX}.log 2>/dev/null; then
    pass "invalid PGPOOLER_SSL_MODE fails clearly"
  else
    fail "invalid mode failed without clear error"
  fi
fi
for _m in disabled prefer required; do
  case "${_m}" in
    required)
      # required without source must fail fast (no PUBLIC_HOST, no manual).
      if docker run --rm --name "pgpooler-mode-${SUFFIX}-${_m}" \
        -e DB_HOST=fakehost -e PGPOOLER_SSL_MODE=required \
        --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-mode-${SUFFIX}-${_m}.log 2>&1; then
        fail "required without TLS source should fail"
      else
        pass "required without source fails fast (no silent plaintext)"
      fi
      ;;
    *)
      if docker run --rm --name "pgpooler-mode-${SUFFIX}-${_m}" \
        -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
        -e PGPOOLER_SSL_MODE="${_m}" \
        --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-mode-${SUFFIX}-${_m}.log 2>&1; then
        pass "PGPOOLER_SSL_MODE=${_m} accepted"
      else
        fail "PGPOOLER_SSL_MODE=${_m} should be accepted"
      fi
      ;;
  esac
done
# Default is prefer: with cert present and no explicit mode, TLS requires.
TLS_DEF_DIR="${TLS_BASE}/defmode"
TLS_DEF_TREE="${TLS_BASE}/defmode-tree"
if make_test_cert "localhost" "${TLS_DEF_DIR}"; then
  mkdir -p "${TLS_DEF_TREE}/live/localhost" 2>/dev/null || true
  install_test_cert "${TLS_DEF_DIR}" "${TLS_DEF_TREE}" "localhost" || true
  if docker run --rm --name "pgpooler-mode-def-${SUFFIX}" \
    -v "${TLS_DEF_TREE}:/caprover-letsencrypt:ro" \
    -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
    -e PUBLIC_HOST=localhost \
    --entrypoint /entrypoint.sh "${IMAGE}" \
    sh -c 'grep -q "client_tls_sslmode = require" /etc/pgbouncer/pgbouncer.ini && echo DEFMODE_OK' \
    >/tmp/pgpooler-modedef-${SUFFIX}.log 2>&1; then
    if grep -q "DEFMODE_OK" /tmp/pgpooler-modedef-${SUFFIX}.log 2>/dev/null; then
      pass "default PGPOOLER_SSL_MODE is prefer (auto require with cert)"
    else
      fail "default mode did not auto-require with cert"
    fi
  else
    fail "default mode container run failed"
  fi
else
  fail "could not generate default-mode test cert"
fi
# Conflict: automatic + manual must fail clearly.
if docker run --rm --name "pgpooler-conflict-${SUFFIX}" \
  -e DB_HOST=fakehost -e PUBLIC_HOST=pgpooler.example.com -e PGPOOLER_SSL_MODE=prefer \
  -e CLIENT_TLS_SSLMODE=require -e CLIENT_TLS_CERT_FILE=/tmp/c -e CLIENT_TLS_KEY_FILE=/tmp/k \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-conflict-${SUFFIX}.log 2>&1; then
  fail "automatic+manual conflict should fail startup"
else
  if grep -qi "conflicting frontend TLS" /tmp/pgpooler-conflict-${SUFFIX}.log 2>/dev/null; then
    pass "automatic vs manual conflict fails clearly"
  else
    fail "conflict failed without clear error"
  fi
fi
# Invalid PUBLIC_HOST must fail (path traversal / injection guard).
if docker run --rm --name "pgpooler-badhost-${SUFFIX}" \
  -e DB_HOST=fakehost -e "PUBLIC_HOST=../evil.example.com" -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-badhost-${SUFFIX}.log 2>&1; then
  fail "path-traversal PUBLIC_HOST should fail"
else
  if grep -qi "invalid PUBLIC_HOST" /tmp/pgpooler-badhost-${SUFFIX}.log 2>/dev/null; then
    pass "invalid PUBLIC_HOST rejected clearly"
  else
    fail "bad host failed without clear error"
  fi
fi

log "--- Test P1: disabled ignores cert, stays plaintext, no auto switch ---"
TLS_DIS_DIR="${TLS_BASE}/disabled"
TLS_DIS_TREE="${TLS_BASE}/disabled-tree"
DIS_PORT=16435
DIS_UI=18035
if make_test_cert "localhost" "${TLS_DIS_DIR}" && install_test_cert "${TLS_DIS_DIR}" "${TLS_DIS_TREE}" "localhost"; then
  pass "disabled test cert generated"
else
  fail "disabled test cert generation failed"
fi
docker run -d --name "pgpooler-disabled-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${DIS_PORT}:6432" -p "127.0.0.1:${DIS_UI}:8080" \
  -v "${TLS_DIS_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=disabled -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${DIS_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "disabled with cert starts plaintext"
else
  fail "disabled with cert did not start"
  docker logs "pgpooler-disabled-live-${SUFFIX}" 2>&1 | head -20 || true
fi
if docker exec "pgpooler-disabled-live-${SUFFIX}" grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini 2>/dev/null; then
  pass "disabled config is explicit disable despite cert"
else
  fail "disabled config should be disable"
fi
if wait_ui "${DIS_UI}"; then
  pass "disabled UI available"
  if fetch_ui "${DIS_UI}" "/tmp/pgpooler-dis-ui-${SUFFIX}.html"; then
    if grep -q "Disabled" "/tmp/pgpooler-dis-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "disabled UI reports Disabled"
    else
      fail "disabled UI should report Disabled"
    fi
    rm -f "/tmp/pgpooler-dis-ui-${SUFFIX}.html" 2>/dev/null || true
  else
    fail "disabled UI fetch failed"
  fi
else
  fail "disabled UI not available"
fi
# Watcher must not switch TLS on in disabled mode (wait > poll interval).
sleep 12
if docker exec "pgpooler-disabled-live-${SUFFIX}" grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini 2>/dev/null; then
  pass "disabled watcher did not enable TLS"
else
  fail "disabled watcher switched TLS on (must not)"
fi
if try_connect "${DIS_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "disabled plaintext still succeeds after wait"
else
  fail "disabled plaintext should still succeed"
fi
docker rm -f "pgpooler-disabled-live-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P2: prefer no cert starts plaintext + UI plaintext state ---"
P2_PORT=16436
P2_UI=18036
docker run -d --name "pgpooler-prefer-plain-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P2_PORT}:6432" -p "127.0.0.1:${P2_UI}:8080" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${P2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "prefer no-cert starts plaintext"
else
  fail "prefer no-cert did not start"
fi
if wait_ui "${P2_UI}"; then
  pass "prefer no-cert UI available"
  if fetch_ui "${P2_UI}" "/tmp/pgpooler-p2-ui-${SUFFIX}.html"; then
    if grep -q "Not available - plaintext currently enabled" "/tmp/pgpooler-p2-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "prefer no-cert UI reports plaintext state"
    else
      fail "prefer no-cert UI should report plaintext"
    fi
    if grep -q "sslmode=disable" "/tmp/pgpooler-p2-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "prefer no-cert UI uses sslmode=disable (no misleading verify-full)"
    else
      fail "prefer no-cert UI should use sslmode=disable"
    fi
    if grep -q "verify-full" "/tmp/pgpooler-p2-ui-${SUFFIX}.html" 2>/dev/null; then
      fail "prefer no-cert UI must not advertise verify-full"
    else
      pass "prefer no-cert UI does not mislead with verify-full"
    fi
    if grep -q "sslrootcert" "/tmp/pgpooler-p2-ui-${SUFFIX}.html" 2>/dev/null; then
      fail "prefer no-cert UI must not mention sslrootcert"
    else
      pass "prefer no-cert UI has no trust-store parameter"
    fi
    rm -f "/tmp/pgpooler-p2-ui-${SUFFIX}.html" 2>/dev/null || true
  else
    fail "prefer no-cert UI fetch failed"
  fi
else
  fail "prefer no-cert UI not available"
fi
docker rm -f "pgpooler-prefer-plain-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P3: prefer with cert requires TLS, verify-full works ---"
TLS_P3_DIR="${TLS_BASE}/p3"
TLS_P3_TREE="${TLS_BASE}/p3-tree"
P3_PORT=16437
P3_UI=18037
if make_test_cert "localhost" "${TLS_P3_DIR}" && install_test_cert "${TLS_P3_DIR}" "${TLS_P3_TREE}" "localhost"; then
  pass "prefer-with-cert test cert generated"
else
  fail "prefer-with-cert cert generation failed"
fi
docker run -d --name "pgpooler-prefer-tls-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P3_PORT}:6432" -p "127.0.0.1:${P3_UI}:8080" \
  -v "${TLS_P3_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
# Boot-time activation verifies the live endpoint before publishing
# active, so wait for the state rather than assuming a fixed delay.
if wait_tls_state "pgpooler-prefer-tls-${SUFFIX}" "active" 30; then
  pass "prefer with cert reaches verified active state"
else
  fail "prefer with cert did not reach active state"
  docker logs "pgpooler-prefer-tls-${SUFFIX}" 2>&1 | head -20 || true
fi
if docker exec "pgpooler-prefer-tls-${SUFFIX}" grep -q "client_tls_sslmode = require" /etc/pgbouncer/pgbouncer.ini 2>/dev/null; then
  pass "prefer with cert uses native require"
else
  fail "prefer with cert should use client_tls_sslmode=require"
fi
if tls_disable_connect "${P3_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "prefer with cert must reject plaintext (sslmode=disable)"
else
  pass "prefer with cert rejects plaintext"
fi
if tls_require_connect "${P3_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "prefer with cert accepts TLS require"
else
  fail "prefer with cert TLS require failed"
  docker logs "pgpooler-prefer-tls-${SUFFIX}" 2>&1 | head -20 || true
fi
if tls_verify_full_localhost "${P3_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}" "${TLS_P3_DIR}/ca.crt"; then
  pass "prefer with cert verify-full works with test CA"
else
  fail "verify-full with test CA failed"
fi
if wait_ui "${P3_UI}"; then
  if fetch_ui "${P3_UI}" "/tmp/pgpooler-p3-ui-${SUFFIX}.html"; then
    if grep -q "Available and required" "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "prefer with cert UI reports required"
    else
      fail "prefer with cert UI should report required"
    fi
    if grep -q "sslmode=verify-full" "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "prefer with cert UI recommends verify-full"
    else
      fail "prefer with cert UI should recommend verify-full"
    fi
    if grep -F -q "sslmode=verify-full&amp;sslrootcert=system" "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "prefer with cert UI uses libpq OS trust-store form (escaped)"
    else
      fail "prefer with cert UI should use sslrootcert=system form"
    fi
    # The browser-visible (HTML-decoded) connection string must carry a
    # literal `&` between the libpq parameters.
    if sed -e 's/&amp;/\&/g' "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null | grep -F -q "?sslmode=verify-full&sslrootcert=system"; then
      pass "prefer with cert UI shows usable libpq connection string"
    else
      fail "prefer with cert UI connection string must be directly usable"
    fi
    if grep -q "operating system trust store" "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "prefer with cert UI explains OS trust store"
    else
      fail "prefer with cert UI should explain OS trust store"
    fi
    if grep -F -q "${BACKEND_PASSWORD}" "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null || grep -F -q "${FRONTEND_PASSWORD}" "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null; then
      fail "prefer with cert UI leaked a credential"
    else
      pass "prefer with cert UI contains no credentials"
    fi
    rm -f "/tmp/pgpooler-p3-ui-${SUFFIX}.html" 2>/dev/null || true
  else
    fail "prefer with cert UI fetch failed"
  fi
else
  fail "prefer with cert UI not available"
fi
# Runtime perms: private copies 0600 postgres, source untouched.
if docker exec "pgpooler-prefer-tls-${SUFFIX}" sh -c 'test "$(stat -c %a /run/pgbouncer/tls/fullchain.pem)" = "600" && test "$(stat -c %a /run/pgbouncer/tls/privkey.pem)" = "600"' >/dev/null 2>&1; then
  pass "runtime TLS copies are mode 0600"
else
  fail "runtime TLS copies should be 0600"
fi
if docker exec "pgpooler-prefer-tls-${SUFFIX}" sh -c 'ps -o user= -C pgbouncer 2>/dev/null | grep -q postgres || ps aux 2>/dev/null | grep "[p]gbouncer" | grep -q postgres' >/dev/null 2>&1; then
  pass "PgBouncer runs as postgres (not root)"
else
  fail "PgBouncer should run as postgres"
fi
docker rm -f "pgpooler-prefer-tls-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P4: prefer cert appears after startup (no container restart) ---"
TLS_P4_DIR="${TLS_BASE}/p4"
TLS_P4_TREE="${TLS_BASE}/p4-tree"
P4_PORT=16438
P4_UI=18038
mkdir -p "${TLS_P4_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_P4_DIR}"; then
  pass "transition test cert generated (not yet installed)"
else
  fail "transition cert generation failed"
fi
docker run -d --name "pgpooler-transition-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P4_PORT}:6432" -p "127.0.0.1:${P4_UI}:8080" \
  -v "${TLS_P4_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${P4_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "transition: initial plaintext works"
else
  fail "transition: initial plaintext did not start"
fi
_P4_ID_BEFORE=$(docker inspect "pgpooler-transition-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
install_test_cert "${TLS_P4_DIR}" "${TLS_P4_TREE}" "localhost" || true
if wait_tls_state "pgpooler-transition-${SUFFIX}" "active" 30; then
  pass "transition: watcher detected certificate (state active)"
else
  fail "transition: watcher did not reach active state"
  docker logs "pgpooler-transition-${SUFFIX}" 2>&1 | tail -20 || true
fi
sleep 2
_P4_ID_AFTER=$(docker inspect "pgpooler-transition-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if [ -n "${_P4_ID_BEFORE}" ] && [ "${_P4_ID_BEFORE}" = "${_P4_ID_AFTER}" ]; then
  pass "transition: container did not restart"
else
  fail "transition: container restarted (must not)"
fi
if tls_disable_connect "${P4_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "transition: plaintext must now be rejected"
else
  pass "transition: plaintext now rejected after cert"
fi
if tls_require_connect "${P4_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "transition: TLS succeeds after cert"
else
  fail "transition: TLS should succeed after cert"
fi
docker rm -f "pgpooler-transition-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P5: required waits, then activates with TLS only (no plaintext window) ---"
TLS_P5_DIR="${TLS_BASE}/p5"
TLS_P5_TREE="${TLS_BASE}/p5-tree"
P5_PORT=16439
P5_UI=18039
mkdir -p "${TLS_P5_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_P5_DIR}"; then
  pass "required test cert generated (not yet installed)"
else
  fail "required cert generation failed"
fi
docker run -d --name "pgpooler-required-wait-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P5_PORT}:6432" -p "127.0.0.1:${P5_UI}:8080" \
  -v "${TLS_P5_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=required -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
sleep 6
if wait_ui "${P5_UI}"; then
  pass "required waiting: HTTP UI available"
  if fetch_ui "${P5_UI}" "/tmp/pgpooler-p5-ui-${SUFFIX}.html"; then
    if grep -q "Required - waiting for certificate" "/tmp/pgpooler-p5-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "required waiting: UI reports waiting state"
    else
      fail "required waiting UI should report waiting"
    fi
    if grep -F -q "sslmode=verify-full&amp;sslrootcert=system" "/tmp/pgpooler-p5-ui-${SUFFIX}.html" 2>/dev/null; then
      pass "required waiting: UI future example uses libpq trust-store form"
    else
      fail "required waiting UI future example should use libpq form"
    fi
    rm -f "/tmp/pgpooler-p5-ui-${SUFFIX}.html" 2>/dev/null || true
  else
    fail "required waiting UI fetch failed"
  fi
else
  fail "required waiting UI not available"
fi
# PgBouncer listener must be unavailable (no plaintext window).
if PGPASSWORD="${FRONTEND_PASSWORD}" psql -X -q -h 127.0.0.1 -p "${P5_PORT}" -U "${FRONTEND_USER}" -d "${TESTDB}" -tA -c "SELECT 1;" "connect_timeout=3" >/dev/null 2>&1; then
  fail "required waiting: PostgreSQL must be unavailable"
else
  pass "required waiting: PostgreSQL unavailable (no plaintext)"
fi
if docker exec "pgpooler-required-wait-${SUFFIX}" cat /run/pgbouncer/pgpooler.state 2>/dev/null | grep -q "TLS_STATE=waiting"; then
  pass "required waiting: state is waiting"
else
  fail "required waiting state should be waiting"
fi
# Container stable (not crash-looping): still running after 6s.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pgpooler-required-wait-${SUFFIX}"; then
  pass "required waiting: container stable (not crash-looping)"
else
  fail "required waiting container should remain running"
fi
_P5_ID_BEFORE=$(docker inspect "pgpooler-required-wait-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
install_test_cert "${TLS_P5_DIR}" "${TLS_P5_TREE}" "localhost" || true
if wait_tls_state "pgpooler-required-wait-${SUFFIX}" "active" 30; then
  pass "required: watcher activated on certificate"
else
  fail "required: did not activate on certificate"
fi
sleep 3
if tls_disable_connect "${P5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "required after cert: plaintext must never succeed"
else
  pass "required after cert: plaintext rejected (no window)"
fi
if tls_require_connect "${P5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "required after cert: first TLS connection succeeds"
else
  fail "required after cert: TLS should succeed"
fi
_P5_ID_AFTER=$(docker inspect "pgpooler-required-wait-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if [ -n "${_P5_ID_BEFORE}" ] && [ "${_P5_ID_BEFORE}" = "${_P5_ID_AFTER}" ]; then
  pass "required: container did not restart"
else
  fail "required: container restarted (must not)"
fi
docker rm -f "pgpooler-required-wait-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P6: renewal without container restart, new cert served ---"
TLS_P6A_DIR="${TLS_BASE}/p6a"
TLS_P6B_DIR="${TLS_BASE}/p6b"
TLS_P6_TREE="${TLS_BASE}/p6-tree"
P6_PORT=16440
P6_UI=18040
if make_test_cert "localhost" "${TLS_P6A_DIR}" && install_test_cert "${TLS_P6A_DIR}" "${TLS_P6_TREE}" "localhost"; then
  pass "renewal cert A installed"
else
  fail "renewal cert A setup failed"
fi
docker run -d --name "pgpooler-renewal-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P6_PORT}:6432" -p "127.0.0.1:${P6_UI}:8080" \
  -v "${TLS_P6_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-renewal-${SUFFIX}" "active" 30; then
  pass "renewal: boot reaches verified active state (cert A)"
else
  fail "renewal: boot did not reach active state"
fi
if tls_require_connect "${P6_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "renewal: initial TLS works (cert A)"
else
  fail "renewal: initial TLS failed"
fi
_FP_A=$(tls_fingerprint "${P6_PORT}" "localhost")
if [ -n "${_FP_A}" ]; then
  pass "renewal: fingerprinted cert A"
else
  fail "renewal: could not fingerprint cert A"
fi
_P6_ID_BEFORE=$(docker inspect "pgpooler-renewal-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if make_test_cert "localhost" "${TLS_P6B_DIR}"; then
  # Ensure B differs from A (new key).
  _FP_CA=$(openssl x509 -in "${TLS_P6A_DIR}/srv.crt" -noout -fingerprint -sha256 2>/dev/null || printf '')
  _FP_CB=$(openssl x509 -in "${TLS_P6B_DIR}/srv.crt" -noout -fingerprint -sha256 2>/dev/null || printf '')
  if [ -n "${_FP_CA}" ] && [ -n "${_FP_CB}" ] && [ "${_FP_CA}" != "${_FP_CB}" ]; then
    pass "renewal cert B differs from A"
  else
    fail "renewal cert B should differ from A"
  fi
else
  fail "renewal cert B generation failed"
fi
install_test_cert "${TLS_P6B_DIR}" "${TLS_P6_TREE}" "localhost" || true
# Wait for new fingerprint on new connections (up to 30s).
_FP_B=""
_tries=0
while [ "${_tries}" -lt 30 ]; do
  sleep 1
  _FP_B=$(tls_fingerprint "${P6_PORT}" "localhost")
  if [ -n "${_FP_B}" ] && [ "${_FP_B}" != "${_FP_A}" ]; then
    break
  fi
  _tries=$((_tries + 1))
done
if [ -n "${_FP_B}" ] && [ "${_FP_B}" != "${_FP_A}" ]; then
  pass "renewal: new connections receive cert B"
else
  fail "renewal: fingerprint did not change to B"
  docker logs "pgpooler-renewal-${SUFFIX}" 2>&1 | tail -10 || true
fi
_P6_ID_AFTER=$(docker inspect "pgpooler-renewal-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if [ -n "${_P6_ID_BEFORE}" ] && [ "${_P6_ID_BEFORE}" = "${_P6_ID_AFTER}" ]; then
  pass "renewal: container did not restart"
else
  fail "renewal: container restarted (must not)"
fi
if tls_require_connect "${P6_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "renewal: TLS still works after reload"
else
  fail "renewal: TLS should work after reload"
fi
if docker logs "pgpooler-renewal-${SUFFIX}" 2>&1 | grep -q "Frontend TLS certificate changed; reloading PgBouncer"; then
  pass "renewal: watcher logged reload"
else
  fail "renewal: watcher should log reload"
fi
docker rm -f "pgpooler-renewal-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P7: invalid certificates never activate TLS ---"
# Each invalid case uses config-only runs (fast) plus one live prefer check.
TLS_INV_BASE="${TLS_BASE}/invalid"
mkdir -p "${TLS_INV_BASE}" 2>/dev/null || true
# Valid reference for localhost.
TLS_VALID_DIR="${TLS_INV_BASE}/valid"
make_test_cert "localhost" "${TLS_VALID_DIR}" || true
# Case missing cert (empty tree).
TLS_MISS_TREE="${TLS_INV_BASE}/miss-tree"
mkdir -p "${TLS_MISS_TREE}/live/localhost" 2>/dev/null || true
if docker run --rm --name "pgpooler-inv-miss-${SUFFIX}" \
  -v "${TLS_MISS_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini && echo INV_MISS_OK' \
  >/tmp/pgpooler-invmiss-${SUFFIX}.log 2>&1; then
  if grep -q "INV_MISS_OK" /tmp/pgpooler-invmiss-${SUFFIX}.log 2>/dev/null; then
    pass "invalid missing cert: prefer stays plaintext"
  else
    fail "missing cert should stay plaintext"
  fi
else
  fail "missing cert run failed"
fi
# Case malformed cert.
TLS_MAL_TREE="${TLS_INV_BASE}/mal-tree"
mkdir -p "${TLS_MAL_TREE}/live/localhost" 2>/dev/null || true
printf 'not a certificate\n' > "${TLS_MAL_TREE}/live/localhost/fullchain.pem" 2>/dev/null || true
cp "${TLS_VALID_DIR}/privkey.pem" "${TLS_MAL_TREE}/live/localhost/privkey.pem" 2>/dev/null || true
if docker run --rm --name "pgpooler-inv-mal-${SUFFIX}" \
  -v "${TLS_MAL_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini && echo INV_MAL_OK' \
  >/tmp/pgpooler-invmal-${SUFFIX}.log 2>&1; then
  if grep -q "INV_MAL_OK" /tmp/pgpooler-invmal-${SUFFIX}.log 2>/dev/null; then
    pass "invalid malformed cert: prefer stays plaintext"
  else
    fail "malformed cert should stay plaintext"
  fi
else
  fail "malformed cert run failed"
fi
# Case hostname mismatch (cert for localhost, host wrong.example.com).
TLS_MM_TREE="${TLS_INV_BASE}/mm-tree"
mkdir -p "${TLS_MM_TREE}/live/wrong.example.com" 2>/dev/null || true
cp "${TLS_VALID_DIR}/fullchain.pem" "${TLS_MM_TREE}/live/wrong.example.com/fullchain.pem" 2>/dev/null || true
cp "${TLS_VALID_DIR}/privkey.pem" "${TLS_MM_TREE}/live/wrong.example.com/privkey.pem" 2>/dev/null || true
if docker run --rm --name "pgpooler-inv-mm-${SUFFIX}" \
  -v "${TLS_MM_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=wrong.example.com -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini && echo INV_MM_OK' \
  >/tmp/pgpooler-invmm-${SUFFIX}.log 2>&1; then
  if grep -q "INV_MM_OK" /tmp/pgpooler-invmm-${SUFFIX}.log 2>/dev/null; then
    pass "invalid hostname mismatch: prefer stays plaintext"
  else
    fail "hostname mismatch should stay plaintext"
  fi
else
  fail "hostname mismatch run failed"
fi
# Case key mismatch (cert A with key B).
TLS_KM_DIR_B="${TLS_INV_BASE}/kmb"
TLS_KM_TREE="${TLS_INV_BASE}/km-tree"
make_test_cert "localhost" "${TLS_KM_DIR_B}" || true
mkdir -p "${TLS_KM_TREE}/live/localhost" 2>/dev/null || true
cp "${TLS_VALID_DIR}/fullchain.pem" "${TLS_KM_TREE}/live/localhost/fullchain.pem" 2>/dev/null || true
cp "${TLS_KM_DIR_B}/privkey.pem" "${TLS_KM_TREE}/live/localhost/privkey.pem" 2>/dev/null || true
if docker run --rm --name "pgpooler-inv-km-${SUFFIX}" \
  -v "${TLS_KM_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini && echo INV_KM_OK' \
  >/tmp/pgpooler-invkm-${SUFFIX}.log 2>&1; then
  if grep -q "INV_KM_OK" /tmp/pgpooler-invkm-${SUFFIX}.log 2>/dev/null; then
    pass "invalid key mismatch: prefer stays plaintext"
  else
    fail "key mismatch should stay plaintext"
  fi
else
  fail "key mismatch run failed"
fi
# Case expired (notAfter in past).
TLS_EXP_DIR="${TLS_INV_BASE}/expwork"
TLS_EXP_TREE="${TLS_INV_BASE}/exp-tree"
mkdir -p "${TLS_EXP_DIR}" "${TLS_EXP_TREE}/live/localhost" 2>/dev/null || true
openssl req -newkey rsa:2048 -nodes -keyout "${TLS_EXP_DIR}/srv.key" -out "${TLS_EXP_DIR}/srv.csr" -subj "/CN=localhost" >/dev/null 2>&1 || true
openssl x509 -req -in "${TLS_EXP_DIR}/srv.csr" -signkey "${TLS_EXP_DIR}/srv.key" -out "${TLS_EXP_DIR}/srv.crt" -not_before 20200101000000Z -not_after 20200201000000Z >/dev/null 2>&1 || true
cp "${TLS_EXP_DIR}/srv.crt" "${TLS_EXP_TREE}/live/localhost/fullchain.pem" 2>/dev/null || true
cp "${TLS_EXP_DIR}/srv.key" "${TLS_EXP_TREE}/live/localhost/privkey.pem" 2>/dev/null || true
if docker run --rm --name "pgpooler-inv-exp-${SUFFIX}" \
  -v "${TLS_EXP_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini && echo INV_EXP_OK' \
  >/tmp/pgpooler-invexp-${SUFFIX}.log 2>&1; then
  if grep -q "INV_EXP_OK" /tmp/pgpooler-invexp-${SUFFIX}.log 2>/dev/null; then
    pass "invalid expired cert: prefer stays plaintext"
  else
    fail "expired cert should stay plaintext"
  fi
else
  fail "expired cert run failed"
fi
# Required with invalid cert stays waiting (PostgreSQL unavailable).
if docker run --rm --name "pgpooler-inv-req-${SUFFIX}" \
  -v "${TLS_MAL_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=required \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "client_tls_sslmode = disable" /etc/pgbouncer/pgbouncer.ini && cat /run/pgbouncer/pgpooler.state | grep -q "TLS_STATE=waiting" && echo INV_REQ_OK' \
  >/tmp/pgpooler-invreq-${SUFFIX}.log 2>&1; then
  if grep -q "INV_REQ_OK" /tmp/pgpooler-invreq-${SUFFIX}.log 2>/dev/null; then
    pass "invalid cert: required stays waiting (no plaintext)"
  else
    fail "required with invalid cert should wait"
  fi
else
  fail "required invalid cert run failed"
fi

log "--- Test P8: Web UI secret isolation + placeholders + escaping ---"
# Distinctive random UI secrets (never printed).
if command -v openssl >/dev/null 2>&1; then
  UI_DB_USER="udb-$(openssl rand -hex 6)"
  UI_DB_PASS="upass-$(openssl rand -hex 8)-X"
  UI_FE_USER="ufe-$(openssl rand -hex 6)"
  UI_FE_PASS="fpass-$(openssl rand -hex 8)-Y"
else
  UI_DB_USER="udb-$$-test"
  UI_DB_PASS="upass-$$-test"
  UI_FE_USER="ufe-$$-test"
  UI_FE_PASS="fpass-$$-test"
fi
P8_PORT=16441
P8_UI=18041
docker run -d --name "pgpooler-ui-secrets-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P8_PORT}:6432" -p "127.0.0.1:${P8_UI}:8080" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${UI_DB_USER}" -e DB_PASSWORD="${UI_DB_PASS}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${UI_FE_USER}" -e PGBOUNCER_PASSWORD="${UI_FE_PASS}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
# Backend role for UI secrets test (create matching role).
docker exec "${PG}" psql -U "${BACKEND_USER}" -d "${TESTDB}" -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${UI_DB_USER}') THEN CREATE ROLE \"${UI_DB_USER}\" LOGIN PASSWORD '${UI_DB_PASS}'; ELSE ALTER ROLE \"${UI_DB_USER}\" LOGIN PASSWORD '${UI_DB_PASS}'; END IF; END \$\$;" >/dev/null 2>&1 || true
docker exec "${PG}" psql -U "${BACKEND_USER}" -d "${TESTDB}" -c "GRANT ALL ON DATABASE \"${TESTDB}\" TO \"${UI_DB_USER}\";" >/dev/null 2>&1 || true
if wait_ui "${P8_UI}"; then
  pass "UI secrets test: page available"
else
  fail "UI secrets test: page not available"
fi
if fetch_ui "${P8_UI}" "/tmp/pgpooler-ui-sec-${SUFFIX}.html"; then
  _UI_LEAK=0
  for _s in "${UI_DB_USER}" "${UI_DB_PASS}" "${UI_FE_USER}" "${UI_FE_PASS}"; do
    if grep -F -q "${_s}" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null; then
      fail "UI leaked a credential value"
      _UI_LEAK=1
      break
    fi
  done
  if [ "${_UI_LEAK}" = "0" ]; then
    pass "UI contains no credential values"
  fi
  if grep -F -q "PGBOUNCER_USER" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null; then
    fail "UI must not contain PGBOUNCER_USER string"
  else
    pass "UI has no PGBOUNCER_USER string"
  fi
  if grep -F -q "PGBOUNCER_PASSWORD" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null; then
    fail "UI must not contain PGBOUNCER_PASSWORD string"
  else
    pass "UI has no PGBOUNCER_PASSWORD string"
  fi
  if grep -F -q "DB_USER" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null; then
    fail "UI must not contain DB_USER string"
  else
    pass "UI has no DB_USER string"
  fi
  if grep -F -q "DB_PASSWORD" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null; then
    fail "UI must not contain DB_PASSWORD string"
  else
    pass "UI has no DB_PASSWORD string"
  fi
  if grep -F -q "&lt;USERNAME&gt;" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null && grep -F -q "&lt;PASSWORD&gt;" "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null; then
    pass "UI shows literal <USERNAME>/<PASSWORD> placeholders"
  else
    fail "UI should show literal placeholders"
  fi
  # Generated container file must also be clean.
  if docker exec "pgpooler-ui-secrets-${SUFFIX}" cat /var/www/index.html 2>/dev/null > "/tmp/pgpooler-ui-sec2-${SUFFIX}.html"; then
    _UI2_LEAK=0
    for _s in "${UI_DB_USER}" "${UI_DB_PASS}" "${UI_FE_USER}" "${UI_FE_PASS}"; do
      if grep -F -q "${_s}" "/tmp/pgpooler-ui-sec2-${SUFFIX}.html" 2>/dev/null; then
        fail "generated web file leaked a credential"
        _UI2_LEAK=1
        break
      fi
    done
    if [ "${_UI2_LEAK}" = "0" ]; then
      pass "generated web file has no credentials"
    fi
    rm -f "/tmp/pgpooler-ui-sec2-${SUFFIX}.html" 2>/dev/null || true
  else
    fail "could not read generated web file"
  fi
  rm -f "/tmp/pgpooler-ui-sec-${SUFFIX}.html" 2>/dev/null || true
else
  fail "UI secrets fetch failed"
fi
docker rm -f "pgpooler-ui-secrets-${SUFFIX}" >/dev/null 2>&1 || true
# Escaping: DB_NAME with HTML specials must be escaped in UI (config-only).
# The container stdout includes startup logs (raw dbname in legacy config
# is preserved upstream behavior); isolate the UI from <!DOCTYPE onwards.
if docker run --rm --name "pgpooler-ui-escape-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER=x -e DB_PASSWORD=y -e 'DB_NAME=a<b>&"c' \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'cat /var/www/index.html' \
  >"/tmp/pgpooler-escape-${SUFFIX}.html" 2>&1; then
  # shellcheck disable=SC2016
  sed -n '/<!DOCTYPE/,$p' "/tmp/pgpooler-escape-${SUFFIX}.html" > "/tmp/pgpooler-escape-ui-${SUFFIX}.html" 2>/dev/null || true
  if grep -F -q "a&lt;b&gt;&amp;&quot;c" "/tmp/pgpooler-escape-ui-${SUFFIX}.html" 2>/dev/null; then
    pass "UI escapes HTML specials in values"
  else
    fail "UI should HTML-escape displayed values"
  fi
  if grep -F -q "a<b>" "/tmp/pgpooler-escape-ui-${SUFFIX}.html" 2>/dev/null; then
    fail "UI must not contain raw <b> from values"
  else
    pass "UI has no raw HTML injection from values"
  fi
  rm -f "/tmp/pgpooler-escape-${SUFFIX}.html" "/tmp/pgpooler-escape-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "UI escape run failed"
fi

log "--- Test P9: healthcheck without auth + Dockerfile expectations ---"
if grep -q "8080" Dockerfile && grep -q "pgpooler-healthcheck" Dockerfile; then
  pass "Dockerfile exposes 8080 and uses new healthcheck"
else
  fail "Dockerfile should expose 8080 and use healthcheck script"
fi
if grep -q "su-exec" Dockerfile && grep -q "openssl" Dockerfile && grep -q "busybox-extras" Dockerfile; then
  pass "Dockerfile has minimal TLS tooling (su-exec/openssl/busybox-extras)"
else
  fail "Dockerfile missing TLS tooling"
fi
if grep -q "USER postgres" Dockerfile; then
  fail "Dockerfile must not run as USER postgres (needs privileged bootstrap)"
else
  pass "Dockerfile allows privileged bootstrap (no USER postgres)"
fi
if [ -f "healthcheck.sh" ] && [ -f "lib/tls.sh" ] && [ -f "lib/ui.sh" ]; then
  pass "TLS/UI/healthcheck helper files present"
else
  fail "helper files missing"
fi
if grep "^HEALTHCHECK" Dockerfile | grep -q "pg_isready"; then
  fail "Dockerfile healthcheck must not use pg_isready (auth noise)"
else
  pass "Dockerfile healthcheck avoids pg_isready auth"
fi
# Live healthcheck: UI + TCP without auth, no postgres login noise.
P9_PORT=16442
P9_UI=18042
docker run -d --name "pgpooler-health-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P9_PORT}:6432" -p "127.0.0.1:${P9_UI}:8080" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${P9_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "healthcheck fixture PgBouncer ready"
else
  fail "healthcheck fixture did not start"
fi
sleep 12
if docker exec "pgpooler-health-live-${SUFFIX}" /usr/local/bin/pgpooler-healthcheck.sh >/dev/null 2>&1; then
  pass "healthcheck script passes without credentials"
else
  fail "healthcheck script should pass"
fi
# Healthcheck must not require auth: no postgres-user login failures caused
# by pg_isready should appear for the frontend auth file path.
if docker logs "pgpooler-health-live-${SUFFIX}" 2>&1 | grep -qi "password leaked\|private key"; then
  fail "healthcheck logs leaked secrets"
else
  pass "healthcheck logs contain no secrets"
fi
docker rm -f "pgpooler-health-live-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test P10: manual CLIENT_TLS_* backward compatibility (no PUBLIC_HOST) ---"
TLS_MAN_DIR="${TLS_BASE}/manual"
TLS_MAN_TREE="${TLS_BASE}/manual-tree"
P10_PORT=16443
P10_UI=18043
if make_test_cert "localhost" "${TLS_MAN_DIR}"; then
  mkdir -p "${TLS_MAN_TREE}" 2>/dev/null || true
  cp "${TLS_MAN_DIR}/fullchain.pem" "${TLS_MAN_TREE}/manual.crt" 2>/dev/null || true
  cp "${TLS_MAN_DIR}/privkey.pem" "${TLS_MAN_TREE}/manual.key" 2>/dev/null || true
  chmod 644 "${TLS_MAN_TREE}/manual.crt" 2>/dev/null || true
  chmod 600 "${TLS_MAN_TREE}/manual.key" 2>/dev/null || true
  chown postgres:postgres "${TLS_MAN_TREE}/manual.crt" "${TLS_MAN_TREE}/manual.key" 2>/dev/null || true
  pass "manual TLS cert staged"
else
  fail "manual cert generation failed"
fi
docker run -d --name "pgpooler-manual-tls-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${P10_PORT}:6432" -p "127.0.0.1:${P10_UI}:8080" \
  -v "${TLS_MAN_TREE}:/manual-tls:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e CLIENT_TLS_SSLMODE=require -e CLIENT_TLS_CERT_FILE=/manual-tls/manual.crt -e CLIENT_TLS_KEY_FILE=/manual-tls/manual.key \
  "${IMAGE}" >/dev/null
sleep 5
if tls_disable_connect "${P10_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "manual TLS should reject plaintext"
else
  pass "manual TLS rejects plaintext (backward compat)"
fi
if tls_require_connect "${P10_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "manual TLS accepts require (backward compat)"
else
  fail "manual TLS require failed"
fi
docker rm -f "pgpooler-manual-tls-${SUFFIX}" >/dev/null 2>&1 || true

# ================================================== Fault-injection (F)
# Deterministic fail-closed regression tests. The image supports
# test-only runtime fault flags (plain files, absent by default, never
# secrets) that the test harness creates/removes inside a running
# container; production behavior is unchanged when they are absent:
#   /run/pgbouncer/.fail-tls-config-update -> config rewrite fails
#   /run/pgbouncer/.fail-tls-reload        -> forward SIGHUP never sent
#   /run/pgbouncer/.fail-tls-rollback      -> rollback SIGHUP never sent
#   /run/pgbouncer/.fail-tls-backup        -> renewal backup fails
#   /run/pgbouncer/.fail-tls-endpoint-verification -> endpoint probe fails
#   /run/pgbouncer/.fail-tls-protocols     -> rewritten config carries a
#     TLS setting PgBouncer rejects at RELOAD while keeping the previous
#     TLS context (proves SIGHUP-delivered-but-not-applied handling)
#   /run/pgbouncer/.fail-tls-install       -> installed key is unloadable
#     (certificate content), so a renewal RELOAD is really rejected while
#     the process survives with the previous context
# Applied-fingerprint semantics under test:
#   applied = source version confirmed live (config verified + expected
#   certificate externally observed on the endpoint). Any failure leaves
#   it unchanged so the next poll retries the same source.

# Read the applied fingerprint recorded inside a container (may be empty).
read_applied_fp() {
  docker exec "$1" cat /run/pgbouncer/tls/.fingerprint 2>/dev/null || printf ''
}
# Content fingerprint of the mounted source pair, computed inside the
# container so the format always matches the watcher implementation.
src_fp_in_container() {
  docker exec "$1" sh -c 'sha256sum "/caprover-letsencrypt/live/'"$2"'/fullchain.pem" "/caprover-letsencrypt/live/'"$2"'/privkey.pem" 2>/dev/null | awk "{print \$1}" | tr "\n" ":"' 2>/dev/null || printf ''
}
# Immediate single-read state assertion (no waiting).
assert_state_now() {
  _as_c="$1"; _as_exp="$2"
  _as_got=$(docker exec "${_as_c}" cat /run/pgbouncer/pgpooler.state 2>/dev/null | grep '^TLS_STATE=' | cut -d= -f2- || printf '')
  [ "${_as_got}" = "${_as_exp}" ]
}
assert_expect_now() {
  _ae_c="$1"; _ae_exp="$2"
  _ae_got=$(docker exec "${_ae_c}" cat /run/pgbouncer/pgpooler.state 2>/dev/null | grep '^EXPECT_PGBOUNCER=' | cut -d= -f2- || printf '')
  [ "${_ae_got}" = "${_ae_exp}" ]
}
# Wait until TLS require works (up to ~15s); for post-activation probes
# where the parent may still be starting PgBouncer.
wait_tls_require() {
  _wtr_hp="$1"; _wtr_u="$2"; _wtr_p="$3"
  _wtr_t=0
  while [ "${_wtr_t}" -lt 15 ]; do
    if tls_require_connect "${_wtr_hp}" "${_wtr_u}" "${_wtr_p}"; then
      return 0
    fi
    sleep 1
    _wtr_t=$((_wtr_t + 1))
  done
  return 1
}

log "--- Test F1: required config-update failure stays fail-closed, then retries ---"
TLS_F1_DIR="${TLS_BASE}/f1"
TLS_F1_TREE="${TLS_BASE}/f1-tree"
F1_PORT=16444
F1_UI=18044
mkdir -p "${TLS_F1_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_F1_DIR}"; then
  pass "F1 cert generated (not yet installed)"
else
  fail "F1 cert generation failed"
fi
docker run -d --name "pgpooler-f1-req-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${F1_PORT}:6432" -p "127.0.0.1:${F1_UI}:8080" \
  -v "${TLS_F1_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=required -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-f1-req-${SUFFIX}" "waiting" 15; then
  pass "F1: initial waiting state"
else
  fail "F1: did not reach waiting state"
fi
_F1_ID_BEFORE=$(docker inspect "pgpooler-f1-req-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
# Inject config-update failure, then deliver the certificate.
docker exec "pgpooler-f1-req-${SUFFIX}" touch /run/pgbouncer/.fail-tls-config-update 2>/dev/null || true
install_test_cert "${TLS_F1_DIR}" "${TLS_F1_TREE}" "localhost" || true
sleep 12
if assert_state_now "pgpooler-f1-req-${SUFFIX}" "waiting"; then
  pass "F1: failed rewrite leaves state waiting (not active)"
else
  fail "F1: state must remain waiting after rewrite failure"
fi
if assert_expect_now "pgpooler-f1-req-${SUFFIX}" "0"; then
  pass "F1: EXPECT_PGBOUNCER stays 0 after rewrite failure"
else
  fail "F1: EXPECT_PGBOUNCER must stay 0 after rewrite failure"
fi
if PGPASSWORD="${FRONTEND_PASSWORD}" psql -X -q -h 127.0.0.1 -p "${F1_PORT}" -U "${FRONTEND_USER}" -d "${TESTDB}" -tA -c "SELECT 1;" "connect_timeout=3" >/dev/null 2>&1; then
  fail "F1: listener must stay unavailable after rewrite failure"
else
  pass "F1: listener unavailable after rewrite failure (fail-closed)"
fi
if fetch_ui "${F1_UI}" "/tmp/pgpooler-f1-ui-${SUFFIX}.html"; then
  if grep -q "Required - waiting for certificate" "/tmp/pgpooler-f1-ui-${SUFFIX}.html" 2>/dev/null; then
    pass "F1: UI still reports waiting (no false active)"
  else
    fail "F1: UI must not claim active after rewrite failure"
  fi
  rm -f "/tmp/pgpooler-f1-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "F1: UI fetch failed"
fi
_F1_APPLIED=$(read_applied_fp "pgpooler-f1-req-${SUFFIX}")
if [ -z "${_F1_APPLIED}" ]; then
  pass "F1: applied fingerprint not advanced on failure"
else
  fail "F1: applied fingerprint must not advance on failure"
fi
# Remove the fault: the next poll must retry and succeed in place.
docker exec "pgpooler-f1-req-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-config-update 2>/dev/null || true
if wait_tls_state "pgpooler-f1-req-${SUFFIX}" "active" 30; then
  pass "F1: retry succeeds after fault removed"
else
  fail "F1: retry did not reach active"
fi
if wait_tls_require "${F1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F1: TLS works after retry"
else
  fail "F1: TLS should work after retry"
fi
if tls_disable_connect "${F1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "F1: plaintext must be rejected after retry"
else
  pass "F1: plaintext rejected after retry (no window)"
fi
_F1_EXPECTED=$(src_fp_in_container "pgpooler-f1-req-${SUFFIX}" "localhost")
_F1_APPLIED_AFTER=$(read_applied_fp "pgpooler-f1-req-${SUFFIX}")
if [ -n "${_F1_EXPECTED}" ] && [ "${_F1_EXPECTED}" = "${_F1_APPLIED_AFTER}" ]; then
  pass "F1: applied fingerprint committed only on success"
else
  fail "F1: applied fingerprint should equal source after success"
fi
_F1_ID_AFTER=$(docker inspect "pgpooler-f1-req-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if [ -n "${_F1_ID_BEFORE}" ] && [ "${_F1_ID_BEFORE}" = "${_F1_ID_AFTER}" ]; then
  pass "F1: container did not restart across failure+retry"
else
  fail "F1: container must not restart"
fi
docker rm -f "pgpooler-f1-req-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test F2: prefer reload failure does not claim active, then retries ---"
TLS_F2_DIR="${TLS_BASE}/f2"
TLS_F2_TREE="${TLS_BASE}/f2-tree"
F2_PORT=16445
F2_UI=18045
mkdir -p "${TLS_F2_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_F2_DIR}"; then
  pass "F2 cert generated (not yet installed)"
else
  fail "F2 cert generation failed"
fi
docker run -d --name "pgpooler-f2-prefer-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${F2_PORT}:6432" -p "127.0.0.1:${F2_UI}:8080" \
  -v "${TLS_F2_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${F2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F2: initial plaintext works"
else
  fail "F2: initial plaintext did not start"
fi
docker exec "pgpooler-f2-prefer-${SUFFIX}" touch /run/pgbouncer/.fail-tls-reload 2>/dev/null || true
install_test_cert "${TLS_F2_DIR}" "${TLS_F2_TREE}" "localhost" || true
sleep 12
if assert_state_now "pgpooler-f2-prefer-${SUFFIX}" "plaintext"; then
  pass "F2: failed reload leaves state plaintext (not active)"
else
  fail "F2: state must remain plaintext after reload failure"
fi
if fetch_ui "${F2_UI}" "/tmp/pgpooler-f2-ui-${SUFFIX}.html"; then
  if grep -q "Not available - plaintext currently enabled" "/tmp/pgpooler-f2-ui-${SUFFIX}.html" 2>/dev/null; then
    pass "F2: UI still reports plaintext (no false active)"
  else
    fail "F2: UI must not claim active after reload failure"
  fi
  rm -f "/tmp/pgpooler-f2-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "F2: UI fetch failed"
fi
_F2_APPLIED=$(read_applied_fp "pgpooler-f2-prefer-${SUFFIX}")
if [ -z "${_F2_APPLIED}" ]; then
  pass "F2: applied fingerprint not advanced on reload failure"
else
  fail "F2: applied fingerprint must not advance on reload failure"
fi
if try_connect "${F2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F2: plaintext still served after reload failure (no outage)"
else
  fail "F2: plaintext should still work after reload failure"
fi
docker exec "pgpooler-f2-prefer-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-reload 2>/dev/null || true
if wait_tls_state "pgpooler-f2-prefer-${SUFFIX}" "active" 30; then
  pass "F2: retry succeeds after fault removed"
else
  fail "F2: retry did not reach active"
fi
sleep 2
if tls_disable_connect "${F2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "F2: plaintext must be rejected after retry"
else
  pass "F2: plaintext rejected after retry"
fi
if tls_require_connect "${F2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F2: TLS works after retry"
else
  fail "F2: TLS should work after retry"
fi
docker rm -f "pgpooler-f2-prefer-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test F3: renewal reload failure keeps serving A, then retries to B ---"
TLS_F3A_DIR="${TLS_BASE}/f3a"
TLS_F3B_DIR="${TLS_BASE}/f3b"
TLS_F3_TREE="${TLS_BASE}/f3-tree"
F3_PORT=16446
F3_UI=18046
if make_test_cert "localhost" "${TLS_F3A_DIR}" && install_test_cert "${TLS_F3A_DIR}" "${TLS_F3_TREE}" "localhost"; then
  pass "F3 cert A installed"
else
  fail "F3 cert A setup failed"
fi
docker run -d --name "pgpooler-f3-renew-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${F3_PORT}:6432" -p "127.0.0.1:${F3_UI}:8080" \
  -v "${TLS_F3_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-f3-renew-${SUFFIX}" "active" 30; then
  pass "F3: boot reaches verified active state (cert A)"
else
  fail "F3: boot did not reach active state"
fi
if tls_require_connect "${F3_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F3: initial TLS works (cert A)"
else
  fail "F3: initial TLS failed"
fi
_F3_FP_A=$(tls_fingerprint "${F3_PORT}" "localhost")
_F3_APPLIED_A=$(read_applied_fp "pgpooler-f3-renew-${SUFFIX}")
_F3_SRC_A=$(src_fp_in_container "pgpooler-f3-renew-${SUFFIX}" "localhost")
if [ -n "${_F3_FP_A}" ] && [ -n "${_F3_APPLIED_A}" ] && [ "${_F3_APPLIED_A}" = "${_F3_SRC_A}" ]; then
  pass "F3: applied fingerprint tracks cert A"
else
  fail "F3: applied fingerprint should equal source A"
fi
_F3_ID_BEFORE=$(docker inspect "pgpooler-f3-renew-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
docker exec "pgpooler-f3-renew-${SUFFIX}" touch /run/pgbouncer/.fail-tls-reload 2>/dev/null || true
if make_test_cert "localhost" "${TLS_F3B_DIR}"; then
  pass "F3 cert B generated"
else
  fail "F3 cert B generation failed"
fi
install_test_cert "${TLS_F3B_DIR}" "${TLS_F3_TREE}" "localhost" || true
sleep 12
_F3_FP_STILL=$(tls_fingerprint "${F3_PORT}" "localhost")
if [ -n "${_F3_FP_STILL}" ] && [ "${_F3_FP_STILL}" = "${_F3_FP_A}" ]; then
  pass "F3: failed reload keeps serving cert A (no poisoning)"
else
  fail "F3: new connections must still receive cert A after reload failure"
fi
_F3_APPLIED_STILL=$(read_applied_fp "pgpooler-f3-renew-${SUFFIX}")
if [ "${_F3_APPLIED_STILL}" = "${_F3_APPLIED_A}" ]; then
  pass "F3: applied fingerprint remains A after reload failure"
else
  fail "F3: applied fingerprint must remain A after reload failure"
fi
if assert_state_now "pgpooler-f3-renew-${SUFFIX}" "active"; then
  pass "F3: state remains active after reload failure"
else
  fail "F3: state must remain active after reload failure"
fi
if tls_require_connect "${F3_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F3: TLS still works after reload failure"
else
  fail "F3: TLS should still work after reload failure"
fi
docker exec "pgpooler-f3-renew-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-reload 2>/dev/null || true
_F3_FP_B=""
_tries=0
while [ "${_tries}" -lt 30 ]; do
  sleep 1
  _F3_FP_B=$(tls_fingerprint "${F3_PORT}" "localhost")
  if [ -n "${_F3_FP_B}" ] && [ "${_F3_FP_B}" != "${_F3_FP_A}" ]; then
    break
  fi
  _tries=$((_tries + 1))
done
if [ -n "${_F3_FP_B}" ] && [ "${_F3_FP_B}" != "${_F3_FP_A}" ]; then
  pass "F3: retry serves renewed cert B"
else
  fail "F3: retry did not serve cert B"
fi
_F3_SRC_B=$(src_fp_in_container "pgpooler-f3-renew-${SUFFIX}" "localhost")
# The applied fingerprint is committed last by design (after the reload is
# confirmed and state/UI are refreshed), so poll briefly for it to land.
_F3_APPLIED_B=""
_tries=0
while [ "${_tries}" -lt 15 ]; do
  _F3_APPLIED_B=$(read_applied_fp "pgpooler-f3-renew-${SUFFIX}")
  if [ -n "${_F3_SRC_B}" ] && [ "${_F3_SRC_B}" = "${_F3_APPLIED_B}" ]; then
    break
  fi
  sleep 1
  _tries=$((_tries + 1))
done
if [ -n "${_F3_SRC_B}" ] && [ "${_F3_SRC_B}" = "${_F3_APPLIED_B}" ]; then
  pass "F3: applied fingerprint becomes B only after success"
else
  fail "F3: applied fingerprint should equal source B after success"
fi
_F3_ID_AFTER=$(docker inspect "pgpooler-f3-renew-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if [ -n "${_F3_ID_BEFORE}" ] && [ "${_F3_ID_BEFORE}" = "${_F3_ID_AFTER}" ]; then
  pass "F3: container did not restart across failure+retry"
else
  fail "F3: container must not restart"
fi
docker rm -f "pgpooler-f3-renew-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test F4: disabled with manual frontend TLS is rejected ---"
for _f4c in "sslmode" "certonly" "keyonly" "full"; do
  case "${_f4c}" in
    sslmode)
      _f4_extra="-e CLIENT_TLS_SSLMODE=require"
      ;;
    certonly)
      _f4_extra="-e CLIENT_TLS_CERT_FILE=/tmp/manual.crt"
      ;;
    keyonly)
      _f4_extra="-e CLIENT_TLS_KEY_FILE=/tmp/manual.key"
      ;;
    full)
      _f4_extra="-e CLIENT_TLS_SSLMODE=require -e CLIENT_TLS_CERT_FILE=/tmp/manual.crt -e CLIENT_TLS_KEY_FILE=/tmp/manual.key"
      ;;
  esac
  # shellcheck disable=SC2086
  if docker run --rm --name "pgpooler-f4-${_f4c}-${SUFFIX}" \
    -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
    -e PGPOOLER_SSL_MODE=disabled ${_f4_extra} \
    --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-f4-${_f4c}-${SUFFIX}.log 2>&1; then
    fail "F4 (${_f4c}): disabled+manual must fail startup"
  else
    if grep -qi "PGPOOLER_SSL_MODE=disabled" /tmp/pgpooler-f4-${_f4c}-${SUFFIX}.log 2>/dev/null; then
      pass "F4 (${_f4c}): disabled+manual rejected clearly"
    else
      fail "F4 (${_f4c}): rejected without clear disabled error"
    fi
  fi
done

log "--- Test F5: manual TLS under prefer without PUBLIC_HOST ---"
TLS_F5_DIR="${TLS_BASE}/f5"
TLS_F5_TREE="${TLS_BASE}/f5-tree"
F5_PORT=16447
F5_UI=18047
if make_test_cert "localhost" "${TLS_F5_DIR}"; then
  mkdir -p "${TLS_F5_TREE}" 2>/dev/null || true
  cp "${TLS_F5_DIR}/fullchain.pem" "${TLS_F5_TREE}/manual.crt" 2>/dev/null || true
  cp "${TLS_F5_DIR}/privkey.pem" "${TLS_F5_TREE}/manual.key" 2>/dev/null || true
  chmod 644 "${TLS_F5_TREE}/manual.crt" 2>/dev/null || true
  chmod 600 "${TLS_F5_TREE}/manual.key" 2>/dev/null || true
  pass "F5 manual cert staged"
else
  fail "F5 manual cert generation failed"
fi
docker run -d --name "pgpooler-f5-manual-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${F5_PORT}:6432" -p "127.0.0.1:${F5_UI}:8080" \
  -v "${TLS_F5_TREE}:/manual-tls:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  -e CLIENT_TLS_SSLMODE=require -e CLIENT_TLS_CERT_FILE=/manual-tls/manual.crt -e CLIENT_TLS_KEY_FILE=/manual-tls/manual.key \
  "${IMAGE}" >/dev/null
sleep 5
if tls_disable_connect "${F5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "F5: manual prefer must reject plaintext"
else
  pass "F5: manual prefer rejects plaintext"
fi
if tls_require_connect "${F5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "F5: manual prefer accepts TLS"
else
  fail "F5: manual prefer TLS failed"
fi
if fetch_ui "${F5_UI}" "/tmp/pgpooler-f5-ui-${SUFFIX}.html"; then
  if grep -q "Available and required (manual configuration)" "/tmp/pgpooler-f5-ui-${SUFFIX}.html" 2>/dev/null; then
    pass "F5: UI reports manual require accurately"
  else
    fail "F5: UI should report manual require"
  fi
  if grep -q "sslmode=verify-full" "/tmp/pgpooler-f5-ui-${SUFFIX}.html" 2>/dev/null; then
    pass "F5: UI recommends verify-full for manual require"
  else
    fail "F5: UI should recommend verify-full"
  fi
  rm -f "/tmp/pgpooler-f5-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "F5: UI fetch failed"
fi
docker rm -f "pgpooler-f5-manual-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test F6: partial manual TLS identity is rejected ---"
if docker run --rm --name "pgpooler-f6-certonly-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGPOOLER_SSL_MODE=prefer -e CLIENT_TLS_CERT_FILE=/tmp/manual.crt \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-f6-certonly-${SUFFIX}.log 2>&1; then
  fail "F6: cert without key must fail"
else
  if grep -qi "CLIENT_TLS_KEY_FILE" /tmp/pgpooler-f6-certonly-${SUFFIX}.log 2>/dev/null; then
    pass "F6: cert without key rejected clearly"
  else
    fail "F6: cert-without-key rejected without clear error"
  fi
fi
if docker run --rm --name "pgpooler-f6-keyonly-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGPOOLER_SSL_MODE=prefer -e CLIENT_TLS_KEY_FILE=/tmp/manual.key \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-f6-keyonly-${SUFFIX}.log 2>&1; then
  fail "F6: key without cert must fail"
else
  if grep -qi "CLIENT_TLS_CERT_FILE" /tmp/pgpooler-f6-keyonly-${SUFFIX}.log 2>/dev/null; then
    pass "F6: key without cert rejected clearly"
  else
    fail "F6: key-without-cert rejected without clear error"
  fi
fi
if docker run --rm --name "pgpooler-f6-requireonly-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGPOOLER_SSL_MODE=prefer -e CLIENT_TLS_SSLMODE=require \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-f6-requireonly-${SUFFIX}.log 2>&1; then
  fail "F6: require without pair must fail"
else
  if grep -qi "needs both" /tmp/pgpooler-f6-requireonly-${SUFFIX}.log 2>/dev/null; then
    pass "F6: require without pair rejected clearly"
  else
    fail "F6: require-without-pair rejected without clear error"
  fi
fi
if docker run --rm --name "pgpooler-f6-badmode-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGPOOLER_SSL_MODE=prefer -e CLIENT_TLS_SSLMODE=bogus \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-f6-badmode-${SUFFIX}.log 2>&1; then
  fail "F6: bogus sslmode must fail"
else
  if grep -qi "invalid CLIENT_TLS_SSLMODE" /tmp/pgpooler-f6-badmode-${SUFFIX}.log 2>/dev/null; then
    pass "F6: bogus sslmode rejected clearly"
  else
    fail "F6: bogus sslmode rejected without clear error"
  fi
fi

# ================================================== Endpoint-verified TLS (G)
# These tests prove the served certificate identity (not PID/TCP/config
# text) gates every `active` publication and every applied-fingerprint
# advance, plus restart-safe generated-config ownership.
# Helpers: served leaf via direct TLS handshake (tls_fingerprint), runtime
# leaf read inside the container in the identical openssl format.

# Leaf fingerprint of the installed runtime cert (openssl x509 format,
# directly comparable with tls_fingerprint output).
runtime_leaf_fp_now() {
  docker exec "$1" openssl x509 -in /run/pgbouncer/tls/fullchain.pem -noout -fingerprint -sha256 2>/dev/null | tr -d '\n' || printf ''
}
# Single-read TLS_STATE (may be empty).
read_tls_state_now() {
  docker exec "$1" cat /run/pgbouncer/pgpooler.state 2>/dev/null | grep '^TLS_STATE=' | cut -d= -f2- || printf ''
}
# Runtime fullchain content hash (proves restore/untouched identity).
runtime_file_hash_now() {
  docker exec "$1" sh -c 'sha256sum /run/pgbouncer/tls/fullchain.pem 2>/dev/null | awk "{print \$1}"' 2>/dev/null || printf ''
}

log "--- Test G1: required publishes prepared, never active, before endpoint verification ---"
TLS_G1_DIR="${TLS_BASE}/g1"
TLS_G1_TREE="${TLS_BASE}/g1-tree"
G1_PORT=16448
G1_UI=18048
mkdir -p "${TLS_G1_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_G1_DIR}"; then
  pass "G1 cert generated (not yet installed)"
else
  fail "G1 cert generation failed"
fi
docker run -d --name "pgpooler-g1-req-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G1_PORT}:6432" -p "127.0.0.1:${G1_UI}:8080" \
  -v "${TLS_G1_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=required -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-g1-req-${SUFFIX}" "waiting" 15; then
  pass "G1: initial waiting state"
else
  fail "G1: did not reach waiting state"
fi
# Fail endpoint verification: prepared must appear, active must not.
docker exec "pgpooler-g1-req-${SUFFIX}" touch /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
install_test_cert "${TLS_G1_DIR}" "${TLS_G1_TREE}" "localhost" || true
_G1_SAW_PREPARED=0
_G1_SAW_ACTIVE=0
_i=0
while [ "${_i}" -lt 40 ]; do
  _st=$(read_tls_state_now "pgpooler-g1-req-${SUFFIX}")
  case "${_st}" in
    active) _G1_SAW_ACTIVE=1; break ;;
    prepared) _G1_SAW_PREPARED=1 ;;
  esac
  sleep 1
  _i=$((_i + 1))
done
if [ "${_G1_SAW_ACTIVE}" = "0" ]; then
  pass "G1: active never published before endpoint verification"
else
  fail "G1: active must never appear before verification"
fi
if [ "${_G1_SAW_PREPARED}" = "1" ]; then
  pass "G1: prepared published while activation in flight"
else
  fail "G1: prepared state was never observed"
fi
_G1_APPLIED=$(read_applied_fp "pgpooler-g1-req-${SUFFIX}")
if [ -z "${_G1_APPLIED}" ]; then
  pass "G1: applied fingerprint empty until verification"
else
  fail "G1: applied fingerprint must not advance before verification"
fi
if fetch_ui "${G1_UI}" "/tmp/pgpooler-g1-ui-${SUFFIX}.html"; then
  if grep -q "Available and required" "/tmp/pgpooler-g1-ui-${SUFFIX}.html" 2>/dev/null; then
    fail "G1: UI must not claim active before verification"
  else
    pass "G1: UI never claims active before verification"
  fi
  rm -f "/tmp/pgpooler-g1-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "G1: UI fetch failed"
fi
_G1_PLAINTEXT_LEAK=0
_i=0
while [ "${_i}" -lt 6 ]; do
  if PGSSLMODE=disable PGCONNECT_TIMEOUT=3 PGPASSWORD="${FRONTEND_PASSWORD}" psql -X -q -h 127.0.0.1 -p "${G1_PORT}" -U "${FRONTEND_USER}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1; then
    _G1_PLAINTEXT_LEAK=1
    break
  fi
  sleep 3
  _i=$((_i + 1))
done
if [ "${_G1_PLAINTEXT_LEAK}" = "0" ]; then
  pass "G1: plaintext never succeeds while unverified (no window)"
else
  fail "G1: plaintext must never succeed while unverified"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pgpooler-g1-req-${SUFFIX}"; then
  pass "G1: container stable during failed verifications"
else
  fail "G1: container should keep running (UI + watcher)"
fi
# Heal: next activation verifies the endpoint and publishes active.
docker exec "pgpooler-g1-req-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
if wait_tls_state "pgpooler-g1-req-${SUFFIX}" "active" 40; then
  pass "G1: active published after verification succeeds"
else
  fail "G1: did not reach active after healing"
fi
_G1_SERVED=$(tls_fingerprint "${G1_PORT}" "localhost")
_G1_EXPECTED=$(runtime_leaf_fp_now "pgpooler-g1-req-${SUFFIX}")
if [ -n "${_G1_SERVED}" ] && [ "${_G1_SERVED}" = "${_G1_EXPECTED}" ]; then
  pass "G1: endpoint serves expected certificate at active"
else
  fail "G1: served certificate must match runtime leaf at active"
fi
if wait_tls_require "${G1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G1: TLS works after verified activation"
else
  fail "G1: TLS should work after verified activation"
fi
if tls_disable_connect "${G1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "G1: plaintext must be rejected"
else
  pass "G1: plaintext rejected (no window)"
fi
_G1_SRC=$(src_fp_in_container "pgpooler-g1-req-${SUFFIX}" "localhost")
_G1_APPLIED_AFTER=$(read_applied_fp "pgpooler-g1-req-${SUFFIX}")
if [ -n "${_G1_SRC}" ] && [ "${_G1_SRC}" = "${_G1_APPLIED_AFTER}" ]; then
  pass "G1: applied committed only after verification"
else
  fail "G1: applied should equal source after verification"
fi
docker rm -f "pgpooler-g1-req-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test G2: SIGHUP delivered but TLS rejected keeps plaintext, then heals ---"
TLS_G2_DIR="${TLS_BASE}/g2"
TLS_G2_TREE="${TLS_BASE}/g2-tree"
G2_PORT=16449
G2_UI=18049
mkdir -p "${TLS_G2_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_G2_DIR}"; then
  pass "G2 cert generated (not yet installed)"
else
  fail "G2 cert generation failed"
fi
docker run -d --name "pgpooler-g2-prefer-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G2_PORT}:6432" -p "127.0.0.1:${G2_UI}:8080" \
  -v "${TLS_G2_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${G2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G2: initial plaintext works"
else
  fail "G2: initial plaintext did not start"
fi
_G2_PID_BEFORE=$(docker exec "pgpooler-g2-prefer-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
# Inject a TLS setting PgBouncer rejects at RELOAD while staying alive.
docker exec "pgpooler-g2-prefer-${SUFFIX}" touch /run/pgbouncer/.fail-tls-protocols 2>/dev/null || true
install_test_cert "${TLS_G2_DIR}" "${TLS_G2_TREE}" "localhost" || true
# Poll: key generation plus a full rejected attempt can exceed fixed sleeps
# under load; the first delivered SIGHUP proves the attempt ran.
_G2_SIGHUP_SEEN=0
_i=0
while [ "${_i}" -lt 30 ]; do
  if docker logs "pgpooler-g2-prefer-${SUFFIX}" 2>&1 | grep -q "got SIGHUP"; then
    _G2_SIGHUP_SEEN=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_G2_SIGHUP_SEEN}" = "1" ]; then
  pass "G2: SIGHUP was actually delivered"
else
  fail "G2: SIGHUP delivery not observed in logs"
fi
_G2_PID_AFTER=$(docker exec "pgpooler-g2-prefer-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
if [ -n "${_G2_PID_BEFORE}" ] && [ "${_G2_PID_BEFORE}" = "${_G2_PID_AFTER}" ]; then
  pass "G2: same PgBouncer process survived (no restart)"
else
  fail "G2: PgBouncer process must stay alive across rejected reload"
fi
if docker exec "pgpooler-g2-prefer-${SUFFIX}" kill -0 "${_G2_PID_AFTER}" 2>/dev/null; then
  pass "G2: rejected reload keeps process alive"
else
  fail "G2: process should stay alive after rejected reload"
fi
if nc -z -w 3 127.0.0.1 "${G2_PORT}" >/dev/null 2>&1; then
  pass "G2: TCP stays open after rejected reload"
else
  fail "G2: TCP should stay open after rejected reload"
fi
_G2_SERVED=$(tls_fingerprint "${G2_PORT}" "localhost")
if [ -z "${_G2_SERVED}" ]; then
  pass "G2: endpoint serves no new certificate (change not applied)"
else
  fail "G2: endpoint must not serve the new certificate"
fi
if assert_state_now "pgpooler-g2-prefer-${SUFFIX}" "plaintext"; then
  pass "G2: state stays plaintext (not active)"
else
  fail "G2: state must remain plaintext after rejected reload"
fi
if fetch_ui "${G2_UI}" "/tmp/pgpooler-g2-ui-${SUFFIX}.html"; then
  if grep -q "Available and required" "/tmp/pgpooler-g2-ui-${SUFFIX}.html" 2>/dev/null; then
    fail "G2: UI must not claim active"
  else
    pass "G2: UI does not lie after rejected reload"
  fi
  rm -f "/tmp/pgpooler-g2-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "G2: UI fetch failed"
fi
_G2_APPLIED=$(read_applied_fp "pgpooler-g2-prefer-${SUFFIX}")
if [ -z "${_G2_APPLIED}" ]; then
  pass "G2: applied fingerprint not advanced on rejected reload"
else
  fail "G2: applied must not advance on rejected reload"
fi
if try_connect "${G2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G2: plaintext still served after rejected reload"
else
  fail "G2: plaintext should still work after rejected reload"
fi
# Heal: removing the flag rewrites a clean config; the retry verifies live.
# A generous window covers a fault-phase iteration still in flight.
docker exec "pgpooler-g2-prefer-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-protocols 2>/dev/null || true
if wait_tls_state "pgpooler-g2-prefer-${SUFFIX}" "active" 60; then
  pass "G2: retry succeeds after fault removed"
else
  fail "G2: retry did not reach active"
fi
sleep 2
_G2_SERVED_AFTER=$(tls_fingerprint "${G2_PORT}" "localhost")
_G2_EXPECTED_AFTER=$(runtime_leaf_fp_now "pgpooler-g2-prefer-${SUFFIX}")
if [ -n "${_G2_SERVED_AFTER}" ] && [ "${_G2_SERVED_AFTER}" = "${_G2_EXPECTED_AFTER}" ]; then
  pass "G2: endpoint serves expected certificate after heal"
else
  fail "G2: served certificate must match after heal"
fi
if tls_disable_connect "${G2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "G2: plaintext must be rejected after heal"
else
  pass "G2: plaintext rejected after heal"
fi
if tls_require_connect "${G2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G2: TLS works after heal"
else
  fail "G2: TLS should work after heal"
fi
docker rm -f "pgpooler-g2-prefer-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test G3: renewal reload rejected keeps serving A, then heals to B ---"
TLS_G3A_DIR="${TLS_BASE}/g3a"
TLS_G3B_DIR="${TLS_BASE}/g3b"
TLS_G3_TREE="${TLS_BASE}/g3-tree"
G3_PORT=16450
G3_UI=18050
if make_test_cert "localhost" "${TLS_G3A_DIR}" && install_test_cert "${TLS_G3A_DIR}" "${TLS_G3_TREE}" "localhost"; then
  pass "G3 cert A installed"
else
  fail "G3 cert A setup failed"
fi
docker run -d --name "pgpooler-g3-renew-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G3_PORT}:6432" -p "127.0.0.1:${G3_UI}:8080" \
  -v "${TLS_G3_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-g3-renew-${SUFFIX}" "active" 30; then
  pass "G3: boot reaches verified active (cert A)"
else
  fail "G3: boot did not reach active"
fi
_G3_FP_A=$(tls_fingerprint "${G3_PORT}" "localhost")
_G3_APPLIED_A=$(read_applied_fp "pgpooler-g3-renew-${SUFFIX}")
# Reference hash of the live A pair, captured before B exists anywhere.
_G3_RT_FILE_A=$(runtime_file_hash_now "pgpooler-g3-renew-${SUFFIX}")
if [ -n "${_G3_FP_A}" ] && [ -n "${_G3_APPLIED_A}" ] && [ -n "${_G3_RT_FILE_A}" ]; then
  pass "G3: cert A verified live with applied record"
else
  fail "G3: cert A should be live with applied record"
fi
_G3_PID_BEFORE=$(docker exec "pgpooler-g3-renew-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
# Install fault: the installed key becomes unloadable, so the renewal
# RELOAD is really rejected by PgBouncer while the process survives.
docker exec "pgpooler-g3-renew-${SUFFIX}" touch /run/pgbouncer/.fail-tls-install 2>/dev/null || true
if make_test_cert "localhost" "${TLS_G3B_DIR}"; then
  pass "G3 cert B generated"
else
  fail "G3 cert B generation failed"
fi
install_test_cert "${TLS_G3B_DIR}" "${TLS_G3_TREE}" "localhost" || true
# Poll: key generation plus a full rejected attempt can exceed fixed
# sleeps under load; the first delivered SIGHUP proves the attempt ran.
_G3_SIGHUP_SEEN=0
_i=0
while [ "${_i}" -lt 30 ]; do
  if docker logs "pgpooler-g3-renew-${SUFFIX}" 2>&1 | grep -q "got SIGHUP"; then
    _G3_SIGHUP_SEEN=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_G3_SIGHUP_SEEN}" = "1" ]; then
  pass "G3: SIGHUP was actually delivered for B"
else
  fail "G3: SIGHUP delivery not observed in logs"
fi
_G3_PID_AFTER=$(docker exec "pgpooler-g3-renew-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
if [ -n "${_G3_PID_BEFORE}" ] && [ "${_G3_PID_BEFORE}" = "${_G3_PID_AFTER}" ]; then
  pass "G3: same PgBouncer process survived rejected renewal"
else
  fail "G3: process must stay alive across rejected renewal"
fi
# Fault cycling alternates bad-B files with restored-A files; wait for a
# fully consistent restored snapshot instead of asserting single reads.
_G3_STEADY=0
_i=0
while [ "${_i}" -lt 30 ]; do
  _s=$(tls_fingerprint "${G3_PORT}" "localhost")
  _f=$(runtime_file_hash_now "pgpooler-g3-renew-${SUFFIX}")
  _a=$(read_applied_fp "pgpooler-g3-renew-${SUFFIX}")
  if [ -n "${_s}" ] && [ "${_s}" = "${_G3_FP_A}" ] && [ "${_f}" = "${_G3_RT_FILE_A}" ] && [ "${_a}" = "${_G3_APPLIED_A}" ]; then
    _G3_STEADY=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_G3_STEADY}" = "1" ]; then
  pass "G3: rejected renewal keeps serving A"
  pass "G3: runtime files restored to A consistently"
  pass "G3: applied remains A after rejected reload"
else
  fail "G3: endpoint must still serve A after rejected reload"
  fail "G3: runtime files should be restored to A"
  fail "G3: applied must remain A after rejected reload"
fi
if assert_state_now "pgpooler-g3-renew-${SUFFIX}" "active"; then
  pass "G3: state remains active after rejected reload"
else
  fail "G3: state must remain active after rejected reload"
fi
if tls_require_connect "${G3_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G3: TLS still works after rejected reload"
else
  fail "G3: TLS should still work after rejected reload"
fi
docker exec "pgpooler-g3-renew-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-install 2>/dev/null || true
_G3_FP_B=""
_tries=0
while [ "${_tries}" -lt 30 ]; do
  sleep 1
  _G3_FP_B=$(tls_fingerprint "${G3_PORT}" "localhost")
  if [ -n "${_G3_FP_B}" ] && [ "${_G3_FP_B}" != "${_G3_FP_A}" ]; then
    break
  fi
  _tries=$((_tries + 1))
done
if [ -n "${_G3_FP_B}" ] && [ "${_G3_FP_B}" != "${_G3_FP_A}" ]; then
  pass "G3: retry serves renewed cert B"
else
  fail "G3: retry did not serve cert B"
fi
_G3_RT_B=$(runtime_leaf_fp_now "pgpooler-g3-renew-${SUFFIX}")
# Both helpers keep raw `openssl x509 -fingerprint` format, so strict
# string equality proves the endpoint serves the runtime leaf.
if [ -n "${_G3_FP_B}" ] && [ -n "${_G3_RT_B}" ] && [ "${_G3_FP_B}" = "${_G3_RT_B}" ]; then
  pass "G3: served B matches runtime leaf"
else
  fail "G3: served B must match runtime leaf (got served='${_G3_FP_B}' runtime='${_G3_RT_B}')"
fi
_G3_SRC_B=$(src_fp_in_container "pgpooler-g3-renew-${SUFFIX}" "localhost")
_G3_APPLIED_B=""
_tries=0
while [ "${_tries}" -lt 15 ]; do
  _G3_APPLIED_B=$(read_applied_fp "pgpooler-g3-renew-${SUFFIX}")
  if [ -n "${_G3_SRC_B}" ] && [ "${_G3_SRC_B}" = "${_G3_APPLIED_B}" ]; then
    break
  fi
  sleep 1
  _tries=$((_tries + 1))
done
if [ -n "${_G3_SRC_B}" ] && [ "${_G3_SRC_B}" = "${_G3_APPLIED_B}" ]; then
  pass "G3: applied becomes B only after endpoint serves B"
else
  fail "G3: applied should equal source B after success"
fi
docker rm -f "pgpooler-g3-renew-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test G4: boot with cert goes prepared first, active only when verified ---"
TLS_G4_DIR="${TLS_BASE}/g4"
TLS_G4_TREE="${TLS_BASE}/g4-tree"
G4_PORT=16451
G4_UI=18051
if make_test_cert "localhost" "${TLS_G4_DIR}" && install_test_cert "${TLS_G4_DIR}" "${TLS_G4_TREE}" "localhost"; then
  pass "G4 cert installed before boot"
else
  fail "G4 cert setup failed"
fi
docker run -d --name "pgpooler-g4-boot-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G4_PORT}:6432" -p "127.0.0.1:${G4_UI}:8080" \
  -v "${TLS_G4_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=required -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
_G4_SAW_PREPARED=0
_G4_REACHED_ACTIVE=0
_G4_ACTIVE_CLEAN=0
_i=0
# State and applied fingerprint are snapshotted in a SINGLE docker exec:
# two separate reads could straddle the publish sequence (state written
# before the applied commit) and falsely observe prepared+applied-set.
while [ "${_i}" -lt 80 ]; do
  _snap=$(docker exec "pgpooler-g4-boot-${SUFFIX}" sh -c 'printf "STATE="; grep "^TLS_STATE=" /run/pgbouncer/pgpooler.state 2>/dev/null | cut -d= -f2-; printf "APPLIED="; tr -d "\n" < /run/pgbouncer/tls/.fingerprint 2>/dev/null; echo' 2>/dev/null || printf '')
  _st=$(printf '%s' "${_snap}" | grep '^STATE=' | cut -d= -f2-)
  _ap=$(printf '%s' "${_snap}" | grep '^APPLIED=' | cut -d= -f2-)
  case "${_st}" in
    prepared)
      _G4_SAW_PREPARED=1
      if [ -z "${_ap}" ]; then
        : # applied correctly empty while prepared
      else
        fail "G4: applied must be empty while prepared"
        break
      fi
      ;;
    active)
      _G4_REACHED_ACTIVE=1
      # At the first active observation the endpoint must already serve
      # the expected certificate: no unverified-active window allowed.
      _G4_SERVED_NOW=$(tls_fingerprint "${G4_PORT}" "localhost")
      _G4_EXPECTED_NOW=$(runtime_leaf_fp_now "pgpooler-g4-boot-${SUFFIX}")
      if [ -n "${_G4_SERVED_NOW}" ] && [ "${_G4_SERVED_NOW}" = "${_G4_EXPECTED_NOW}" ]; then
        _G4_ACTIVE_CLEAN=1
      else
        fail "G4: endpoint must serve expected cert at first active (got '${_G4_SERVED_NOW}')"
      fi
      break
      ;;
  esac
  sleep 1
  _i=$((_i + 1))
done
if [ "${_G4_SAW_PREPARED}" = "1" ]; then
  pass "G4: boot publishes prepared before active"
else
  fail "G4: prepared was never observed at boot"
fi
if [ "${_G4_REACHED_ACTIVE}" = "1" ]; then
  pass "G4: boot reaches active after verification"
else
  fail "G4: boot did not reach active"
fi
if [ "${_G4_ACTIVE_CLEAN}" = "1" ]; then
  pass "G4: first active already serves expected certificate"
else
  fail "G4: active must imply verified endpoint"
fi
if tls_disable_connect "${G4_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "G4: plaintext must be rejected"
else
  pass "G4: plaintext rejected (no window)"
fi
if tls_require_connect "${G4_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G4: first TLS connection succeeds"
else
  fail "G4: TLS should succeed"
fi
docker rm -f "pgpooler-g4-boot-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test G5: docker restart with generated automatic config ---"
TLS_G5_DIR="${TLS_BASE}/g5"
TLS_G5_TREE="${TLS_BASE}/g5-tree"
G5_PORT=16452
G5_UI=18052
if make_test_cert "localhost" "${TLS_G5_DIR}" && install_test_cert "${TLS_G5_DIR}" "${TLS_G5_TREE}" "localhost"; then
  pass "G5 cert installed"
else
  fail "G5 cert setup failed"
fi
docker run -d --name "pgpooler-g5-restart-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G5_PORT}:6432" -p "127.0.0.1:${G5_UI}:8080" \
  -v "${TLS_G5_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-g5-restart-${SUFFIX}" "active" 30; then
  pass "G5: initial active before restart"
else
  fail "G5: did not reach active before restart"
fi
if tls_require_connect "${G5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G5: TLS works before restart"
else
  fail "G5: TLS should work before restart"
fi
_G5_ID_BEFORE=$(docker inspect "pgpooler-g5-restart-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
# Anchor readiness on post-restart log lines: the state file survives
# `docker restart` on the container filesystem, so a stale pre-restart
# `active` must not count. A fresh boot regenerates the config and logs
# a fresh endpoint verification.
_G5_CFG_BEFORE=$(docker logs "pgpooler-g5-restart-${SUFFIX}" 2>&1 | grep -c "Creating pgbouncer config" || true)
_G5_OK_BEFORE=$(docker logs "pgpooler-g5-restart-${SUFFIX}" 2>&1 | grep -c "Frontend TLS verified active" || true)
docker restart "pgpooler-g5-restart-${SUFFIX}" >/dev/null 2>&1 || true
_G5_BOOTED=0
_tries=0
while [ "${_tries}" -lt 60 ]; do
  if [ "$(docker logs "pgpooler-g5-restart-${SUFFIX}" 2>&1 | grep -c "Creating pgbouncer config" || true)" -gt "${_G5_CFG_BEFORE}" ]; then
    _G5_BOOTED=1
    break
  fi
  sleep 1
  _tries=$((_tries + 1))
done
if [ "${_G5_BOOTED}" = "1" ]; then
  pass "G5: rebooted and regenerated config (marker accepted)"
else
  fail "G5: container did not reboot with config regeneration"
fi
_G5_VERIFIED=0
_tries=0
while [ "${_tries}" -lt 60 ]; do
  if [ "$(docker logs "pgpooler-g5-restart-${SUFFIX}" 2>&1 | grep -c "Frontend TLS verified active" || true)" -gt "${_G5_OK_BEFORE}" ]; then
    _G5_VERIFIED=1
    break
  fi
  sleep 1
  _tries=$((_tries + 1))
done
if [ "${_G5_VERIFIED}" = "1" ]; then
  pass "G5: fresh endpoint verification after restart (not stale state)"
else
  fail "G5: no fresh endpoint verification after restart"
fi
if wait_tls_state "pgpooler-g5-restart-${SUFFIX}" "active" 30; then
  pass "G5: same container returns to active after restart"
else
  fail "G5: container did not return to active after restart"
  docker logs "pgpooler-g5-restart-${SUFFIX}" 2>&1 | tail -20 || true
fi
_G5_ID_AFTER=$(docker inspect "pgpooler-g5-restart-${SUFFIX}" --format '{{.Id}}' 2>/dev/null || printf '')
if [ -n "${_G5_ID_BEFORE}" ] && [ "${_G5_ID_BEFORE}" = "${_G5_ID_AFTER}" ]; then
  pass "G5: restart kept the same container"
else
  fail "G5: expected the same container after restart"
fi
if docker logs "pgpooler-g5-restart-${SUFFIX}" 2>&1 | grep -q "custom mounted config"; then
  fail "G5: own generated config misclassified as custom"
else
  pass "G5: no custom-config false positive after restart"
fi
if tls_require_connect "${G5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G5: TLS works after restart"
else
  fail "G5: TLS should work after restart"
fi
if tls_disable_connect "${G5_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "G5: plaintext must stay rejected after restart"
else
  pass "G5: plaintext rejected after restart"
fi
_G5_SERVED_AFTER=$(tls_fingerprint "${G5_PORT}" "localhost")
_G5_EXPECTED_AFTER=$(runtime_leaf_fp_now "pgpooler-g5-restart-${SUFFIX}")
if [ -n "${_G5_SERVED_AFTER}" ] && [ "${_G5_SERVED_AFTER}" = "${_G5_EXPECTED_AFTER}" ]; then
  pass "G5: expected certificate still served after restart"
else
  fail "G5: served certificate must match after restart"
fi
if fetch_ui "${G5_UI}" "/tmp/pgpooler-g5-ui-${SUFFIX}.html"; then
  if grep -q "Available and required" "/tmp/pgpooler-g5-ui-${SUFFIX}.html" 2>/dev/null; then
    pass "G5: UI correct after restart"
  else
    fail "G5: UI should report active after restart"
  fi
  rm -f "/tmp/pgpooler-g5-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "G5: UI fetch failed after restart"
fi
docker rm -f "pgpooler-g5-restart-${SUFFIX}" >/dev/null 2>&1 || true
# Restart variant without certificate: plaintext must recover cleanly.
G5B_PORT=16453
G5B_UI=18053
docker run -d --name "pgpooler-g5b-restart-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G5B_PORT}:6432" -p "127.0.0.1:${G5B_UI}:8080" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${G5B_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G5b: plaintext works before restart"
else
  fail "G5b: plaintext did not start"
fi
docker restart "pgpooler-g5b-restart-${SUFFIX}" >/dev/null 2>&1 || true
if wait_pgbouncer "${G5B_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G5b: plaintext recovers after restart"
else
  fail "G5b: plaintext should recover after restart"
  docker logs "pgpooler-g5b-restart-${SUFFIX}" 2>&1 | tail -10 || true
fi
if assert_state_now "pgpooler-g5b-restart-${SUFFIX}" "plaintext"; then
  pass "G5b: state plaintext after restart"
else
  fail "G5b: state should be plaintext after restart"
fi
docker rm -f "pgpooler-g5b-restart-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test G6: genuine custom config still detected, marker config accepted ---"
TLS_G6_DIR="${TLS_BASE}/g6"
TLS_G6_TREE="${TLS_BASE}/g6-tree"
if make_test_cert "localhost" "${TLS_G6_DIR}" && install_test_cert "${TLS_G6_DIR}" "${TLS_G6_TREE}" "localhost"; then
  pass "G6 cert staged"
else
  fail "G6 cert setup failed"
fi
printf '[pgbouncer]\nlisten_port = 6432\n' > "${TLS_BASE}/g6-custom.ini" 2>/dev/null || true
if docker run --rm --name "pgpooler-g6-custom-${SUFFIX}" \
  -v "${TLS_G6_TREE}:/caprover-letsencrypt:ro" \
  -v "${TLS_BASE}/g6-custom.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-g6-custom-${SUFFIX}.log 2>&1; then
  fail "G6: genuine custom config with automatic TLS must fail"
else
  if grep -q "custom mounted config" /tmp/pgpooler-g6-custom-${SUFFIX}.log 2>/dev/null; then
    pass "G6: genuine custom config still detected clearly"
  else
    fail "G6: custom config rejected without clear error"
  fi
fi
mkdir -p "${TLS_BASE}/g6-marker-dir" 2>/dev/null || true
printf '# Generated by PgPooler-Uma - do not edit inside the container\n[pgbouncer]\nlisten_port = 6432\n' > "${TLS_BASE}/g6-marker-dir/pgbouncer.ini" 2>/dev/null || true
if docker run --rm --name "pgpooler-g6-marker-${SUFFIX}" \
  -v "${TLS_G6_TREE}:/caprover-letsencrypt:ro" \
  -v "${TLS_BASE}/g6-marker-dir:/etc/pgbouncer" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "^# Generated by PgPooler-Uma" /etc/pgbouncer/pgbouncer.ini && grep -q "client_tls_sslmode = require" /etc/pgbouncer/pgbouncer.ini && grep -q "^testdb" /etc/pgbouncer/pgbouncer.ini && echo G6_MARKER_OK' \
  >/tmp/pgpooler-g6-marker-${SUFFIX}.log 2>&1; then
  if grep -q "G6_MARKER_OK" /tmp/pgpooler-g6-marker-${SUFFIX}.log 2>/dev/null; then
    pass "G6: marker-owned config regenerated with automatic TLS"
  else
    fail "G6: marker-owned config should regenerate automatic TLS"
  fi
else
  fail "G6: marker-owned config run failed"
fi
# A marker-owned single-file read-only mount cannot be regenerated in
# place; automatic TLS must fail clearly rather than misbehave.
printf '# Generated by PgPooler-Uma - do not edit inside the container\n[pgbouncer]\nlisten_port = 6432\n' > "${TLS_BASE}/g6-marker-ro.ini" 2>/dev/null || true
if docker run --rm --name "pgpooler-g6-markerro-${SUFFIX}" \
  -v "${TLS_G6_TREE}:/caprover-letsencrypt:ro" \
  -v "${TLS_BASE}/g6-marker-ro.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-g6-markerro-${SUFFIX}.log 2>&1; then
  fail "G6: read-only marker mount with automatic TLS must fail"
else
  if grep -qi "custom mounted config\|cannot.*regenerat" /tmp/pgpooler-g6-markerro-${SUFFIX}.log 2>/dev/null; then
    pass "G6: read-only marker mount fails clearly"
  else
    fail "G6: read-only marker mount rejected without clear error"
  fi
fi

# Wait until a container stops (fail-closed termination asserts).
wait_container_stopped() {
  _wcs_c="$1"; _wcs_timeout="${2:-60}"; _wcs_t=0
  while [ "${_wcs_t}" -lt "${_wcs_timeout}" ]; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${_wcs_c}" 2>/dev/null || printf 'false')" = "false" ]; then
      return 0
    fi
    sleep 1
    _wcs_t=$((_wcs_t + 1))
  done
  return 1
}
# Count PgBouncer SIGHUP deliveries observed in container logs.
sighup_count() {
  docker logs "$1" 2>&1 | grep -c "got SIGHUP" || true
}

log "--- Test G7: renewal backup failure aborts before touching active pair ---"
TLS_G7A_DIR="${TLS_BASE}/g7a"
TLS_G7B_DIR="${TLS_BASE}/g7b"
TLS_G7_TREE="${TLS_BASE}/g7-tree"
G7_PORT=16454
G7_UI=18054
if make_test_cert "localhost" "${TLS_G7A_DIR}" && install_test_cert "${TLS_G7A_DIR}" "${TLS_G7_TREE}" "localhost"; then
  pass "G7 cert A installed"
else
  fail "G7 cert A setup failed"
fi
docker run -d --name "pgpooler-g7-renew-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${G7_PORT}:6432" -p "127.0.0.1:${G7_UI}:8080" \
  -v "${TLS_G7_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-g7-renew-${SUFFIX}" "active" 30; then
  pass "G7: boot reaches verified active (cert A)"
else
  fail "G7: boot did not reach active"
fi
_G7_RT_A=$(runtime_file_hash_now "pgpooler-g7-renew-${SUFFIX}")
_G7_FP_A=$(tls_fingerprint "${G7_PORT}" "localhost")
_G7_APPLIED_A=$(read_applied_fp "pgpooler-g7-renew-${SUFFIX}")
if [ -n "${_G7_RT_A}" ] && [ -n "${_G7_FP_A}" ] && [ -n "${_G7_APPLIED_A}" ]; then
  pass "G7: cert A live with recorded state"
else
  fail "G7: cert A should be live with recorded state"
fi
docker exec "pgpooler-g7-renew-${SUFFIX}" touch /run/pgbouncer/.fail-tls-backup 2>/dev/null || true
if make_test_cert "localhost" "${TLS_G7B_DIR}"; then
  pass "G7 cert B generated"
else
  fail "G7 cert B generation failed"
fi
install_test_cert "${TLS_G7B_DIR}" "${TLS_G7_TREE}" "localhost" || true
sleep 13
if [ "$(runtime_file_hash_now "pgpooler-g7-renew-${SUFFIX}")" = "${_G7_RT_A}" ]; then
  pass "G7: backup failure leaves active pair untouched"
else
  fail "G7: runtime files must not change when backup fails"
fi
_G7_FP_STILL=$(tls_fingerprint "${G7_PORT}" "localhost")
if [ -n "${_G7_FP_STILL}" ] && [ "${_G7_FP_STILL}" = "${_G7_FP_A}" ]; then
  pass "G7: endpoint still serves A after backup failure"
else
  fail "G7: endpoint must still serve A after backup failure"
fi
if [ "$(read_applied_fp "pgpooler-g7-renew-${SUFFIX}")" = "${_G7_APPLIED_A}" ]; then
  pass "G7: applied remains A after backup failure"
else
  fail "G7: applied must remain A after backup failure"
fi
if assert_state_now "pgpooler-g7-renew-${SUFFIX}" "active"; then
  pass "G7: state remains active after backup failure"
else
  fail "G7: state must remain active after backup failure"
fi
if tls_require_connect "${G7_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "G7: TLS still works after backup failure"
else
  fail "G7: TLS should still work after backup failure"
fi
docker exec "pgpooler-g7-renew-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-backup 2>/dev/null || true
_G7_FP_B=""
_tries=0
while [ "${_tries}" -lt 30 ]; do
  sleep 1
  _G7_FP_B=$(tls_fingerprint "${G7_PORT}" "localhost")
  if [ -n "${_G7_FP_B}" ] && [ "${_G7_FP_B}" != "${_G7_FP_A}" ]; then
    break
  fi
  _tries=$((_tries + 1))
done
if [ -n "${_G7_FP_B}" ] && [ "${_G7_FP_B}" != "${_G7_FP_A}" ]; then
  pass "G7: retry serves renewed cert B"
else
  fail "G7: retry did not serve cert B"
fi
_G7_SRC_B=$(src_fp_in_container "pgpooler-g7-renew-${SUFFIX}" "localhost")
_G7_APPLIED_B=""
_tries=0
while [ "${_tries}" -lt 15 ]; do
  _G7_APPLIED_B=$(read_applied_fp "pgpooler-g7-renew-${SUFFIX}")
  if [ -n "${_G7_SRC_B}" ] && [ "${_G7_SRC_B}" = "${_G7_APPLIED_B}" ]; then
    break
  fi
  sleep 1
  _tries=$((_tries + 1))
done
if [ -n "${_G7_SRC_B}" ] && [ "${_G7_SRC_B}" = "${_G7_APPLIED_B}" ]; then
  pass "G7: applied becomes B only after endpoint serves B"
else
  fail "G7: applied should equal source B after success"
fi
docker rm -f "pgpooler-g7-renew-${SUFFIX}" >/dev/null 2>&1 || true

# ================================================== Ambiguous reload (H)
# SIGHUP-delivered-but-unverified handling. Forward reload and rollback
# reload use separate fault flags so each half is independently
# deterministic:
#   .fail-tls-reload   -> forward SIGHUP never sent (old state authoritative)
#   .fail-tls-rollback -> rollback SIGHUP never sent (rollback unconfirmable)
#   endpoint-verification fault -> probes report failure while real
#     reloads still apply (the ambiguous case under test)

log "--- Test H1: prefer reload succeeds, probe falsely fails, rollback confirmed ---"
TLS_H1_DIR="${TLS_BASE}/h1"
TLS_H1_TREE="${TLS_BASE}/h1-tree"
H1_PORT=16457
H1_UI=18057
mkdir -p "${TLS_H1_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_H1_DIR}"; then
  pass "H1 cert generated (not yet installed)"
else
  fail "H1 cert generation failed"
fi
docker run -d --name "pgpooler-h1-prefer-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${H1_PORT}:6432" -p "127.0.0.1:${H1_UI}:8080" \
  -v "${TLS_H1_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${H1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "H1: initial plaintext works"
else
  fail "H1: initial plaintext did not start"
fi
_H1_PID_BEFORE=$(docker exec "pgpooler-h1-prefer-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
# Fault only the observer: the real SIGHUP still applies require, while
# every endpoint probe reports failure (the ambiguous case).
docker exec "pgpooler-h1-prefer-${SUFFIX}" touch /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
install_test_cert "${TLS_H1_DIR}" "${TLS_H1_TREE}" "localhost" || true
# Under a persistent probe fault the service cycles require-live (while
# probes retry) back to verified plaintext (after rollback), so every
# phase-dependent assertion polls for a steady observation.
_H1_SIGHUPS=0
_i=0
while [ "${_i}" -lt 30 ]; do
  _H1_SIGHUPS=$(sighup_count "pgpooler-h1-prefer-${SUFFIX}")
  if [ "${_H1_SIGHUPS}" -ge 2 ]; then
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H1_SIGHUPS}" -ge 2 ]; then
  pass "H1: rollback reload explicitly sent (SIGHUPs=${_H1_SIGHUPS})"
else
  fail "H1: expected forward plus rollback SIGHUPs (got ${_H1_SIGHUPS})"
fi
_H1_EMPTY=0
_i=0
while [ "${_i}" -lt 30 ]; do
  if [ -z "$(tls_fingerprint "${H1_PORT}" "localhost")" ]; then
    _H1_EMPTY=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H1_EMPTY}" = "1" ]; then
  pass "H1: candidate TLS state not left running"
else
  fail "H1: endpoint must not serve the candidate after rollback"
fi
if assert_state_now "pgpooler-h1-prefer-${SUFFIX}" "plaintext"; then
  pass "H1: state stays plaintext until rollback confirmed"
else
  fail "H1: state must remain plaintext"
fi
if fetch_ui "${H1_UI}" "/tmp/pgpooler-h1-ui-${SUFFIX}.html"; then
  if grep -q "Available and required" "/tmp/pgpooler-h1-ui-${SUFFIX}.html" 2>/dev/null; then
    fail "H1: UI must not claim active"
  else
    pass "H1: UI does not claim active"
  fi
  rm -f "/tmp/pgpooler-h1-ui-${SUFFIX}.html" 2>/dev/null || true
else
  fail "H1: UI fetch failed"
fi
_H1_APPLIED=$(read_applied_fp "pgpooler-h1-prefer-${SUFFIX}")
if [ -z "${_H1_APPLIED}" ]; then
  pass "H1: applied fingerprint not advanced on ambiguity"
else
  fail "H1: applied must not advance without verification"
fi
_H1_RB_LOGGED=0
_i=0
while [ "${_i}" -lt 15 ]; do
  if docker logs "pgpooler-h1-prefer-${SUFFIX}" 2>&1 | grep -q "Frontend TLS rollback to plaintext verified"; then
    _H1_RB_LOGGED=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H1_RB_LOGGED}" = "1" ]; then
  pass "H1: rollback confirmation logged"
else
  fail "H1: rollback confirmation should be logged"
fi
# Plaintext must REALLY work after rollback: poll for a live session
# because fault cycling alternates require-live and plaintext phases.
_H1_PLAIN_OK=0
_i=0
while [ "${_i}" -lt 30 ]; do
  if try_connect "${H1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
    _H1_PLAIN_OK=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H1_PLAIN_OK}" = "1" ]; then
  pass "H1: plaintext really works after confirmed rollback"
else
  fail "H1: plaintext must work after confirmed rollback"
fi
_H1_PID_AFTER=$(docker exec "pgpooler-h1-prefer-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
if [ -n "${_H1_PID_BEFORE}" ] && [ "${_H1_PID_BEFORE}" = "${_H1_PID_AFTER}" ]; then
  pass "H1: container did not restart across rollback"
else
  fail "H1: container must not restart on confirmed rollback"
fi
# Heal: the watcher retries the candidate and verifies it live.
docker exec "pgpooler-h1-prefer-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
if wait_tls_state "pgpooler-h1-prefer-${SUFFIX}" "active" 40; then
  pass "H1: retry succeeds after fault removed"
else
  fail "H1: retry did not reach active"
fi
sleep 2
_H1_SERVED_AFTER=$(tls_fingerprint "${H1_PORT}" "localhost")
_H1_EXPECTED_AFTER=$(runtime_leaf_fp_now "pgpooler-h1-prefer-${SUFFIX}")
if [ -n "${_H1_SERVED_AFTER}" ] && [ "${_H1_SERVED_AFTER}" = "${_H1_EXPECTED_AFTER}" ]; then
  pass "H1: endpoint serves expected certificate after heal"
else
  fail "H1: served certificate must match after heal"
fi
if tls_disable_connect "${H1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  fail "H1: plaintext must be rejected after heal"
else
  pass "H1: plaintext rejected after heal"
fi
if tls_require_connect "${H1_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "H1: TLS works after heal"
else
  fail "H1: TLS should work after heal"
fi
docker rm -f "pgpooler-h1-prefer-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test H2: renewal B applies, probe falsely fails, rollback A confirmed ---"
TLS_H2A_DIR="${TLS_BASE}/h2a"
TLS_H2B_DIR="${TLS_BASE}/h2b"
TLS_H2_TREE="${TLS_BASE}/h2-tree"
H2_PORT=16458
H2_UI=18058
if make_test_cert "localhost" "${TLS_H2A_DIR}" && install_test_cert "${TLS_H2A_DIR}" "${TLS_H2_TREE}" "localhost"; then
  pass "H2 cert A installed"
else
  fail "H2 cert A setup failed"
fi
docker run -d --name "pgpooler-h2-renew-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${H2_PORT}:6432" -p "127.0.0.1:${H2_UI}:8080" \
  -v "${TLS_H2_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-h2-renew-${SUFFIX}" "active" 30; then
  pass "H2: boot reaches verified active (cert A)"
else
  fail "H2: boot did not reach active"
fi
_H2_FP_A=$(tls_fingerprint "${H2_PORT}" "localhost")
_H2_APPLIED_A=$(read_applied_fp "pgpooler-h2-renew-${SUFFIX}")
_H2_RT_FILE_A=$(runtime_file_hash_now "pgpooler-h2-renew-${SUFFIX}")
if [ -n "${_H2_FP_A}" ] && [ -n "${_H2_APPLIED_A}" ] && [ -n "${_H2_RT_FILE_A}" ]; then
  pass "H2: cert A verified live with recorded state"
else
  fail "H2: cert A should be live with recorded state"
fi
_H2_PID_BEFORE=$(docker exec "pgpooler-h2-renew-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
docker exec "pgpooler-h2-renew-${SUFFIX}" touch /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
if make_test_cert "localhost" "${TLS_H2B_DIR}"; then
  pass "H2 cert B generated"
else
  fail "H2 cert B generation failed"
fi
install_test_cert "${TLS_H2B_DIR}" "${TLS_H2_TREE}" "localhost" || true
# Fault cycling alternates B-live and restored-A phases; wait for a
# fully consistent restored snapshot instead of asserting single reads.
_H2_SIGHUPS=0
_i=0
while [ "${_i}" -lt 30 ]; do
  _H2_SIGHUPS=$(sighup_count "pgpooler-h2-renew-${SUFFIX}")
  if [ "${_H2_SIGHUPS}" -ge 2 ]; then
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H2_SIGHUPS}" -ge 2 ]; then
  pass "H2: rollback reload explicitly sent (SIGHUPs=${_H2_SIGHUPS})"
else
  fail "H2: expected forward plus rollback SIGHUPs (got ${_H2_SIGHUPS})"
fi
_H2_STEADY=0
_i=0
while [ "${_i}" -lt 30 ]; do
  _s=$(tls_fingerprint "${H2_PORT}" "localhost")
  _f=$(runtime_file_hash_now "pgpooler-h2-renew-${SUFFIX}")
  _a=$(read_applied_fp "pgpooler-h2-renew-${SUFFIX}")
  _st=$(read_tls_state_now "pgpooler-h2-renew-${SUFFIX}")
  if [ -n "${_s}" ] && [ "${_s}" = "${_H2_FP_A}" ] && [ "${_f}" = "${_H2_RT_FILE_A}" ] && [ "${_a}" = "${_H2_APPLIED_A}" ] && [ "${_st}" = "active" ]; then
    _H2_STEADY=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H2_STEADY}" = "1" ]; then
  pass "H2: endpoint serves A again after confirmed rollback"
  pass "H2: runtime files are A after rollback"
  pass "H2: applied remains A after rollback"
  pass "H2: state remains active after confirmed rollback"
else
  fail "H2: endpoint must serve A after confirmed rollback"
  fail "H2: runtime files must be A after rollback"
  fail "H2: applied must remain A after rollback"
  fail "H2: state must remain active after confirmed rollback"
fi
_H2_RB_LOGGED=0
_i=0
while [ "${_i}" -lt 15 ]; do
  if docker logs "pgpooler-h2-renew-${SUFFIX}" 2>&1 | grep -q "Previous TLS certificate verified after rollback"; then
    _H2_RB_LOGGED=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H2_RB_LOGGED}" = "1" ]; then
  pass "H2: rollback confirmation logged"
else
  fail "H2: rollback confirmation should be logged"
fi
if tls_require_connect "${H2_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "H2: TLS still works after confirmed rollback"
else
  fail "H2: TLS should still work after confirmed rollback"
fi
_H2_PID_AFTER=$(docker exec "pgpooler-h2-renew-${SUFFIX}" cat /run/pgbouncer/pgbouncer.pid 2>/dev/null || printf '')
if [ -n "${_H2_PID_BEFORE}" ] && [ "${_H2_PID_BEFORE}" = "${_H2_PID_AFTER}" ]; then
  pass "H2: same process survived rollback"
else
  fail "H2: process must stay alive across confirmed rollback"
fi
docker exec "pgpooler-h2-renew-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
_H2_FP_B=""
_tries=0
while [ "${_tries}" -lt 30 ]; do
  sleep 1
  _H2_FP_B=$(tls_fingerprint "${H2_PORT}" "localhost")
  if [ -n "${_H2_FP_B}" ] && [ "${_H2_FP_B}" != "${_H2_FP_A}" ]; then
    break
  fi
  _tries=$((_tries + 1))
done
if [ -n "${_H2_FP_B}" ] && [ "${_H2_FP_B}" != "${_H2_FP_A}" ]; then
  pass "H2: retry serves renewed cert B"
else
  fail "H2: retry did not serve cert B"
fi
_H2_SRC_B=$(src_fp_in_container "pgpooler-h2-renew-${SUFFIX}" "localhost")
_H2_APPLIED_B=""
_tries=0
while [ "${_tries}" -lt 15 ]; do
  _H2_APPLIED_B=$(read_applied_fp "pgpooler-h2-renew-${SUFFIX}")
  if [ -n "${_H2_SRC_B}" ] && [ "${_H2_SRC_B}" = "${_H2_APPLIED_B}" ]; then
    break
  fi
  sleep 1
  _tries=$((_tries + 1))
done
if [ -n "${_H2_SRC_B}" ] && [ "${_H2_SRC_B}" = "${_H2_APPLIED_B}" ]; then
  pass "H2: applied becomes B only after endpoint serves B"
else
  fail "H2: applied should equal source B after success"
fi
docker rm -f "pgpooler-h2-renew-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test H3: unverifiable rollback stops the container, never lies ---"
# Prefer variant: endpoint fault plus rollback reload fault. The forward
# reload really applies require, the probe falsely fails, and the
# rollback reload cannot be delivered, so plaintext can never be
# confirmed and the container must stop instead of claiming it.
TLS_H3P_DIR="${TLS_BASE}/h3p"
TLS_H3P_TREE="${TLS_BASE}/h3p-tree"
H3P_PORT=16459
H3P_UI=18059
mkdir -p "${TLS_H3P_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_H3P_DIR}"; then
  pass "H3p cert generated (not yet installed)"
else
  fail "H3p cert generation failed"
fi
docker run -d --name "pgpooler-h3-prefer-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${H3P_PORT}:6432" -p "127.0.0.1:${H3P_UI}:8080" \
  -v "${TLS_H3P_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${H3P_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "H3p: initial plaintext works"
else
  fail "H3p: initial plaintext did not start"
fi
docker exec "pgpooler-h3-prefer-${SUFFIX}" touch /run/pgbouncer/.fail-tls-endpoint-verification /run/pgbouncer/.fail-tls-rollback 2>/dev/null || true
install_test_cert "${TLS_H3P_DIR}" "${TLS_H3P_TREE}" "localhost" || true
_H3P_SAW_ACTIVE=0
_i=0
while [ "${_i}" -lt 45 ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "pgpooler-h3-prefer-${SUFFIX}" 2>/dev/null || printf 'false')" = "false" ]; then
    break
  fi
  _st=$(read_tls_state_now "pgpooler-h3-prefer-${SUFFIX}")
  if [ "${_st}" = "active" ]; then
    _H3P_SAW_ACTIVE=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H3P_SAW_ACTIVE}" = "0" ]; then
  pass "H3p: active never published on unverifiable rollback"
else
  fail "H3p: active must never appear without verification"
fi
if wait_container_stopped "pgpooler-h3-prefer-${SUFFIX}" 60; then
  pass "H3p: container stopped instead of false plaintext"
else
  fail "H3p: container should stop when rollback is unconfirmable"
fi
if docker logs "pgpooler-h3-prefer-${SUFFIX}" 2>&1 | grep -q "got SIGHUP"; then
  pass "H3p: forward SIGHUP was delivered before rollback failure"
else
  fail "H3p: forward SIGHUP delivery not observed"
fi
if docker logs "pgpooler-h3-prefer-${SUFFIX}" 2>&1 | grep -q "rollback could not be verified; stopping container"; then
  pass "H3p: unverifiable rollback logged"
else
  fail "H3p: unverifiable rollback should be logged"
fi
docker cp "pgpooler-h3-prefer-${SUFFIX}:/run/pgbouncer/pgpooler.state" "/tmp/pgpooler-h3p-state-${SUFFIX}" 2>/dev/null || true
if grep -q "^TLS_STATE=plaintext" "/tmp/pgpooler-h3p-state-${SUFFIX}" 2>/dev/null; then
  pass "H3p: last published state was truthful plaintext"
else
  fail "H3p: last state must not claim active"
fi
if docker cp "pgpooler-h3-prefer-${SUFFIX}:/run/pgbouncer/tls/.fingerprint" "/tmp/pgpooler-h3p-fp-${SUFFIX}" 2>/dev/null; then
  if [ -s "/tmp/pgpooler-h3p-fp-${SUFFIX}" ]; then
    fail "H3p: applied fingerprint must stay empty"
  else
    pass "H3p: applied fingerprint empty"
  fi
else
  pass "H3p: applied fingerprint empty"
fi
docker cp "pgpooler-h3-prefer-${SUFFIX}:/var/www/index.html" "/tmp/pgpooler-h3p-ui-${SUFFIX}.html" 2>/dev/null || true
if grep -q "Available and required" "/tmp/pgpooler-h3p-ui-${SUFFIX}.html" 2>/dev/null; then
  fail "H3p: UI must never claim active"
else
  pass "H3p: UI never claimed active"
fi
rm -f "/tmp/pgpooler-h3p-state-${SUFFIX}" "/tmp/pgpooler-h3p-fp-${SUFFIX}" "/tmp/pgpooler-h3p-ui-${SUFFIX}.html" 2>/dev/null || true
if [ "$(docker inspect -f '{{.State.Running}}' "pgpooler-h3-prefer-${SUFFIX}" 2>/dev/null || printf 'false')" = "false" ]; then
  pass "H3p: container stays stopped (no restart loop from test)"
else
  fail "H3p: container should remain stopped"
fi
docker rm -f "pgpooler-h3-prefer-${SUFFIX}" >/dev/null 2>&1 || true
# Renewal variant: B really applies, probe falsely fails, rollback
# reload fails, so A cannot be re-confirmed and the container stops
# with applied still A and the backup retained.
TLS_H3RA_DIR="${TLS_BASE}/h3ra"
TLS_H3RB_DIR="${TLS_BASE}/h3rb"
TLS_H3R_TREE="${TLS_BASE}/h3r-tree"
H3R_PORT=16460
H3R_UI=18060
if make_test_cert "localhost" "${TLS_H3RA_DIR}" && install_test_cert "${TLS_H3RA_DIR}" "${TLS_H3R_TREE}" "localhost"; then
  pass "H3r cert A installed"
else
  fail "H3r cert A setup failed"
fi
docker run -d --name "pgpooler-h3-renew-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${H3R_PORT}:6432" -p "127.0.0.1:${H3R_UI}:8080" \
  -v "${TLS_H3R_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_tls_state "pgpooler-h3-renew-${SUFFIX}" "active" 30; then
  pass "H3r: boot reaches verified active (cert A)"
else
  fail "H3r: boot did not reach active"
fi
_H3R_APPLIED_A=$(read_applied_fp "pgpooler-h3-renew-${SUFFIX}")
if [ -n "${_H3R_APPLIED_A}" ]; then
  pass "H3r: applied A recorded"
else
  fail "H3r: applied A should be recorded"
fi
docker exec "pgpooler-h3-renew-${SUFFIX}" touch /run/pgbouncer/.fail-tls-endpoint-verification /run/pgbouncer/.fail-tls-rollback 2>/dev/null || true
if make_test_cert "localhost" "${TLS_H3RB_DIR}"; then
  pass "H3r cert B generated"
else
  fail "H3r cert B generation failed"
fi
install_test_cert "${TLS_H3RB_DIR}" "${TLS_H3R_TREE}" "localhost" || true
if wait_container_stopped "pgpooler-h3-renew-${SUFFIX}" 90; then
  pass "H3r: container stopped instead of false active=A"
else
  fail "H3r: container should stop when rollback is unconfirmable"
fi
if docker logs "pgpooler-h3-renew-${SUFFIX}" 2>&1 | grep -q "got SIGHUP"; then
  pass "H3r: forward SIGHUP was delivered before rollback failure"
else
  fail "H3r: forward SIGHUP delivery not observed"
fi
if docker logs "pgpooler-h3-renew-${SUFFIX}" 2>&1 | grep -q "could not be verified after rollback; stopping container"; then
  pass "H3r: unverifiable rollback logged"
else
  fail "H3r: unverifiable rollback should be logged"
fi
docker cp "pgpooler-h3-renew-${SUFFIX}:/run/pgbouncer/tls/.fingerprint" "/tmp/pgpooler-h3r-fp-${SUFFIX}" 2>/dev/null || true
if [ -f "/tmp/pgpooler-h3r-fp-${SUFFIX}" ] && [ "$(tr -d '\n' < "/tmp/pgpooler-h3r-fp-${SUFFIX}" 2>/dev/null)" = "${_H3R_APPLIED_A}" ]; then
  pass "H3r: applied still A (never advanced to B)"
else
  fail "H3r: applied must remain A"
fi
if docker cp "pgpooler-h3-renew-${SUFFIX}:/run/pgbouncer/tls/.fullchain.pem.prev" "/tmp/pgpooler-h3r-prev-${SUFFIX}" 2>/dev/null; then
  pass "H3r: backup retained for recovery"
else
  fail "H3r: backup must be retained when rollback is unconfirmed"
fi
if PGPASSWORD="${FRONTEND_PASSWORD}" psql -X -q -h 127.0.0.1 -p "${H3R_PORT}" -U "${FRONTEND_USER}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1; then
  fail "H3r: no service may be offered after stop"
else
  pass "H3r: no false service after stop"
fi
if [ "$(docker inspect -f '{{.State.Running}}' "pgpooler-h3-renew-${SUFFIX}" 2>/dev/null || printf 'false')" = "false" ]; then
  pass "H3r: container stays stopped"
else
  fail "H3r: container should remain stopped"
fi
rm -f "/tmp/pgpooler-h3r-fp-${SUFFIX}" "/tmp/pgpooler-h3r-prev-${SUFFIX}" 2>/dev/null || true
docker rm -f "pgpooler-h3-renew-${SUFFIX}" >/dev/null 2>&1 || true

log "--- Test H4: reload failure versus probe failure behave differently ---"
TLS_H4A_DIR="${TLS_BASE}/h4a"
TLS_H4A_TREE="${TLS_BASE}/h4a-tree"
H4A_PORT=16455
H4A_UI=18055
mkdir -p "${TLS_H4A_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_H4A_DIR}"; then
  pass "H4a cert generated (not yet installed)"
else
  fail "H4a cert generation failed"
fi
docker run -d --name "pgpooler-h4-reloadfail-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${H4A_PORT}:6432" -p "127.0.0.1:${H4A_UI}:8080" \
  -v "${TLS_H4A_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${H4A_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "H4a: initial plaintext works"
else
  fail "H4a: initial plaintext did not start"
fi
docker exec "pgpooler-h4-reloadfail-${SUFFIX}" touch /run/pgbouncer/.fail-tls-reload 2>/dev/null || true
install_test_cert "${TLS_H4A_DIR}" "${TLS_H4A_TREE}" "localhost" || true
sleep 13
if [ "$(sighup_count "pgpooler-h4-reloadfail-${SUFFIX}")" = "0" ]; then
  pass "H4a: no SIGHUP sent when reload helper fails"
else
  fail "H4a: reload failure must send no SIGHUP"
fi
if assert_state_now "pgpooler-h4-reloadfail-${SUFFIX}" "plaintext"; then
  pass "H4a: state stays plaintext"
else
  fail "H4a: state must remain plaintext"
fi
if [ -z "$(read_applied_fp "pgpooler-h4-reloadfail-${SUFFIX}")" ]; then
  pass "H4a: applied stays empty"
else
  fail "H4a: applied must stay empty"
fi
docker rm -f "pgpooler-h4-reloadfail-${SUFFIX}" >/dev/null 2>&1 || true
TLS_H4B_DIR="${TLS_BASE}/h4b"
TLS_H4B_TREE="${TLS_BASE}/h4b-tree"
H4B_PORT=16456
H4B_UI=18056
mkdir -p "${TLS_H4B_TREE}/live/localhost" 2>/dev/null || true
if make_test_cert "localhost" "${TLS_H4B_DIR}"; then
  pass "H4b cert generated (not yet installed)"
else
  fail "H4b cert generation failed"
fi
docker run -d --name "pgpooler-h4-probefail-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${H4B_PORT}:6432" -p "127.0.0.1:${H4B_UI}:8080" \
  -v "${TLS_H4B_TREE}:/caprover-letsencrypt:ro" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  -e PUBLIC_HOST=localhost -e PGPOOLER_SSL_MODE=prefer -e PGPOOLER_TLS_POLL_INTERVAL=5 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${H4B_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  pass "H4b: initial plaintext works"
else
  fail "H4b: initial plaintext did not start"
fi
docker exec "pgpooler-h4-probefail-${SUFFIX}" touch /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
install_test_cert "${TLS_H4B_DIR}" "${TLS_H4B_TREE}" "localhost" || true
_H4B_SIGHUPS=0
_i=0
while [ "${_i}" -lt 30 ]; do
  _H4B_SIGHUPS=$(sighup_count "pgpooler-h4-probefail-${SUFFIX}")
  if [ "${_H4B_SIGHUPS}" -ge 2 ]; then
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H4B_SIGHUPS}" -ge 2 ]; then
  pass "H4b: probe failure triggers explicit rollback reload"
else
  fail "H4b: expected forward plus rollback SIGHUPs"
fi
if assert_state_now "pgpooler-h4-probefail-${SUFFIX}" "plaintext"; then
  pass "H4b: state stays plaintext"
else
  fail "H4b: state must remain plaintext"
fi
if [ -z "$(read_applied_fp "pgpooler-h4-probefail-${SUFFIX}")" ]; then
  pass "H4b: applied stays empty"
else
  fail "H4b: applied must stay empty"
fi
_H4B_PLAIN_OK=0
_i=0
while [ "${_i}" -lt 30 ]; do
  if try_connect "${H4B_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
    _H4B_PLAIN_OK=1
    break
  fi
  sleep 1
  _i=$((_i + 1))
done
if [ "${_H4B_PLAIN_OK}" = "1" ]; then
  pass "H4b: plaintext confirmed live after rollback"
else
  fail "H4b: plaintext must work after rollback"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "pgpooler-h4-probefail-${SUFFIX}"; then
  pass "H4b: container alive after confirmed rollback"
else
  fail "H4b: container should stay alive after confirmed rollback"
fi
docker exec "pgpooler-h4-probefail-${SUFFIX}" rm -f /run/pgbouncer/.fail-tls-endpoint-verification 2>/dev/null || true
if wait_tls_state "pgpooler-h4-probefail-${SUFFIX}" "active" 40; then
  pass "H4b: retry succeeds after fault removed"
else
  fail "H4b: retry did not reach active"
fi
docker rm -f "pgpooler-h4-probefail-${SUFFIX}" >/dev/null 2>&1 || true

# Scrub TLS temp trees (may contain test keys; never committed).
rm -rf "${TLS_BASE}" 2>/dev/null || true
for _f in /tmp/pgpooler-uiwait-${SUFFIX}.tmp; do
  [ -f "${_f}" ] || continue
  rm -f "${_f}" || true
done

log "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
# Scrub temp logs (defense in depth; they may contain hashes).
for _f in /tmp/pgpooler-*-${SUFFIX}.log; do
  [ -f "${_f}" ] || continue
  rm -f "${_f}" || true
done
if [ "${FAIL_COUNT}" -ne 0 ]; then
  exit 1
fi
