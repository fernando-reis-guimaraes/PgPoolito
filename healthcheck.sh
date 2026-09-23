#!/bin/sh
# PgPooler-Uma healthcheck: no PostgreSQL authentication, no secrets.
# Passes when the HTTP UI is reachable and, when PgBouncer is expected
# to be running with a settled state, its TCP port accepts connections
# (no login attempted).
# In required+waiting state PgBouncer is intentionally absent; UI alone
# is sufficient and the container is not reported as broken. The
# transitional prepared state is treated the same way (UI only) so a
# normal activation never trips a restart loop; a failed activation
# reverts to waiting, which is also UI-only healthy.
set -eu

LISTEN_PORT="${LISTEN_PORT:-5432}"
HTTP_PORT="8080"
STATE_FILE="/run/pgbouncer/pgpooler.state"

_ui_ok=0
if command -v wget >/dev/null 2>&1; then
  if wget -q -O /dev/null -T 3 "http://127.0.0.1:${HTTP_PORT}/" >/dev/null 2>&1; then
    _ui_ok=1
  fi
else
  # Fallback TCP check for the UI port when wget is unavailable.
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 3 127.0.0.1 "${HTTP_PORT}" >/dev/null 2>&1; then
      _ui_ok=1
    fi
  fi
fi

_expect=1
_state=""
if [ -f "${STATE_FILE}" ]; then
  # Only read our own fixed keys; never evaluate the file.
  _line=$(grep -E '^EXPECT_PGBOUNCER=' "${STATE_FILE}" 2>/dev/null | tail -n 1 || true)
  case "${_line}" in
    EXPECT_PGBOUNCER=0) _expect=0 ;;
    EXPECT_PGBOUNCER=1) _expect=1 ;;
  esac
  _state=$(grep -E '^TLS_STATE=' "${STATE_FILE}" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
fi

if [ "${_ui_ok}" -ne 1 ]; then
  exit 1
fi

if [ "${_expect}" -eq 0 ]; then
  # Intentional waiting state (required, certificate pending).
  exit 0
fi

case "${_state}" in
  waiting|prepared)
    # Transitional or intentionally absent PgBouncer; UI reachability
    # above is sufficient.
    exit 0
    ;;
esac

# PgBouncer TCP liveness without authentication (no pg_isready login).
if command -v nc >/dev/null 2>&1; then
  if nc -z -w 3 127.0.0.1 "${LISTEN_PORT}" >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
fi

# Last resort: process presence (no network probe).
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -x pgbouncer >/dev/null 2>&1; then
    exit 0
  fi
  exit 1
fi
if ps aux 2>/dev/null | grep -q '[p]gbouncer'; then
  exit 0
fi
exit 1
