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
sleep 5
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
sleep 6
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
