#!/bin/sh
# PgPooler-Uma integration + config tests.
# Covers: legacy auth, split auth (frontend PGBOUNCER_* vs backend DB_*),
# wrong-password rejection, partial-pair validation, same-user conflict,
# auth-file generation, forced backend user in pgbouncer.ini, and image build.
#
# Security: passwords are generated per-run (never committed) and never
# printed. Test output only shows usernames, ports, and pass/fail markers.
# Do not run with `set -x` / `sh -x`.
#
# Usage: ./tests/test_pgpooler.sh [--image <name>] [--keep]
# Requires: docker, psql (postgresql-client)

set -eu

IMAGE="${IMAGE:-pgpooler-test:local}"
KEEP=0
for _a in "$@"; do
  case "${_a}" in
    --image) shift; IMAGE="$1"; shift ;;
    --image=*) IMAGE="${_a#--image=}"; shift ;;
    --keep) KEEP=1; shift ;;
    *) ;;
  esac
done
# Manual arg parse (POSIX): support --image NAME and --keep
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
  BACKEND_PASSWORD="be-$$-$RANDOM-test"
  FRONTEND_PASSWORD="fe-$$-$RANDOM-test"
  WRONG_PASSWORD="wr-$$-$RANDOM-test"
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
  # Remove any test containers (names contain the unique suffix).
  for _c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "pgpooler-test-.*${SUFFIX}" || true); do
    docker rm -f "${_c}" >/dev/null 2>&1 || true
  done
  # Also catch fixed helper names from config-only runs.
  for _c in pgpooler-cfg-legacy pgpooler-cfg-split pgpooler-partial-1 pgpooler-partial-2 pgpooler-conflict pgpooler-identical pgpooler-authfile pgpooler-dbconf pgpooler-legacy-live pgpooler-split-live; do
    docker rm -f "${_c}-${SUFFIX}" >/dev/null 2>&1 || true
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
log "--- Test 6: auth-file generation (usernames present, no password leak) ---"
docker run --rm --name "pgpooler-authfile-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && echo AUTHFILE_OK' \
  >/tmp/pgpooler-authfile-${SUFFIX}.log 2>&1 || true
if grep -q "AUTHFILE_OK" /tmp/pgpooler-authfile-${SUFFIX}.log 2>/dev/null; then
  pass "split auth-file contains both backend_user and app_user"
else
  fail "split auth-file missing expected usernames"
fi
# Ensure startup logs never echo either password.
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-authfile-${SUFFIX}.log 2>/dev/null; then
  fail "backend password leaked into startup logs"
else
  pass "no backend password in startup logs"
fi
if grep -F -q "${FRONTEND_PASSWORD}" /tmp/pgpooler-authfile-${SUFFIX}.log 2>/dev/null; then
  fail "frontend password leaked into startup logs"
else
  pass "no frontend password in startup logs"
fi
# No duplicate entries.
docker run --rm --name "pgpooler-dedup-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" \
  sh -c 'test "$(grep -c "\"backend_user\"" /etc/pgbouncer/userlist.txt)" = "1" && test "$(grep -c "\"app_user\"" /etc/pgbouncer/userlist.txt)" = "1" && echo DEDUP_OK' \
  >/tmp/pgpooler-dedup-${SUFFIX}.log 2>&1 || true
if grep -q "DEDUP_OK" /tmp/pgpooler-dedup-${SUFFIX}.log 2>/dev/null; then
  pass "auth-file has no duplicate entries"
else
  fail "auth-file duplicate check failed"
fi

log "--- Test 7: generated database config forces backend user ---"
docker run --rm --name "pgpooler-dbconf-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" cat /etc/pgbouncer/pgbouncer.ini \
  >/tmp/pgpooler-dbconf-${SUFFIX}.log 2>&1 || true
if grep -q "user=${BACKEND_USER}" /tmp/pgpooler-dbconf-${SUFFIX}.log 2>/dev/null; then
  pass "pgbouncer.ini contains user=${BACKEND_USER}"
else
  fail "pgbouncer.ini missing forced backend user"
fi
if grep -q "user=${FRONTEND_USER}" /tmp/pgpooler-dbconf-${SUFFIX}.log 2>/dev/null; then
  fail "pgbouncer.ini must not force user=${FRONTEND_USER}"
else
  pass "pgbouncer.ini does not force frontend user"
fi
if grep -F -q "${BACKEND_PASSWORD}" /tmp/pgpooler-dbconf-${SUFFIX}.log 2>/dev/null; then
  fail "backend password leaked into pgbouncer.ini output"
else
  pass "no backend password in pgbouncer.ini"
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

log "--- Test 5: same username with conflicting passwords must fail ---"
if docker run --rm --name "pgpooler-conflict-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGBOUNCER_USER="${BACKEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-conflict-${SUFFIX}.log 2>&1; then
  fail "startup with conflicting same-username passwords should fail"
else
  if grep -qi "cannot represent two different passwords" /tmp/pgpooler-conflict-${SUFFIX}.log 2>/dev/null; then
    pass "conflicting same-username passwords fail clearly"
  else
    fail "conflict failed but without clear error"
  fi
fi
log "--- Test 5b: identical username+password is accepted ---"
if docker run --rm --name "pgpooler-identical-${SUFFIX}" \
  -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
  -e PGBOUNCER_USER="${BACKEND_USER}" -e PGBOUNCER_PASSWORD="${BACKEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" true >/tmp/pgpooler-identical-${SUFFIX}.log 2>&1; then
  pass "identical frontend/backend credentials accepted"
else
  fail "identical frontend/backend credentials should be accepted"
fi

log "--- Test 7b: DATABASE_URL split forces backend user ---"
docker run --rm --name "pgpooler-url-${SUFFIX}" \
  -e "DATABASE_URL=postgres://${BACKEND_USER}:${BACKEND_PASSWORD}@fakehost:5432/${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  --entrypoint /entrypoint.sh "${IMAGE}" cat /etc/pgbouncer/pgbouncer.ini \
  >/tmp/pgpooler-url-${SUFFIX}.log 2>&1 || true
if grep -q "user=${BACKEND_USER}" /tmp/pgpooler-url-${SUFFIX}.log 2>/dev/null && ! grep -q "user=${FRONTEND_USER}" /tmp/pgpooler-url-${SUFFIX}.log 2>/dev/null; then
  pass "DATABASE_URL split entry forces backend user"
else
  fail "DATABASE_URL split entry missing forced backend user"
fi

log "--- Test 7c: AUTH_TYPE variants preserve userlist behavior ---"
for _at in md5 plain scram-sha-256; do
  if docker run --rm --name "pgpooler-authtype-${SUFFIX}" \
    -e DB_HOST=fakehost -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" \
    -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
    -e AUTH_TYPE="${_at}" \
    --entrypoint /entrypoint.sh "${IMAGE}" \
    sh -c 'grep -q "\"backend_user\"" /etc/pgbouncer/userlist.txt && grep -q "\"app_user\"" /etc/pgbouncer/userlist.txt && echo AUTHTYPE_OK' \
    >/tmp/pgpooler-authtype-${SUFFIX}-${_at}.log 2>&1; then
    if grep -q "AUTHTYPE_OK" /tmp/pgpooler-authtype-${SUFFIX}-${_at}.log 2>/dev/null; then
      pass "AUTH_TYPE=${_at} generates both userlist entries"
    else
      fail "AUTH_TYPE=${_at} missing userlist entries"
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

log "--- Test 1: legacy behavior (DB_* only) ---"
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

log "--- Test 2: split authentication (frontend app_user -> backend backend_user) ---"
SPLIT_PORT=16432
docker run -d --name "pgpooler-split-live-${SUFFIX}" --network "${NET}" \
  -p "127.0.0.1:${SPLIT_PORT}:6432" \
  -e DB_HOST="${PG}" -e DB_PORT=5432 -e DB_USER="${BACKEND_USER}" -e DB_PASSWORD="${BACKEND_PASSWORD}" -e DB_NAME="${TESTDB}" \
  -e PGBOUNCER_USER="${FRONTEND_USER}" -e PGBOUNCER_PASSWORD="${FRONTEND_PASSWORD}" \
  -e LISTEN_PORT=6432 -e AUTH_TYPE=scram-sha-256 \
  "${IMAGE}" >/dev/null
if wait_pgbouncer "${SPLIT_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}"; then
  _u="$(query_current_user "${SPLIT_PORT}" "${FRONTEND_USER}" "${FRONTEND_PASSWORD}")"
  if [ "${_u}" = "${BACKEND_USER}" ]; then
    pass "split auth maps ${FRONTEND_USER} to backend ${BACKEND_USER}"
  else
    fail "split current_user mismatch (got '${_u}', want '${BACKEND_USER}')"
  fi
else
  fail "split pgbouncer did not become ready"
  docker logs "pgpooler-split-live-${SUFFIX}" 2>&1 | head -20 || true
fi

log "--- Test 3: wrong frontend password must fail ---"
if PGPASSWORD="${WRONG_PASSWORD}" psql -h 127.0.0.1 -p "${SPLIT_PORT}" -U "${FRONTEND_USER}" -d "${TESTDB}" -tA -c "SELECT 1;" >/dev/null 2>&1; then
  fail "wrong frontend password should not authenticate"
else
  pass "wrong frontend password is rejected"
fi
docker rm -f "pgpooler-split-live-${SUFFIX}" >/dev/null 2>&1 || true

log "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
# Scrub temp logs of secrets before exiting (defense in depth).
for _f in /tmp/pgpooler-*-${SUFFIX}.log; do
  [ -f "${_f}" ] || continue
  # Do not print; just remove files that could contain hashes.
  rm -f "${_f}" || true
done
if [ "${FAIL_COUNT}" -ne 0 ]; then
  exit 1
fi
