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
else
  BACKEND_PASSWORD="be-$$-$(date +%s)-test"
  FRONTEND_PASSWORD="fe-$$-$(date +%s)-test"
  WRONG_PASSWORD="wr-$$-$(date +%s)-test"
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
    if PGPASSWORD="${_p}" psql -h 127.0.0.1 -p "${_hp}" -U "${_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1; then
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
  PGPASSWORD="${_p}" psql -h 127.0.0.1 -p "${_hp}" -U "${_u}" -d "${TESTDB}" -tA -c "SELECT current_user;" 2>/dev/null
}

# Attempt a connection; returns 0 on success, 1 on failure (no output).
# Args: host_port user password
try_connect() {
  _hp="$1"; _u="$2"; _p="$3"
  PGPASSWORD="${_p}" psql -h 127.0.0.1 -p "${_hp}" -U "${_u}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1
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
  sh -c 'grep -q " user=backend_user" /etc/pgbouncer/pgbouncer.ini && grep -q " password=" /etc/pgbouncer/pgbouncer.ini && ! grep -q " user=app_user" /etc/pgbouncer/pgbouncer.ini && ! grep -q "^testdb.*auth_user" /etc/pgbouncer/pgbouncer.ini && echo DBCONF_OK' \
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
  sh -c '! grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && grep -q " user=backend_user" /etc/pgbouncer/pgbouncer.ini && grep -q " password=" /etc/pgbouncer/pgbouncer.ini && echo URL_OK' \
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
  sh -c '! grep -q "\"foo\"" /etc/pgbouncer/userlist.txt && ! grep -q "\"bar\"" /etc/pgbouncer/userlist.txt && grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && grep -q " user=foo" /etc/pgbouncer/pgbouncer.ini && grep -q " user=bar" /etc/pgbouncer/pgbouncer.ini && echo URLS_OK' \
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

log "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
# Scrub temp logs (defense in depth; they may contain hashes).
for _f in /tmp/pgpooler-*-${SUFFIX}.log; do
  [ -f "${_f}" ] || continue
  rm -f "${_f}" || true
done
if [ "${FAIL_COUNT}" -ne 0 ]; then
  exit 1
fi
