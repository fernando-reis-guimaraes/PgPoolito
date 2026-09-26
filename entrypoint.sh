#!/bin/sh
# Based on https://raw.githubusercontent.com/brainsam/pgbouncer/master/entrypoint.sh

set -e

# Here are some parameters. See all on
# https://pgbouncer.github.io/config.html

PG_CONFIG_DIR=/etc/pgbouncer
PG_CONFIG_FILE="${PG_CONFIG_DIR}/pgbouncer.ini"
_AUTH_FILE="${AUTH_FILE:-$PG_CONFIG_DIR/userlist.txt}"

# Load PgPoolito TLS + UI helpers when present (container path first,
# then relative to this script for local execution). Never fail when the
# helpers are absent in minimal test harnesses.
if [ -f "/usr/local/lib/pgpooler/tls.sh" ]; then
  # shellcheck source=/dev/null
  . "/usr/local/lib/pgpooler/tls.sh"
elif [ -f "$(dirname -- "$0")/lib/tls.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname -- "$0")/lib/tls.sh"
elif [ -f "./lib/tls.sh" ]; then
  # shellcheck source=/dev/null
  . "./lib/tls.sh"
fi
if [ -f "/usr/local/lib/pgpooler/ui.sh" ]; then
  # shellcheck source=/dev/null
  . "/usr/local/lib/pgpooler/ui.sh"
elif [ -f "$(dirname -- "$0")/lib/ui.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname -- "$0")/lib/ui.sh"
elif [ -f "./lib/ui.sh" ]; then
  # shellcheck source=/dev/null
  . "./lib/ui.sh"
fi

# PgPoolito frontend TLS policy (CapRover-friendly).
# PGPOOLER_SSL_MODE controls automatic CapRover certificate discovery.
# It is NOT PgBouncer native client_tls_sslmode. Our prefer means:
# plaintext only while no valid certificate exists, require once one does.
# Both prefer (with cert) and required (with cert) map to native require.
PGPOOLER_SSL_MODE="${PGPOOLER_SSL_MODE:-prefer}"
case "${PGPOOLER_SSL_MODE}" in
  disabled|prefer|required) ;;
  *)
    echo "error: invalid PGPOOLER_SSL_MODE='${PGPOOLER_SSL_MODE}' (expected disabled|prefer|required)." >&2
    exit 1
    ;;
esac

# PUBLIC_HOST is the single canonical explicit hostname. Untrusted input:
# sanitize before any filesystem or OpenSSL use. No eval anywhere.
PUBLIC_HOST_SANITIZED=""
if [ -n "${PUBLIC_HOST:-}" ]; then
  if command -v sanitize_public_host >/dev/null 2>&1; then
    if PUBLIC_HOST_SANITIZED=$(sanitize_public_host "${PUBLIC_HOST}" 2>/dev/null); then
      :
    else
      echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
      exit 1
    fi
  else
    # Fallback minimal guard when helper lib is unavailable.
    case "${PUBLIC_HOST}" in
      *[!A-Za-z0-9.-]*)
        echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
        exit 1
        ;;
      .*)
        echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
        exit 1
        ;;
      *.)
        echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
        exit 1
        ;;
      -*)
        echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
        exit 1
        ;;
      *-)
        echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
        exit 1
        ;;
      *..*)
        echo "error: invalid PUBLIC_HOST value (must be a single DNS hostname)." >&2
        exit 1
        ;;
      *)
        PUBLIC_HOST_SANITIZED="${PUBLIC_HOST}"
        ;;
    esac
  fi
fi

# Manual frontend TLS identity (advanced / non-CapRover users).
# Only CERT_FILE / KEY_FILE / SSLMODE count; CA/protocols/ciphers alone
# do not trigger manual mode and may accompany automatic TLS.
MANUAL_FRONTEND_TLS=0
if [ -n "${CLIENT_TLS_CERT_FILE:-}" ] || [ -n "${CLIENT_TLS_KEY_FILE:-}" ] || [ -n "${CLIENT_TLS_SSLMODE:-}" ]; then
  MANUAL_FRONTEND_TLS=1
fi

# Automatic CapRover discovery is a candidate only when a hostname is
# configured and the policy is not disabled. Without PUBLIC_HOST we never
# scan certificate directories (a server may hold dozens of certs).
AUTO_TLS_CANDIDATE=0
if [ "${PGPOOLER_SSL_MODE}" != "disabled" ] && [ -n "${PUBLIC_HOST_SANITIZED}" ]; then
  AUTO_TLS_CANDIDATE=1
fi

# Deterministic precedence: never silently mix automatic discovery with a
# manually specified certificate/key pair. Fail clearly instead of guessing.
if [ "${AUTO_TLS_CANDIDATE}" = "1" ] && [ "${MANUAL_FRONTEND_TLS}" = "1" ]; then
  echo "error: conflicting frontend TLS configuration: PUBLIC_HOST automatic TLS (PGPOOLER_SSL_MODE=${PGPOOLER_SSL_MODE}) cannot be combined with manual CLIENT_TLS_CERT_FILE/CLIENT_TLS_KEY_FILE/CLIENT_TLS_SSLMODE. Unset the manual settings for automatic CapRover TLS, or unset PUBLIC_HOST to use manual TLS." >&2
  exit 1
fi

# disabled means frontend TLS is actually off: automatic discovery is off
# and a manual frontend TLS identity must not be accepted either, otherwise
# the UI would report Disabled while PgBouncer enforces TLS.
if [ "${PGPOOLER_SSL_MODE}" = "disabled" ] && [ "${MANUAL_FRONTEND_TLS}" = "1" ]; then
  echo "error: PGPOOLER_SSL_MODE=disabled cannot be combined with manual CLIENT_TLS_CERT_FILE/CLIENT_TLS_KEY_FILE/CLIENT_TLS_SSLMODE. Unset the manual settings for disabled TLS, or use PGPOOLER_SSL_MODE=prefer without PUBLIC_HOST for manual TLS." >&2
  exit 1
fi

# Validate a manual frontend TLS identity (advanced / non-CapRover users).
# A bare CA/protocols/ciphers setting without CERT/KEY/SSLMODE is not an
# identity and needs no validation here. Partial or contradictory pairs
# fail fast so PgBouncer can never start with an incomplete identity.
if [ "${MANUAL_FRONTEND_TLS}" = "1" ]; then
  if [ -n "${CLIENT_TLS_CERT_FILE:-}" ] && [ -z "${CLIENT_TLS_KEY_FILE:-}" ]; then
    echo "error: CLIENT_TLS_CERT_FILE is set without CLIENT_TLS_KEY_FILE; both or neither are required." >&2
    exit 1
  fi
  if [ -z "${CLIENT_TLS_CERT_FILE:-}" ] && [ -n "${CLIENT_TLS_KEY_FILE:-}" ]; then
    echo "error: CLIENT_TLS_KEY_FILE is set without CLIENT_TLS_CERT_FILE; both or neither are required." >&2
    exit 1
  fi
  if [ -n "${CLIENT_TLS_SSLMODE:-}" ]; then
    case "${CLIENT_TLS_SSLMODE}" in
      disable|allow|prefer|require|verify-ca|verify-full) ;;
      *)
        echo "error: invalid CLIENT_TLS_SSLMODE='${CLIENT_TLS_SSLMODE}' (expected disable|allow|prefer|require|verify-ca|verify-full)." >&2
        exit 1
        ;;
    esac
  fi
  case "${CLIENT_TLS_SSLMODE:-}" in
    require|verify-ca|verify-full)
      if [ -z "${CLIENT_TLS_CERT_FILE:-}" ] || [ -z "${CLIENT_TLS_KEY_FILE:-}" ]; then
        echo "error: CLIENT_TLS_SSLMODE='${CLIENT_TLS_SSLMODE}' needs both CLIENT_TLS_CERT_FILE and CLIENT_TLS_KEY_FILE." >&2
        exit 1
      fi
      ;;
  esac
  if [ -n "${CLIENT_TLS_CERT_FILE:-}" ] && [ ! -r "${CLIENT_TLS_CERT_FILE}" ]; then
    echo "error: manual frontend TLS certificate is not readable; refusing to start with an incomplete TLS identity." >&2
    exit 1
  fi
  if [ -n "${CLIENT_TLS_KEY_FILE:-}" ] && [ ! -r "${CLIENT_TLS_KEY_FILE}" ]; then
    echo "error: manual frontend TLS key is not readable; refusing to start with an incomplete TLS identity." >&2
    exit 1
  fi
fi

# required without any TLS source can never succeed: fail fast instead of
# waiting forever with nothing to watch.
if [ "${PGPOOLER_SSL_MODE}" = "required" ] && [ "${AUTO_TLS_CANDIDATE}" = "0" ] && [ "${MANUAL_FRONTEND_TLS}" = "0" ]; then
  echo "error: PGPOOLER_SSL_MODE=required needs either PUBLIC_HOST (automatic CapRover certificate) or manual CLIENT_TLS_* configuration. No TLS source is configured." >&2
  exit 1
fi

# required with manual TLS (no automatic candidate) must actually enforce
# TLS: the manual sslmode must be require or stricter.
if [ "${PGPOOLER_SSL_MODE}" = "required" ] && [ "${AUTO_TLS_CANDIDATE}" = "0" ] && [ "${MANUAL_FRONTEND_TLS}" = "1" ]; then
  case "${CLIENT_TLS_SSLMODE:-}" in
    require|verify-ca|verify-full) ;;
    *)
      echo "error: PGPOOLER_SSL_MODE=required with manual TLS needs CLIENT_TLS_SSLMODE=require (or verify-ca/verify-full). Current value does not enforce TLS." >&2
      exit 1
      ;;
  esac
fi

# Watcher polling interval (seconds). Default 300 per spec; override is
# honored for tests/advanced tuning. No busy loop: minimum 5 seconds.
PGPOOLER_TLS_POLL_INTERVAL="${PGPOOLER_TLS_POLL_INTERVAL:-300}"
case "${PGPOOLER_TLS_POLL_INTERVAL}" in
  ''|*[!0-9]*)
    echo "error: invalid PGPOOLER_TLS_POLL_INTERVAL='${PGPOOLER_TLS_POLL_INTERVAL}' (expected integer seconds)." >&2
    exit 1
    ;;
esac
if [ "${PGPOOLER_TLS_POLL_INTERVAL}" -lt 5 ]; then
  PGPOOLER_TLS_POLL_INTERVAL=5
fi
if [ "${PGPOOLER_TLS_POLL_INTERVAL}" -gt 3600 ]; then
  PGPOOLER_TLS_POLL_INTERVAL=3600
fi

# Runtime TLS locations (mirror lib/tls.sh defaults when lib is missing).
if [ -z "${TLS_RUNTIME_DIR:-}" ]; then
  TLS_RUNTIME_DIR="/run/pgbouncer/tls"
fi
if [ -z "${TLS_RUNTIME_CERT:-}" ]; then
  TLS_RUNTIME_CERT="${TLS_RUNTIME_DIR}/fullchain.pem"
fi
if [ -z "${TLS_RUNTIME_KEY:-}" ]; then
  TLS_RUNTIME_KEY="${TLS_RUNTIME_DIR}/privkey.pem"
fi
if [ -z "${PGPOOLER_STATE_FILE:-}" ]; then
  PGPOOLER_STATE_FILE="/run/pgbouncer/pgpooler.state"
fi
if [ -z "${CAPROVER_BASE:-}" ]; then
  CAPROVER_BASE="/caprover-letsencrypt"
fi
if [ -z "${TLS_APPLIED_FILE:-}" ]; then
  TLS_APPLIED_FILE="/run/pgbouncer/tls/.fingerprint"
fi
# Test-only fault-injection flags (runtime files, absent by default).
# The test harness creates/removes them inside a running container to force
# deterministic config-update, reload, backup, endpoint-verification, or
# TLS-reload-rejection failures and verify fail-closed retry behavior.
# They are never set in production and change nothing when absent.
# Never contain secrets.
TLS_FAIL_CONFIG_UPDATE_FILE="/run/pgbouncer/.fail-tls-config-update"
TLS_FAIL_RELOAD_FILE="/run/pgbouncer/.fail-tls-reload"
# TLS_FAIL_BACKUP_FILE / TLS_FAIL_ENDPOINT_FILE / TLS_FAIL_INSTALL_FILE
# defaults live in lib/tls.sh (consumed there); the remaining flags are
# consumed below. All are test-only, absent by default, never secrets.
TLS_FAIL_PROTOCOLS_FILE="/run/pgbouncer/.fail-tls-protocols"
TLS_FAIL_ROLLBACK_FILE="/run/pgbouncer/.fail-tls-rollback"
# Sentinel value injected into the rewritten config while the protocols
# fault flag is present. PgBouncer 1.25.2 rejects it at RELOAD while
# keeping the previous TLS context (verified live), which deterministically
# simulates "SIGHUP delivered but TLS not applied". Stripped on every
# rewrite and re-added only while the flag is present, so removing the
# flag heals the config on the next poll.
TLS_FAIL_PROTOCOLS_SENTINEL="bogusproto-pgpooler-test"
HTTP_PORT="8080"
WWW_DIR="/var/www"
WWW_FILE="${WWW_DIR}/index.html"
PGBOUNCER_PID_FILE="/run/pgbouncer/pgbouncer.pid"

# Frontend TLS runtime state. One of: disabled, plaintext, prepared,
# waiting, active, manual, manual-require. Also controls UI + healthcheck.
# `prepared` means the automatic certificate is installed and the config
# is verified to require TLS, but the live endpoint has not been
# externally verified yet. `active` additionally means the running
# PgBouncer was externally verified to serve the expected certificate.
FRONTEND_TLS_STATE="plaintext"
FRONTEND_TLS_ACTIVE=0
EXPECT_PGBOUNCER=1

# Workaround userlist.txt missing issue
# https://github.com/edoburu/docker-pgbouncer/issues/33
if [ ! -e "${_AUTH_FILE}" ]; then
  touch "${_AUTH_FILE}"
fi
# Restrict auth file permissions (contains credentials).
chmod 0600 "${_AUTH_FILE}" 2>/dev/null || true
if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
  chown postgres:postgres "${_AUTH_FILE}" 2>/dev/null || true
fi

# PgPoolito extension: optional independent frontend credentials.
# PGBOUNCER_USER / PGBOUNCER_PASSWORD authenticate applications connecting
# TO PgBouncer, while DB_USER / DB_PASSWORD are the credentials PgBouncer
# uses FROM PgBouncer TO PostgreSQL via native `user=` / `password=`
# database parameters.
# Legacy mode (neither set) is fully backward-compatible with upstream.
# Split mode (both set): auth_file holds ONLY the frontend credential;
# backend credentials live ONLY in the generated [databases] entry.
SPLIT_AUTH=0
if [ -n "${PGBOUNCER_USER:-}" ] || [ -n "${PGBOUNCER_PASSWORD:-}" ]; then
  if [ -z "${PGBOUNCER_USER:-}" ] || [ -z "${PGBOUNCER_PASSWORD:-}" ]; then
    echo "error: PGBOUNCER_USER and PGBOUNCER_PASSWORD must be set together (both or neither)." >&2
    echo "error: refusing to start with a partial frontend credential pair." >&2
    exit 1
  fi
  SPLIT_AUTH=1
fi

# True if $1 contains a literal LF or CR. The auth_file is line-oriented,
# so such values can never be represented safely in a one-line entry.
# Never prints the value.
has_cr_or_lf() {
  _cr=$(printf '\r')
  case "$1" in
*"
"*|*"${_cr}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Split-mode frontend credentials must not contain line breaks.
if [ -n "${PGBOUNCER_USER:-}" ] && has_cr_or_lf "${PGBOUNCER_USER}"; then
  echo "error: PGBOUNCER_USER contains a newline or carriage return and cannot be represented safely in PgBouncer auth_file" >&2
  exit 1
fi
if [ -n "${PGBOUNCER_PASSWORD:-}" ] && has_cr_or_lf "${PGBOUNCER_PASSWORD}"; then
  echo "error: PGBOUNCER_PASSWORD contains a newline or carriage return and cannot be represented safely in PgBouncer auth_file" >&2
  exit 1
fi

# True (0) when $1 is empty or whitespace-only; false when it contains at
# least one non-whitespace byte. Check-only, no modification, no eval.
# Never prints the value. POSIX /bin/sh compatible.
is_blank_db_name() {
  case "$1" in
    "") return 0 ;;
    *[![:space:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Fail fast when the effective database name is missing or whitespace-only.
# Args: value context-label (label never contains secrets).
# The [databases] section is line-oriented, so blank or CR/LF-bearing keys
# can never be represented safely. Legitimate names (including those with
# embedded spaces) pass through byte-identical. Never prints the value.
require_valid_db_name() {
  if is_blank_db_name "$1"; then
    echo "error: database name is required and must not be empty or whitespace-only ($2); set DB_NAME or use DATABASE_URL ending in /<database>." >&2
    exit 1
  fi
  if has_cr_or_lf "$1"; then
    echo "error: database name contains a newline or carriage return and cannot be represented safely in pgbouncer.ini ($2)." >&2
    exit 1
  fi
}

# Extract all info from a given URL. Sets variables because shell functions can't return multiple values.
#
# Parameters:
#   - The url we should parse
# Returns (sets variables): DB_USER, DB_PASSWORD, DB_HOST, DB_PORT, DB_NAME
# Limitation (upstream parser, preserved): credentials are split naively on
# `:`, `@`, `/`, `,`. Passwords containing those characters (or requiring
# percent-encoding) may misparse; prefer separate DB_* variables for such
# credentials. Parsed values are safely re-serialized on output, but a
# misparsed value cannot be recovered. Never logs the URL.
parse_url() {
  # Thanks to https://stackoverflow.com/a/17287984/146289

  # Allow to pass values like dj-database-url / django-environ accept
  proto="$(echo $1 | grep :// | sed -e's,^\(.*://\).*,\1,g')"
  url="$(echo $1 | sed -e s,$proto,,g)"

  # extract the user and password (if any)
  userpass="$(echo $url | grep @ | sed -r 's/^(.*)@([^@]*)$/\1/')"
  DB_PASSWORD="$(echo $userpass | grep : | cut -d: -f2)"
  if [ -n "${DB_PASSWORD}" ]; then
    DB_USER="$(echo $userpass | grep : | cut -d: -f1)"
  else
    DB_USER="${userpass}"
  fi

  # extract the host -- updated
  hostport=`echo $url | sed -e s,$userpass@,,g | cut -d/ -f1`
  port=`echo $hostport | grep : | cut -d: -f2`
  if [ -n "$port" ]; then
    DB_HOST=`echo $hostport | grep : | cut -d: -f1`
    DB_PORT="${port}"
  else
    DB_HOST="${hostport}"
  fi

  DB_NAME="$(echo $url | grep / | cut -d/ -f2-)"
}

# Serialize a value as a PgBouncer/libpq-style connection-string value:
# surround with single quotes, double every literal single quote.
# Preserves all other characters verbatim. Writes only the serialized
# value to stdout; never logs the input. POSIX /bin/sh compatible.
quote_connstr_value() {
  _q_rest="$1"
  _q_acc=""
  while :; do
    case "${_q_rest}" in
      *\'*)
        _q_acc="${_q_acc}${_q_rest%%\'*}''"
        _q_rest="${_q_rest#*\'}"
        ;;
      *)
        break
        ;;
    esac
  done
  printf "'%s%s'\n" "${_q_acc}" "${_q_rest}"
}

# Serialize a PgBouncer auth-file quoted field: double every literal `"`.
# Distinct from quote_connstr_value(), which uses single-quote quoting for
# [databases] connection strings. Writes only the serialized field content
# to stdout; never logs the input. POSIX /bin/sh compatible. No eval.
quote_authfile_field() {
  _a_rest="$1"
  _a_acc=""
  while :; do
    case "${_a_rest}" in
      *\"*)
        _a_acc="${_a_acc}${_a_rest%%\"*}\"\""
        _a_rest="${_a_rest#*\"}"
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s%s\n' "${_a_acc}" "${_a_rest}"
}

# Literal auth-file username lookup (no regex).
# Serializes the username with quote_authfile_field(), then compares the
# exact `"serialized-user" ` prefix (including the trailing space before
# the password field) using shell case with the needle quoted as literal
# data. Backslashes, regex metacharacters, and doubled quotes are all
# preserved literally. Never logs credentials.
authfile_has_user() {
  _h_needle="\"$(quote_authfile_field "$1")\" "
  [ -f "${_AUTH_FILE}" ] || return 1
  while IFS= read -r _h_line || [ -n "${_h_line}" ]; do
    case "${_h_line}" in
      "${_h_needle}"*)
        return 0
        ;;
    esac
  done < "${_AUTH_FILE}"
  return 1
}

# Write a single username/password pair to the auth file, preserving the
# existing AUTH_TYPE behavior (md5 / plain / scram-sha-256).
# Skips empty credentials and avoids duplicate entries.
# Never prints passwords; only logs the username.
write_user_entry() {
  _w_user="$1"
  _w_pass="$2"
  if [ -z "${_w_user}" ] || [ -z "${_w_pass}" ]; then
    return 0
  fi
  # auth_file is line-oriented: reject line breaks instead of silently
  # writing a corrupt entry. Normal legacy credentials (no CR/LF) are
  # unaffected, so upstream compatibility is preserved for all working
  # cases; only previously-broken values now fail fast with a clear error.
  if has_cr_or_lf "${_w_user}" || has_cr_or_lf "${_w_pass}"; then
    echo "error: credential contains a newline or carriage return and cannot be represented safely in PgBouncer auth_file" >&2
    exit 1
  fi
  if [ ! -e "${_AUTH_FILE}" ]; then
    touch "${_AUTH_FILE}"
  fi
  chmod 0600 "${_AUTH_FILE}" 2>/dev/null || true
  if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${_AUTH_FILE}" 2>/dev/null || true
  fi
  if authfile_has_user "${_w_user}"; then
    return 0
  fi
  if [ "${AUTH_TYPE:-}" = "plain" ] || [ "${AUTH_TYPE:-}" = "scram-sha-256" ]; then
    _w_hash="${_w_pass}"
  else
    _w_hash="md5$(printf '%s' "${_w_pass}${_w_user}" | md5sum | cut -f 1 -d ' ')"
  fi
  printf '"%s" "%s"\n' "$(quote_authfile_field "${_w_user}")" "$(quote_authfile_field "${_w_hash}")" >> "${_AUTH_FILE}"
  echo "Wrote authentication credentials for '${_w_user}' to ${_AUTH_FILE}"
}

# Legacy backend auth: only when split mode is OFF, to remain
# upstream-compatible. In split mode the backend credential must NOT
# enter the frontend auth_file.
generate_userlist_if_needed() {
  if [ "${SPLIT_AUTH}" = "1" ]; then
    return 0
  fi
  if [ -n "${DB_USER:-}" ] && [ -n "${DB_PASSWORD:-}" ] && [ -e "${_AUTH_FILE}" ]; then
    write_user_entry "${DB_USER}" "${DB_PASSWORD}"
  fi
}

# Frontend auth: only in split mode, writes PGBOUNCER_USER to auth_file.
ensure_frontend_auth() {
  if [ "${SPLIT_AUTH}" = "1" ]; then
    write_user_entry "${PGBOUNCER_USER}" "${PGBOUNCER_PASSWORD}"
  fi
}

# Grabs variables set by `parse_url` and adds them to the PG config file as a database entry.
# Legacy mode: upstream format unchanged (auth_user only, unquoted).
# Split mode: native backend `user=` + `password=` WITHOUT per-database
# `auth_user`, otherwise PgBouncer would still accept the backend user as
# a frontend login (isolation breach). String-valued connstr parameters
# (host/user/password) are single-quote serialized; port stays numeric.
# Global AUTH_USER handling unchanged.
# Routing policy (single-upstream only): effective DB exactly "postgres"
# emits the wildcard "*" key (multi-database admin mode, no dbname, so the
# client-requested database is used). Any other valid DB emits its explicit
# name (locked mode, preserved byte-identical to upstream behavior).
# DATABASE_URLS entries never wildcard: while DATABASE_URLS is set the
# explicit name is always used. Callers must validate DB_NAME via
# require_valid_db_name() before invoking; empty/whitespace-only must fail
# fast and never reach this function.
generate_config_db_entry() {
  _db_key="${DB_NAME}"
  if [ -z "${DATABASE_URLS:-}" ] && [ "${_db_key}" = "postgres" ]; then
    _db_key="*"
  fi
  if [ "${SPLIT_AUTH}" = "1" ]; then
    _q_host="$(quote_connstr_value "${DB_HOST:?"Setup pgbouncer config error! You must set DB_HOST env"}")"
    if [ -n "${DB_USER:-}" ]; then
      _forced_user=" user=$(quote_connstr_value "${DB_USER}")"
    else
      _forced_user=""
    fi
    if [ -n "${DB_PASSWORD:-}" ]; then
      _backend_password=" password=$(quote_connstr_value "${DB_PASSWORD}")"
    else
      _backend_password=""
    fi
    printf "\
${_db_key} = host=${_q_host} \
port=${DB_PORT:-5432}${_forced_user}${_backend_password}
${CLIENT_ENCODING:+client_encoding = ${CLIENT_ENCODING}\n}\
" >> "${PG_CONFIG_FILE}"
  else
    printf "\
${_db_key} = host=${DB_HOST:?"Setup pgbouncer config error! You must set DB_HOST env"} \
port=${DB_PORT:-5432} auth_user=${DB_USER:-postgres}
${CLIENT_ENCODING:+client_encoding = ${CLIENT_ENCODING}\n}\
" >> "${PG_CONFIG_FILE}"
  fi
}

# Print generated config with password values redacted. Never print raw secrets.
print_config_redacted() {
  if [ -f "${PG_CONFIG_FILE}" ]; then
    sed -e 's/password=.*/password=***REDACTED***/' "${PG_CONFIG_FILE}" || printf '%s\n' "(unable to display redacted config)"
  fi
}

# --- Frontend TLS config helpers (automatic CapRover behavior) ---

# Append the initial frontend TLS block during config generation.
# Automatic prepared/active -> require + runtime paths. Manual ->
# preserved native CLIENT_TLS_* lines. Otherwise explicit disable
# (equivalent to default).
write_frontend_tls_block() {
  if [ "${FRONTEND_TLS_ACTIVE}" = "1" ]; then
    printf 'client_tls_sslmode = require\n' >> "${PG_CONFIG_FILE}"
    printf 'client_tls_cert_file = %s\n' "${TLS_RUNTIME_CERT}" >> "${PG_CONFIG_FILE}"
    printf 'client_tls_key_file = %s\n' "${TLS_RUNTIME_KEY}" >> "${PG_CONFIG_FILE}"
    # Optional hardening extras may accompany automatic TLS.
    if [ -n "${CLIENT_TLS_CA_FILE:-}" ]; then
      printf 'client_tls_ca_file = %s\n' "${CLIENT_TLS_CA_FILE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_PROTOCOLS:-}" ]; then
      printf 'client_tls_protocols = %s\n' "${CLIENT_TLS_PROTOCOLS}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_CIPHERS:-}" ]; then
      printf 'client_tls_ciphers = %s\n' "${CLIENT_TLS_CIPHERS}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_ECDHCURVE:-}" ]; then
      printf 'client_tls_ecdhcurve = %s\n' "${CLIENT_TLS_ECDHCURVE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_DHEPARAMS:-}" ]; then
      printf 'client_tls_dheparams = %s\n' "${CLIENT_TLS_DHEPARAMS}" >> "${PG_CONFIG_FILE}"
    fi
    return 0
  fi
  if [ "${MANUAL_FRONTEND_TLS}" = "1" ]; then
    if [ -n "${CLIENT_TLS_SSLMODE:-}" ]; then
      printf 'client_tls_sslmode = %s\n' "${CLIENT_TLS_SSLMODE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_KEY_FILE:-}" ]; then
      printf 'client_tls_key_file = %s\n' "${CLIENT_TLS_KEY_FILE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_CERT_FILE:-}" ]; then
      printf 'client_tls_cert_file = %s\n' "${CLIENT_TLS_CERT_FILE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_CA_FILE:-}" ]; then
      printf 'client_tls_ca_file = %s\n' "${CLIENT_TLS_CA_FILE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_PROTOCOLS:-}" ]; then
      printf 'client_tls_protocols = %s\n' "${CLIENT_TLS_PROTOCOLS}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_CIPHERS:-}" ]; then
      printf 'client_tls_ciphers = %s\n' "${CLIENT_TLS_CIPHERS}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_ECDHCURVE:-}" ]; then
      printf 'client_tls_ecdhcurve = %s\n' "${CLIENT_TLS_ECDHCURVE}" >> "${PG_CONFIG_FILE}"
    fi
    if [ -n "${CLIENT_TLS_DHEPARAMS:-}" ]; then
      printf 'client_tls_dheparams = %s\n' "${CLIENT_TLS_DHEPARAMS}" >> "${PG_CONFIG_FILE}"
    fi
    return 0
  fi
  # No TLS: explicit disable so plaintext behavior is intentional.
  printf 'client_tls_sslmode = disable\n' >> "${PG_CONFIG_FILE}"
}

# Rewrite an existing generated config to require automatic TLS.
# Used by the watcher for activation and renewal paths.
# Removes prior client_tls_sslmode/cert/key lines, appends require block.
# Atomic via temp file + mv. Preserves all other settings. Keeps a
# best-effort backup of the previous config for recoverability.
# Honors the test-only fault flags to simulate a rewrite failure or a
# PgBouncer-rejected TLS setting (sentinel protocols value).
update_config_tls_to_require() {
  if [ -f "${TLS_FAIL_CONFIG_UPDATE_FILE:-/run/pgbouncer/.fail-tls-config-update}" ]; then
    return 1
  fi
  _u_tmp="${PG_CONFIG_FILE}.tls.tmp.$$"
  rm -f "${_u_tmp}" 2>/dev/null || true
  cp -f "${PG_CONFIG_FILE}" "${PG_CONFIG_FILE}.prev" 2>/dev/null || true
  # Strip prior frontend identity lines (sslmode/cert/key only; keep
  # CA/protocols/ciphers extras which are re-appended from env below).
  # The test-only rejected-protocols sentinel is always stripped here and
  # re-added below only while its fault flag is present, so healing the
  # flag heals the config on the next rewrite.
  grep -v -E '^[[:space:]]*client_tls_(sslmode|cert_file|key_file)[[:space:]]*=' "${PG_CONFIG_FILE}" 2>/dev/null | grep -v -F "${TLS_FAIL_PROTOCOLS_SENTINEL:-bogusproto-pgpooler-test}" > "${_u_tmp}" 2>/dev/null || return 1
  {
    printf 'client_tls_sslmode = require\n'
    printf 'client_tls_cert_file = %s\n' "${TLS_RUNTIME_CERT}"
    printf 'client_tls_key_file = %s\n' "${TLS_RUNTIME_KEY}"
    if [ -n "${CLIENT_TLS_CA_FILE:-}" ]; then
      # Avoid duplicating an existing ca line already preserved above.
      if ! grep -q -E '^[[:space:]]*client_tls_ca_file[[:space:]]*=' "${_u_tmp}" 2>/dev/null; then
        printf 'client_tls_ca_file = %s\n' "${CLIENT_TLS_CA_FILE}"
      fi
    fi
    if [ -n "${CLIENT_TLS_PROTOCOLS:-}" ]; then
      if ! grep -q -E '^[[:space:]]*client_tls_protocols[[:space:]]*=' "${_u_tmp}" 2>/dev/null; then
        printf 'client_tls_protocols = %s\n' "${CLIENT_TLS_PROTOCOLS}"
      fi
    fi
    if [ -n "${CLIENT_TLS_CIPHERS:-}" ]; then
      if ! grep -q -E '^[[:space:]]*client_tls_ciphers[[:space:]]*=' "${_u_tmp}" 2>/dev/null; then
        printf 'client_tls_ciphers = %s\n' "${CLIENT_TLS_CIPHERS}"
      fi
    fi
    if [ -n "${CLIENT_TLS_ECDHCURVE:-}" ]; then
      if ! grep -q -E '^[[:space:]]*client_tls_ecdhcurve[[:space:]]*=' "${_u_tmp}" 2>/dev/null; then
        printf 'client_tls_ecdhcurve = %s\n' "${CLIENT_TLS_ECDHCURVE}"
      fi
    fi
    if [ -n "${CLIENT_TLS_DHEPARAMS:-}" ]; then
      if ! grep -q -E '^[[:space:]]*client_tls_dheparams[[:space:]]*=' "${_u_tmp}" 2>/dev/null; then
        printf 'client_tls_dheparams = %s\n' "${CLIENT_TLS_DHEPARAMS}"
      fi
    fi
  } >> "${_u_tmp}" || return 1
  # Test-only rejected setting: deterministically rejected by PgBouncer at
  # RELOAD while the previous TLS context is kept (verified live).
  if [ -f "${TLS_FAIL_PROTOCOLS_FILE:-/run/pgbouncer/.fail-tls-protocols}" ]; then
    printf 'client_tls_protocols = %s\n' "${TLS_FAIL_PROTOCOLS_SENTINEL:-bogusproto-pgpooler-test}" >> "${_u_tmp}" || return 1
  fi
  chmod 0600 "${_u_tmp}" 2>/dev/null || true
  if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${_u_tmp}" 2>/dev/null || true
  fi
  mv -f "${_u_tmp}" "${PG_CONFIG_FILE}" 2>/dev/null || return 1
  chmod 0600 "${PG_CONFIG_FILE}" 2>/dev/null || true
  return 0
}

# Rewrite a generated config back to explicit plaintext frontend TLS.
# Used only as a fail-safe when a tentative prefer activation cannot be
# verified: the running PgBouncer still serves plaintext, so the on-disk
# config is realigned with reality instead of claiming require.
# Atomic via temp file + mv. Preserves all other settings.
downgrade_config_tls_to_disable() {
  _d_tmp="${PG_CONFIG_FILE}.tls.tmp.$$"
  rm -f "${_d_tmp}" 2>/dev/null || true
  cp -f "${PG_CONFIG_FILE}" "${PG_CONFIG_FILE}.prev" 2>/dev/null || true
  grep -v -E '^[[:space:]]*client_tls_(sslmode|cert_file|key_file)[[:space:]]*=' "${PG_CONFIG_FILE}" 2>/dev/null | grep -v -F "${TLS_FAIL_PROTOCOLS_SENTINEL:-bogusproto-pgpooler-test}" > "${_d_tmp}" 2>/dev/null || return 1
  printf 'client_tls_sslmode = disable\n' >> "${_d_tmp}" || return 1
  chmod 0600 "${_d_tmp}" 2>/dev/null || true
  if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${_d_tmp}" 2>/dev/null || true
  fi
  mv -f "${_d_tmp}" "${PG_CONFIG_FILE}" 2>/dev/null || return 1
  chmod 0600 "${PG_CONFIG_FILE}" 2>/dev/null || true
  return 0
}

# Persist supervisor state for the healthcheck and UI.
write_state_file() {
  mkdir -p "$(dirname "${PGPOOLER_STATE_FILE}")" 2>/dev/null || true
  {
    printf 'TLS_STATE=%s\n' "${FRONTEND_TLS_STATE}"
    if [ "${EXPECT_PGBOUNCER}" = "0" ]; then
      printf 'EXPECT_PGBOUNCER=0\n'
    else
      printf 'EXPECT_PGBOUNCER=1\n'
    fi
  } > "${PGPOOLER_STATE_FILE}.tmp" 2>/dev/null || return 1
  mv -f "${PGPOOLER_STATE_FILE}.tmp" "${PGPOOLER_STATE_FILE}" 2>/dev/null || return 1
  chmod 0644 "${PGPOOLER_STATE_FILE}" 2>/dev/null || true
  return 0
}

# Resolve the database name for UI display without mutating global DB_*.
# Prefers explicit DB_NAME, then first DATABASE_URL(S) entry, else "*".
resolve_display_db() {
  # Capture explicit env before parsing overwrote it is handled by caller
  # via _ORIG_DB_NAME; fall back to current DB_NAME.
  if [ -n "${_ORIG_DB_NAME:-}" ]; then
    printf '%s' "${_ORIG_DB_NAME}"
    return 0
  fi
  if [ -n "${DB_NAME:-}" ]; then
    printf '%s' "${DB_NAME}"
    return 0
  fi
  printf '*'
}

# Render the documentation UI for the current FRONTEND_TLS_STATE.
render_ui() {
  _r_port="${LISTEN_PORT:-5432}"
  _r_db=$(resolve_display_db)
  if command -v generate_ui_page >/dev/null 2>&1; then
    generate_ui_page "${FRONTEND_TLS_STATE}" "${PUBLIC_HOST_SANITIZED}" "${_r_port}" "${_r_db}" "${WWW_FILE}" || true
  fi
  # UI files contain no secrets: world-readable is safe.
  chmod 0644 "${WWW_FILE}" 2>/dev/null || true
}

# Remember explicit DB_NAME before URL parsing overwrites it.
_ORIG_DB_NAME="${DB_NAME:-}"

# Write the password with MD5 encryption, to avoid printing it during startup.
# Notice that `docker inspect` will show unencrypted env variables.
# NOTE: comma-separated iteration runs in the main shell (no pipe subshell)
# so that validation failures correctly abort startup.
# In split mode backend users are NOT added to auth_file; only the
# frontend credential is added once after parsing.
if [ -n "${DATABASE_URLS:-}" ]; then
  _urls_rest="${DATABASE_URLS},"
  while [ -n "${_urls_rest}" ]; do
    _cur_url="${_urls_rest%%,*}"
    case "${_urls_rest}" in
      *,*) _urls_rest="${_urls_rest#*,}" ;;
      *) _urls_rest="" ;;
    esac
    if [ -z "${_cur_url}" ]; then
      continue
    fi
    parse_url "${_cur_url}"
    require_valid_db_name "${DB_NAME:-}" "DATABASE_URLS entry"
    generate_userlist_if_needed
  done
  ensure_frontend_auth
else
  if [ -n "${DATABASE_URL:-}" ]; then
    parse_url "${DATABASE_URL}"
  fi
  require_valid_db_name "${DB_NAME:-}" "single-upstream DB_NAME/DATABASE_URL"
  generate_userlist_if_needed
  ensure_frontend_auth
fi

# Detect a pre-existing custom config before we generate one.
# A config carrying our generation marker is ours (e.g. left behind by a
# normal `docker restart` of this same container filesystem) and is
# regenerated deterministically below; only a file WITHOUT the marker
# counts as a user custom/mounted config. A marker-owned file that cannot
# be removed (e.g. a read-only single-file mount) cannot be regenerated,
# so automatic TLS refuses it clearly instead of misbehaving.
_GENERATED_MARKER="# Generated by PgPoolito - do not edit inside the container"
_CUSTOM_CONFIG=0
if [ -f "${PG_CONFIG_FILE}" ]; then
  if grep -q '^# Generated by PgPoolito' "${PG_CONFIG_FILE}" 2>/dev/null; then
    _CUSTOM_CONFIG=0
    rm -f "${PG_CONFIG_FILE}" 2>/dev/null || true
    if [ -f "${PG_CONFIG_FILE}" ]; then
      if [ "${AUTO_TLS_CANDIDATE}" = "1" ]; then
        echo "error: automatic CapRover TLS (PUBLIC_HOST=${PUBLIC_HOST_SANITIZED}) needs to regenerate ${PG_CONFIG_FILE}, but the owned file cannot be regenerated (read-only mount?). Mount the directory read-write, remove the mount, or unset PUBLIC_HOST to use manual CLIENT_TLS_* settings." >&2
        exit 1
      fi
      _CUSTOM_CONFIG=1
    fi
  else
    _CUSTOM_CONFIG=1
  fi
fi
if [ "${_CUSTOM_CONFIG}" = "1" ] && [ "${AUTO_TLS_CANDIDATE}" = "1" ]; then
  echo "error: automatic CapRover TLS (PUBLIC_HOST=${PUBLIC_HOST_SANITIZED}) requires the generated pgbouncer.ini; a custom mounted config is present. Remove the custom mount to use automatic TLS, or unset PUBLIC_HOST to use manual CLIENT_TLS_* settings." >&2
  exit 1
fi

# Initial automatic TLS bootstrap (privileged: reads read-only source tree,
# validates with OpenSSL, installs private runtime copies). No secrets logged.
# A successful install is still tentative: it publishes `prepared` (config
# ready, endpoint not yet verified), never `active`. The version counts as
# applied only after PgBouncer is started and the live endpoint is
# externally verified below (fail-closed).
_BOOT_TLS_CERT=""
_BOOT_TLS_KEY=""
_BOOT_PREPARED=0
if [ "${AUTO_TLS_CANDIDATE}" = "1" ]; then
  _SRC_CERT="${CAPROVER_BASE}/live/${PUBLIC_HOST_SANITIZED}/fullchain.pem"
  _SRC_KEY="${CAPROVER_BASE}/live/${PUBLIC_HOST_SANITIZED}/privkey.pem"
  if command -v validate_caprover_cert >/dev/null 2>&1; then
    if validate_caprover_cert "${_SRC_CERT}" "${_SRC_KEY}" "${PUBLIC_HOST_SANITIZED}"; then
      if install_runtime_cert "${_SRC_CERT}" "${_SRC_KEY}"; then
        FRONTEND_TLS_ACTIVE=1
        FRONTEND_TLS_STATE="prepared"
        _BOOT_TLS_CERT="${_SRC_CERT}"
        _BOOT_TLS_KEY="${_SRC_KEY}"
        echo "Valid certificate detected for ${PUBLIC_HOST_SANITIZED}; preparing frontend TLS" >&2
      else
        echo "TLS setup: failed to install runtime certificate for ${PUBLIC_HOST_SANITIZED}." >&2
        if [ "${PGPOOLER_SSL_MODE}" = "required" ]; then
          FRONTEND_TLS_ACTIVE=0
          FRONTEND_TLS_STATE="waiting"
        else
          FRONTEND_TLS_ACTIVE=0
          FRONTEND_TLS_STATE="plaintext"
        fi
      fi
    else
      clear_runtime_cert_files || true
      if [ "${PGPOOLER_SSL_MODE}" = "required" ]; then
        FRONTEND_TLS_ACTIVE=0
        FRONTEND_TLS_STATE="waiting"
        echo "Frontend TLS policy requires a certificate; waiting before starting PgBouncer" >&2
      else
        FRONTEND_TLS_ACTIVE=0
        FRONTEND_TLS_STATE="plaintext"
        echo "Frontend TLS policy: prefer" >&2
        echo "No valid certificate for ${PUBLIC_HOST_SANITIZED}; starting PgBouncer without frontend TLS" >&2
      fi
    fi
  else
    # Helper lib missing: cannot validate safely.
    clear_runtime_cert_files || true
    if [ "${PGPOOLER_SSL_MODE}" = "required" ]; then
      FRONTEND_TLS_ACTIVE=0
      FRONTEND_TLS_STATE="waiting"
      echo "Frontend TLS policy requires a certificate; waiting before starting PgBouncer" >&2
    else
      FRONTEND_TLS_ACTIVE=0
      FRONTEND_TLS_STATE="plaintext"
      echo "Frontend TLS policy: prefer" >&2
      echo "No valid certificate for ${PUBLIC_HOST_SANITIZED}; starting PgBouncer without frontend TLS" >&2
    fi
  fi
else
  # No automatic candidate: disabled, manual, or plaintext default.
  if [ "${PGPOOLER_SSL_MODE}" = "disabled" ]; then
    FRONTEND_TLS_ACTIVE=0
    FRONTEND_TLS_STATE="disabled"
    echo "Frontend TLS policy: disabled" >&2
  elif [ "${MANUAL_FRONTEND_TLS}" = "1" ]; then
    FRONTEND_TLS_ACTIVE=0
    case "${CLIENT_TLS_SSLMODE:-}" in
      require|verify-ca|verify-full)
        FRONTEND_TLS_STATE="manual-require"
        ;;
      *)
        FRONTEND_TLS_STATE="manual"
        ;;
    esac
    echo "Frontend TLS: manual configuration in use" >&2
  else
    FRONTEND_TLS_ACTIVE=0
    FRONTEND_TLS_STATE="plaintext"
    if [ -n "${PUBLIC_HOST_SANITIZED}" ]; then
      echo "Frontend TLS policy: prefer" >&2
      echo "No valid certificate for ${PUBLIC_HOST_SANITIZED}; starting PgBouncer without frontend TLS" >&2
    else
      echo "Frontend TLS policy: prefer (no PUBLIC_HOST; automatic TLS inactive)" >&2
    fi
  fi
fi

if [ "${FRONTEND_TLS_STATE}" = "waiting" ]; then
  EXPECT_PGBOUNCER=0
else
  EXPECT_PGBOUNCER=1
fi

if [ ! -f "${PG_CONFIG_FILE}" ]; then
  echo "Creating pgbouncer config in ${PG_CONFIG_DIR}"

  # Config file is in "ini" format. Section names are between "[" and "]".
  # Lines starting with ";" or "#" are taken as comments and ignored.
  # The characters ";" and "#" are not recognized when they appear later in the line.
  printf "\
%s\n\
################## Auto generated ##################
[databases]
" "${_GENERATED_MARKER}" > "${PG_CONFIG_FILE}"

  if [ -n "${DATABASE_URLS:-}" ]; then
    _urls_rest="${DATABASE_URLS},"
    while [ -n "${_urls_rest}" ]; do
      _cur_url="${_urls_rest%%,*}"
      case "${_urls_rest}" in
        *,*) _urls_rest="${_urls_rest#*,}" ;;
        *) _urls_rest="" ;;
      esac
      if [ -z "${_cur_url}" ]; then
        continue
      fi
      parse_url "${_cur_url}"
      require_valid_db_name "${DB_NAME:-}" "DATABASE_URLS entry"
      generate_config_db_entry
    done
  else
    if [ -n "${DATABASE_URL:-}" ]; then
      parse_url "${DATABASE_URL}"
    fi
    require_valid_db_name "${DB_NAME:-}" "single-upstream DB_NAME/DATABASE_URL"
    generate_config_db_entry
  fi

  printf "\
[pgbouncer]
listen_addr = ${LISTEN_ADDR:-0.0.0.0}
listen_port = ${LISTEN_PORT:-5432}
unix_socket_dir = ${UNIX_SOCKET_DIR}
user = postgres
auth_file = ${_AUTH_FILE}
${AUTH_HBA_FILE:+auth_hba_file = ${AUTH_HBA_FILE}\n}\
auth_type = ${AUTH_TYPE:-md5}
${AUTH_USER:+auth_user = ${AUTH_USER}\n}\
${AUTH_QUERY:+auth_query = ${AUTH_QUERY}\n}\
${AUTH_DBNAME:+auth_dbname = ${AUTH_DBNAME}\n}\
${POOL_MODE:+pool_mode = ${POOL_MODE}\n}\
${MAX_CLIENT_CONN:+max_client_conn = ${MAX_CLIENT_CONN}\n}\
${POOL_SIZE:+pool_size = ${POOL_SIZE}\n}\
${DEFAULT_POOL_SIZE:+default_pool_size = ${DEFAULT_POOL_SIZE}\n}\
${MIN_POOL_SIZE:+min_pool_size = ${MIN_POOL_SIZE}\n}\
${RESERVE_POOL_SIZE:+reserve_pool_size = ${RESERVE_POOL_SIZE}\n}\
${RESERVE_POOL_TIMEOUT:+reserve_pool_timeout = ${RESERVE_POOL_TIMEOUT}\n}\
${MAX_DB_CONNECTIONS:+max_db_connections = ${MAX_DB_CONNECTIONS}\n}\
${MAX_USER_CONNECTIONS:+max_user_connections = ${MAX_USER_CONNECTIONS}\n}\
${SERVER_ROUND_ROBIN:+server_round_robin = ${SERVER_ROUND_ROBIN}\n}\
ignore_startup_parameters = ${IGNORE_STARTUP_PARAMETERS:-extra_float_digits}
${DISABLE_PQEXEC:+disable_pqexec = ${DISABLE_PQEXEC}\n}\
${APPLICATION_NAME_ADD_HOST:+application_name_add_host = ${APPLICATION_NAME_ADD_HOST}\n}\
${TIMEZONE:+timezone = ${TIMEZONE}\n}\
${MAX_PREPARED_STATEMENTS:+max_prepared_statements = ${MAX_PREPARED_STATEMENTS}\n}\

# Log settings
${LOG_CONNECTIONS:+log_connections = ${LOG_CONNECTIONS}\n}\
${LOG_DISCONNECTIONS:+log_disconnections = ${LOG_DISCONNECTIONS}\n}\
${LOG_POOLER_ERRORS:+log_pooler_errors = ${LOG_POOLER_ERRORS}\n}\
${LOG_STATS:+log_stats = ${LOG_STATS}\n}\
${STATS_PERIOD:+stats_period = ${STATS_PERIOD}\n}\
${VERBOSE:+verbose = ${VERBOSE}\n}\
admin_users = ${ADMIN_USERS:-postgres}
${STATS_USERS:+stats_users = ${STATS_USERS}\n}\
${LOGFILE:+logfile = ${LOGFILE}\n}\n

# Connection sanity checks, timeouts
${SERVER_RESET_QUERY:+server_reset_query = ${SERVER_RESET_QUERY}\n}\
${SERVER_RESET_QUERY_ALWAYS:+server_reset_query_always = ${SERVER_RESET_QUERY_ALWAYS}\n}\
${SERVER_CHECK_DELAY:+server_check_delay = ${SERVER_CHECK_DELAY}\n}\
${SERVER_CHECK_QUERY:+server_check_query = ${SERVER_CHECK_QUERY}\n}\
${SERVER_LIFETIME:+server_lifetime = ${SERVER_LIFETIME}\n}\
${SERVER_IDLE_TIMEOUT:+server_idle_timeout = ${SERVER_IDLE_TIMEOUT}\n}\
${SERVER_CONNECT_TIMEOUT:+server_connect_timeout = ${SERVER_CONNECT_TIMEOUT}\n}\
${SERVER_LOGIN_RETRY:+server_login_retry = ${SERVER_LOGIN_RETRY}\n}\
${CLIENT_LOGIN_TIMEOUT:+client_login_timeout = ${CLIENT_LOGIN_TIMEOUT}\n}\
${AUTODB_IDLE_TIMEOUT:+autodb_idle_timeout = ${AUTODB_IDLE_TIMEOUT}\n}\
${DNS_MAX_TTL:+dns_max_ttl = ${DNS_MAX_TTL}\n}\
${DNS_NXDOMAIN_TTL:+dns_nxdomain_ttl = ${DNS_NXDOMAIN_TTL}\n}\

# TLS settings
" >> "${PG_CONFIG_FILE}"
  # Frontend TLS block: automatic require, manual passthrough, or disable.
  write_frontend_tls_block
  printf "\
${SERVER_TLS_SSLMODE:+server_tls_sslmode = ${SERVER_TLS_SSLMODE}\n}\
${SERVER_TLS_CA_FILE:+server_tls_ca_file = ${SERVER_TLS_CA_FILE}\n}\
${SERVER_TLS_KEY_FILE:+server_tls_key_file = ${SERVER_TLS_KEY_FILE}\n}\
${SERVER_TLS_CERT_FILE:+server_tls_cert_file = ${SERVER_TLS_CERT_FILE}\n}\
${SERVER_TLS_PROTOCOLS:+server_tls_protocols = ${SERVER_TLS_PROTOCOLS}\n}\
${SERVER_TLS_CIPHERS:+server_tls_ciphers = ${SERVER_TLS_CIPHERS}\n}\

# Dangerous timeouts
${QUERY_TIMEOUT:+query_timeout = ${QUERY_TIMEOUT}\n}\
${QUERY_WAIT_TIMEOUT:+query_wait_timeout = ${QUERY_WAIT_TIMEOUT}\n}\
${CLIENT_IDLE_TIMEOUT:+client_idle_timeout = ${CLIENT_IDLE_TIMEOUT}\n}\
${IDLE_TRANSACTION_TIMEOUT:+idle_transaction_timeout = ${IDLE_TRANSACTION_TIMEOUT}\n}\
${PKT_BUF:+pkt_buf = ${PKT_BUF}\n}\
${MAX_PACKET_SIZE:+max_packet_size = ${MAX_PACKET_SIZE}\n}\
${LISTEN_BACKLOG:+listen_backlog = ${LISTEN_BACKLOG}\n}\
${SBUF_LOOPCNT:+sbuf_loopcnt = ${SBUF_LOOPCNT}\n}\
${SUSPEND_TIMEOUT:+suspend_timeout = ${SUSPEND_TIMEOUT}\n}\
${TCP_DEFER_ACCEPT:+tcp_defer_accept = ${TCP_DEFER_ACCEPT}\n}\
${TCP_KEEPALIVE:+tcp_keepalive = ${TCP_KEEPALIVE}\n}\
${TCP_KEEPCNT:+tcp_keepcnt = ${TCP_KEEPCNT}\n}\
${TCP_KEEPIDLE:+tcp_keepidle = ${TCP_KEEPIDLE}\n}\
${TCP_KEEPINTVL:+tcp_keepintvl = ${TCP_KEEPINTVL}\n}\
${TCP_USER_TIMEOUT:+tcp_user_timeout = ${TCP_USER_TIMEOUT}\n}\
################## end file ##################
" >> "${PG_CONFIG_FILE}"
  chmod 0600 "${PG_CONFIG_FILE}" 2>/dev/null || true
  if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${PG_CONFIG_FILE}" 2>/dev/null || true
  fi
  print_config_redacted
fi

# Ensure restrictive permissions on generated files (may already exist).
chmod 0600 "${PG_CONFIG_FILE}" 2>/dev/null || true
chmod 0600 "${_AUTH_FILE}" 2>/dev/null || true
if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
  chown postgres:postgres "${PG_CONFIG_FILE}" "${_AUTH_FILE}" 2>/dev/null || true
fi
if [ -f "${TLS_RUNTIME_CERT}" ]; then
  chmod 0600 "${TLS_RUNTIME_CERT}" 2>/dev/null || true
fi
if [ -f "${TLS_RUNTIME_KEY}" ]; then
  chmod 0600 "${TLS_RUNTIME_KEY}" 2>/dev/null || true
fi

# Fail-closed confirmation for a tentative boot-time preparation: the
# generated config must literally carry the automatic TLS identity before
# the container may proceed as `prepared`. The version counts as applied
# only later, after PgBouncer is started and the live endpoint is
# externally verified. Only then may state become `active`.
if [ "${FRONTEND_TLS_STATE}" = "prepared" ] && [ -n "${_BOOT_TLS_CERT}" ]; then
  if command -v verify_automatic_tls_config >/dev/null 2>&1 && \
     verify_automatic_tls_config "${PG_CONFIG_FILE}" "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null; then
    _BOOT_PREPARED=1
  else
    echo "TLS setup: generated config failed verification for ${PUBLIC_HOST_SANITIZED}; not preparing frontend TLS." >&2
    _BOOT_TLS_CERT=""
    _BOOT_TLS_KEY=""
    if [ "${PGPOOLER_SSL_MODE}" = "required" ]; then
      FRONTEND_TLS_ACTIVE=0
      FRONTEND_TLS_STATE="waiting"
      EXPECT_PGBOUNCER=0
    else
      FRONTEND_TLS_ACTIVE=0
      FRONTEND_TLS_STATE="plaintext"
      EXPECT_PGBOUNCER=1
      downgrade_config_tls_to_disable || true
    fi
  fi
fi

# Publish supervisor state + documentation UI before process startup.
write_state_file || true
mkdir -p "${WWW_DIR}" 2>/dev/null || true
render_ui || true
if [ "$(id -u 2>/dev/null || printf '0')" = "0" ] && id postgres >/dev/null 2>&1; then
  chown -R postgres:postgres "${WWW_DIR}" 2>/dev/null || true
  if [ -d "${TLS_RUNTIME_DIR}" ]; then
    chown -R postgres:postgres "${TLS_RUNTIME_DIR}" 2>/dev/null || true
    chmod 0700 "${TLS_RUNTIME_DIR}" 2>/dev/null || true
    chmod 0600 "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null || true
  fi
fi

# Compatibility path: config/auth inspection commands (used by tests and
# custom tooling) keep the historical generate-then-exec behavior without
# starting the HTTP UI, PgBouncer supervisor, or certificate watcher.
# The normal container CMD starts /usr/bin/pgbouncer.
_IS_PGBOUNCER_CMD=0
case "${1:-}" in
  *pgbouncer*) _IS_PGBOUNCER_CMD=1 ;;
esac
if [ "${_IS_PGBOUNCER_CMD}" = "0" ]; then
  echo "Starting $*..."
  exec "$@"
fi

# --- Supervised runtime (PID 1): HTTP UI + PgBouncer + cert watcher ---
# PgBouncer itself always runs unprivileged as postgres via su-exec.
# The privileged parent only handles cert install, config updates, UI
# refresh, watcher polling, and signal forwarding. No eval, no secrets.

HTTPD_PID=""
PGBOUNCER_PID=""
WATCHER_PID=""
_SHUTDOWN=0

cleanup_children() {
  _sig="${1:-TERM}"
  if [ -n "${WATCHER_PID}" ]; then
    kill "${_sig}" "${WATCHER_PID}" 2>/dev/null || true
  fi
  if [ -n "${PGBOUNCER_PID}" ]; then
    kill "${_sig}" "${PGBOUNCER_PID}" 2>/dev/null || true
  fi
  if [ -n "${HTTPD_PID}" ]; then
    kill "${_sig}" "${HTTPD_PID}" 2>/dev/null || true
  fi
}

handle_term() {
  if [ "${_SHUTDOWN}" = "1" ]; then
    return 0
  fi
  _SHUTDOWN=1
  cleanup_children TERM
}

handle_hup() {
  # Forward reload to PgBouncer when running.
  if [ -n "${PGBOUNCER_PID}" ]; then
    kill -HUP "${PGBOUNCER_PID}" 2>/dev/null || true
  fi
}

trap 'handle_term' TERM INT
trap 'handle_hup' HUP

start_httpd() {
  mkdir -p "${WWW_DIR}" 2>/dev/null || true
  if [ ! -f "${WWW_FILE}" ]; then
    render_ui || true
  fi
  # Prefer busybox-extras httpd (tiny). Fall back to busybox httpd.
  if command -v busybox-extras >/dev/null 2>&1; then
    if id postgres >/dev/null 2>&1 && command -v su-exec >/dev/null 2>&1; then
      su-exec postgres busybox-extras httpd -f -p "${HTTP_PORT}" -h "${WWW_DIR}" &
    else
      busybox-extras httpd -f -p "${HTTP_PORT}" -h "${WWW_DIR}" &
    fi
    HTTPD_PID="$!"
    return 0
  fi
  if command -v httpd >/dev/null 2>&1; then
    if id postgres >/dev/null 2>&1 && command -v su-exec >/dev/null 2>&1; then
      su-exec postgres httpd -f -p "${HTTP_PORT}" -h "${WWW_DIR}" &
    else
      httpd -f -p "${HTTP_PORT}" -h "${WWW_DIR}" &
    fi
    HTTPD_PID="$!"
    return 0
  fi
  echo "warning: no httpd implementation found; documentation UI unavailable." >&2
  HTTPD_PID=""
  return 0
}

start_pgbouncer() {
  # Drop privileges: PgBouncer never runs as root.
  if id postgres >/dev/null 2>&1 && command -v su-exec >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    su-exec postgres "$@" &
  else
    # shellcheck disable=SC2086
    "$@" &
  fi
  PGBOUNCER_PID="$!"
  printf '%s' "${PGBOUNCER_PID}" > "${PGBOUNCER_PID_FILE}.tmp" 2>/dev/null || true
  mv -f "${PGBOUNCER_PID_FILE}.tmp" "${PGBOUNCER_PID_FILE}" 2>/dev/null || true
  echo "Starting $* (pid ${PGBOUNCER_PID})..." >&2
}

# Deliver SIGHUP to the supervised PgBouncer via the pid file (usable
# from the watcher subshell). Returns nonzero when delivery fails, in
# which case no successful reload may be assumed by the caller.
_deliver_sighup_to_pgbouncer() {
  _r_pid=""
  if [ -f "${PGBOUNCER_PID_FILE}" ]; then
    _r_pid=$(tr -d ' \n' < "${PGBOUNCER_PID_FILE}" 2>/dev/null || printf '')
  fi
  if [ -z "${_r_pid}" ] && [ -n "${PGBOUNCER_PID:-}" ]; then
    _r_pid="${PGBOUNCER_PID}"
  fi
  case "${_r_pid}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if kill -0 "${_r_pid}" 2>/dev/null; then
    kill -HUP "${_r_pid}" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

# SIGHUP PgBouncer for activation/renewal. Honors the test-only fault
# flag to simulate a reload failure for fail-closed retry tests.
reload_pgbouncer() {
  if [ -f "${TLS_FAIL_RELOAD_FILE:-/run/pgbouncer/.fail-tls-reload}" ]; then
    return 1
  fi
  _deliver_sighup_to_pgbouncer
}

# SIGHUP PgBouncer for an explicit rollback reload. Honors a separate
# test-only fault flag so rollback delivery failure is independently
# deterministic from forward reload failure.
reload_pgbouncer_rollback() {
  if [ -f "${TLS_FAIL_ROLLBACK_FILE:-/run/pgbouncer/.fail-tls-rollback}" ]; then
    return 1
  fi
  _deliver_sighup_to_pgbouncer
}

# Stop this container after an unverifiable rollback: kill the supervised
# PgBouncer (if any) so the supervisor exits nonzero instead of serving
# or advertising a state that was never externally verified. Never
# publishes any state itself.
abort_container_after_unverified_rollback() {
  _k_pid=""
  if [ -f "${PGBOUNCER_PID_FILE}" ]; then
    _k_pid=$(tr -d ' \n' < "${PGBOUNCER_PID_FILE}" 2>/dev/null || printf '')
  fi
  case "${_k_pid}" in
    ''|*[!0-9]*) _k_pid="" ;;
  esac
  if [ -n "${_k_pid}" ] && kill -0 "${_k_pid}" 2>/dev/null; then
    kill -TERM "${_k_pid}" 2>/dev/null || true
  else
    kill -TERM 1 2>/dev/null || true
  fi
  return 0
}

# Confirm a prefer rollback: the process is alive and the endpoint serves
# no candidate certificate (plaintext again). Raw observation, never
# fault-flaggable: this is the ground truth the rollback claims.
# Args: port host. Bounded retries for the async reload to settle.
confirm_plaintext_rollback() {
  _c_port="${1:-5432}"
  _c_host="${2:-localhost}"
  _c_try=0
  while [ "${_c_try}" -lt 4 ]; do
    if pgbouncer_pid_alive; then
      _c_served=""
      _c_served=$(served_frontend_leaf_fp "${_c_port}" "${_c_host}" 2>/dev/null || printf '')
      if [ -z "${_c_served}" ]; then
        return 0
      fi
    fi
    sleep 1 2>/dev/null || true
    _c_try=$((_c_try + 1))
  done
  return 1
}

# Confirm a renewal rollback: the process is alive and the endpoint
# serves the restored runtime leaf again. Raw observation, never
# fault-flaggable. Args: port host. Bounded retries for settle.
confirm_renewal_rollback() {
  _rr_port="${1:-5432}"
  _rr_host="${2:-localhost}"
  _rr_try=0
  while [ "${_rr_try}" -lt 4 ]; do
    if pgbouncer_pid_alive; then
      _rr_expected=""
      _rr_expected=$(runtime_leaf_fingerprint "${TLS_RUNTIME_CERT}" 2>/dev/null || printf '')
      _rr_served=""
      _rr_served=$(served_frontend_leaf_fp "${_rr_port}" "${_rr_host}" 2>/dev/null || printf '')
      if [ -n "${_rr_expected}" ] && [ -n "${_rr_served}" ] && [ "${_rr_served}" = "${_rr_expected}" ]; then
        return 0
      fi
    fi
    sleep 1 2>/dev/null || true
    _rr_try=$((_rr_try + 1))
  done
  return 1
}

# Roll back an ambiguous prefer activation to confirmed plaintext:
# realign config to disable, verify it, reload, and confirm the endpoint
# no longer serves the candidate. Returns 0 only on confirmed rollback.
rollback_prefer_to_plaintext() {
  _rp_port="${1:-5432}"
  _rp_host="${2:-localhost}"
  downgrade_config_tls_to_disable || return 1
  verify_frontend_tls_disabled_config "${PG_CONFIG_FILE}" 2>/dev/null || return 1
  reload_pgbouncer_rollback || return 1
  confirm_plaintext_rollback "${_rp_port}" "${_rp_host}" || return 1
  return 0
}

# Roll back an ambiguous renewal to the restored previous pair:
# reload the restored files and confirm the endpoint serves them again.
# Returns 0 only on confirmed rollback. Call only after
# restore_runtime_cert_backup.
rollback_renewal_to_previous() {
  _rn_port="${1:-5432}"
  _rn_host="${2:-localhost}"
  reload_pgbouncer_rollback || return 1
  confirm_renewal_rollback "${_rn_port}" "${_rn_host}" || return 1
  return 0
}

# True when the supervised PgBouncer process (pid file) is alive.
pgbouncer_pid_alive() {
  _a_pid=""
  if [ -f "${PGBOUNCER_PID_FILE}" ]; then
    _a_pid=$(tr -d ' \n' < "${PGBOUNCER_PID_FILE}" 2>/dev/null || printf '')
  fi
  case "${_a_pid}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "${_a_pid}" 2>/dev/null
}

# True when the PgBouncer TCP port accepts connections (no login attempted).
pgbouncer_tcp_ready() {
  _t_port="${LISTEN_PORT:-5432}"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 127.0.0.1 "${_t_port}" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# Wait until the PgBouncer TCP port accepts connections (no login).
# Used to give a freshly started process a moment before the endpoint
# probe decides; waiting is not proof of anything.
wait_pgbouncer_tcp() {
  _wt_timeout="${1:-15}"
  _wt_t=0
  while [ "${_wt_t}" -lt "${_wt_timeout}" ]; do
    if pgbouncer_tcp_ready; then
      return 0
    fi
    sleep 1 2>/dev/null || true
    _wt_t=$((_wt_t + 1))
  done
  return 1
}

# Certificate watcher: content-fingerprint polling (no inotify, no hooks).
# Handles initial appearance + renewal without container restart.
# Runs as a background subshell: it shares the filesystem (config, runtime
# certs, applied fingerprint, state file, pid file) with the parent but
# cannot set parent shell variables. All cross-process coordination uses
# files. Fail-closed rules:
#  - the applied fingerprint advances only after the expected certificate
#    is externally observed on the live endpoint; any failure leaves it
#    unchanged so the next poll retries the same source version;
#  - TLS_STATE=active and the active UI are published only after endpoint
#    verification; `prepared` is published while activation is in flight;
#  - a delivered SIGHUP plus a live PID plus an open TCP port are NOT
#    success: only the served-certificate match counts, because PgBouncer
#    keeps its previous TLS context when it rejects new TLS settings;
#  - required waiting->prepared additionally requires config verification,
#    and the parent re-verifies before starting PgBouncer and verifies the
#    endpoint before publishing active;
#  - a failed renewal keeps serving the previous known-good pair (runtime
#    files restored, applied fingerprint untouched); active TLS is never
#    downgraded to plaintext.
# On required waiting->prepared: validate, install, rewrite config,
# verify; the parent supervisor starts PgBouncer and verifies the
# endpoint (no container restart).
cert_watcher() {
  # Only automatic candidates need a watcher. Disabled/manual/plaintext
  # without PUBLIC_HOST exits immediately (no polling, no busy loop).
  if [ "${AUTO_TLS_CANDIDATE}" != "1" ]; then
    return 0
  fi
  if ! command -v validate_caprover_cert >/dev/null 2>&1; then
    return 0
  fi
  _W_SRC_CERT="${CAPROVER_BASE}/live/${PUBLIC_HOST_SANITIZED}/fullchain.pem"
  _W_SRC_KEY="${CAPROVER_BASE}/live/${PUBLIC_HOST_SANITIZED}/privkey.pem"
  _W_HOST="${PUBLIC_HOST_SANITIZED:-localhost}"
  _W_PORT="${LISTEN_PORT:-5432}"
  # Subshell-local view of TLS state, seeded from the parent at fork and
  # kept in sync via the state file each iteration.
  _w_state="${FRONTEND_TLS_STATE}"
  _w_mode="${PGPOOLER_SSL_MODE}"
  while :; do
    sleep "${PGPOOLER_TLS_POLL_INTERVAL}" || true
    # Refresh state from the file so parent-driven changes are visible.
    if [ -f "${PGPOOLER_STATE_FILE}" ]; then
      _w_file_state=$(grep -E '^TLS_STATE=' "${PGPOOLER_STATE_FILE}" 2>/dev/null | tail -n 1 | cut -d= -f2- || printf '')
      if [ -n "${_w_file_state}" ]; then
        _w_state="${_w_file_state}"
      fi
    fi
    # Compare the source version against the last APPLIED version (not
    # merely installed files) so failures automatically retry. A state of
    # `prepared` means the parent is driving activation; leave it alone.
    if [ "${_w_state}" = "prepared" ]; then
      continue
    fi
    _w_src_fp=""
    if command -v source_fingerprint >/dev/null 2>&1; then
      _w_src_fp=$(source_fingerprint "${_W_SRC_CERT}" "${_W_SRC_KEY}" 2>/dev/null || printf '')
    fi
    _w_applied_fp=""
    if command -v read_applied_fingerprint >/dev/null 2>&1; then
      _w_applied_fp=$(read_applied_fingerprint 2>/dev/null || printf '')
    fi
    if [ -z "${_w_src_fp}" ]; then
      # No source (still waiting or removed). Never downgrade active TLS.
      continue
    fi
    if [ -n "${_w_applied_fp}" ] && [ "${_w_src_fp}" = "${_w_applied_fp}" ]; then
      continue
    fi
    # New or not-yet-applied source: validate before any activation.
    if ! validate_caprover_cert "${_W_SRC_CERT}" "${_W_SRC_KEY}" "${PUBLIC_HOST_SANITIZED}"; then
      if [ "${_w_state}" = "waiting" ]; then
        echo "TLS validation: new certificate invalid; still waiting for a valid certificate for ${PUBLIC_HOST_SANITIZED}." >&2
      else
        echo "TLS validation: renewed certificate invalid; keeping current frontend TLS state." >&2
      fi
      continue
    fi
    if [ "${_w_state}" = "active" ]; then
      # Renewal: same config paths, new contents take effect after RELOAD.
      # Existing client connections stay alive per PgBouncer semantics.
      # The known-good backup is mandatory: without it the active pair
      # must not be touched.
      if ! backup_runtime_cert; then
        echo "TLS setup: failed to back up current certificate for ${PUBLIC_HOST_SANITIZED}; leaving active pair untouched and retrying later." >&2
        continue
      fi
      if ! install_runtime_cert "${_W_SRC_CERT}" "${_W_SRC_KEY}"; then
        echo "TLS setup: failed to install renewed certificate for ${PUBLIC_HOST_SANITIZED}." >&2
        continue
      fi
      echo "Frontend TLS certificate changed; reloading PgBouncer" >&2
      if reload_pgbouncer; then
        echo "Frontend TLS reload delivered; verifying live endpoint" >&2
        if verify_frontend_tls_endpoint_retry "${_W_PORT}" "${_W_HOST}"; then
          clear_runtime_cert_backup || true
          FRONTEND_TLS_STATE="active"
          FRONTEND_TLS_ACTIVE=1
          EXPECT_PGBOUNCER=1
          write_state_file || true
          render_ui || true
          if ! commit_applied_fingerprint "${_W_SRC_CERT}" "${_W_SRC_KEY}"; then
            echo "TLS setup: failed to record applied certificate for ${PUBLIC_HOST_SANITIZED}; will retry." >&2
            continue
          fi
          _w_state="active"
        else
          # SIGHUP delivered but B not observed: live state is UNKNOWN.
          # Do not assume rejection. Restore A files, reload them, and
          # confirm A is actually served again before claiming active.
          echo "TLS renewal endpoint verification failed; restoring previous certificate" >&2
          if restore_runtime_cert_backup && rollback_renewal_to_previous "${_W_PORT}" "${_W_HOST}"; then
            echo "Previous TLS certificate verified after rollback" >&2
            clear_runtime_cert_backup || true
          else
            echo "Previous TLS certificate could not be verified after rollback; stopping container to avoid false state" >&2
            abort_container_after_unverified_rollback
          fi
        fi
      else
        # No delivery confirmed: the process is presumed still on A.
        # Reunite the disk with that state and confirm best-effort; a
        # failed confirmation only warns here because no reload was
        # delivered and liveness remains the supervisor's domain.
        echo "TLS renewal reload not delivered; restoring previous certificate files" >&2
        restore_runtime_cert_backup || true
        if rollback_renewal_to_previous "${_W_PORT}" "${_W_HOST}"; then
          clear_runtime_cert_backup || true
        else
          echo "TLS renewal rollback after undelivered reload could not be confirmed; keeping backup and retrying later." >&2
        fi
      fi
      continue
    fi
    if [ "${_w_state}" = "plaintext" ] && [ "${_w_mode}" = "prefer" ]; then
      # Dynamic prefer transition: plaintext -> require without restart.
      # The on-disk config may already carry require from a previous
      # failed attempt while the running process still serves plaintext;
      # state stays plaintext until the endpoint is verified.
      echo "Valid certificate detected for ${PUBLIC_HOST_SANITIZED}; applying frontend TLS" >&2
      if install_runtime_cert "${_W_SRC_CERT}" "${_W_SRC_KEY}" && \
         update_config_tls_to_require && \
         verify_automatic_tls_config "${PG_CONFIG_FILE}" "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null; then
        if reload_pgbouncer; then
          echo "Frontend TLS reload delivered; verifying live endpoint" >&2
          if verify_frontend_tls_endpoint_retry "${_W_PORT}" "${_W_HOST}"; then
            echo "Valid certificate detected for ${PUBLIC_HOST_SANITIZED}; frontend TLS is now required" >&2
            FRONTEND_TLS_ACTIVE=1
            FRONTEND_TLS_STATE="active"
            EXPECT_PGBOUNCER=1
            write_state_file || true
            render_ui || true
            print_config_redacted >/dev/null 2>&1 || true
            if ! commit_applied_fingerprint "${_W_SRC_CERT}" "${_W_SRC_KEY}"; then
              echo "TLS setup: failed to record applied certificate for ${PUBLIC_HOST_SANITIZED}; will retry." >&2
              continue
            fi
            _w_state="active"
          else
            # SIGHUP delivered but the expected certificate is not
            # observed: live state is UNKNOWN, so do not assume the old
            # plaintext survived. Roll back explicitly and confirm it.
            echo "Frontend TLS endpoint verification failed after reload; rolling back to plaintext" >&2
            if rollback_prefer_to_plaintext "${_W_PORT}" "${_W_HOST}"; then
              echo "Frontend TLS rollback to plaintext verified" >&2
            else
              echo "Frontend TLS rollback could not be verified; stopping container to avoid false state" >&2
              abort_container_after_unverified_rollback
            fi
          fi
        else
          # Case A: no delivery confirmed, so the running process is
          # presumed still plaintext. Realign the config best-effort
          # (no second reload) and retry later.
          echo "TLS setup: frontend TLS reload not delivered; staying on plaintext and retrying later." >&2
          downgrade_config_tls_to_disable || true
        fi
      else
        echo "TLS setup: failed to prepare frontend TLS for ${PUBLIC_HOST_SANITIZED}; staying on plaintext and retrying later." >&2
        downgrade_config_tls_to_disable || true
      fi
      continue
    fi
    if [ "${_w_state}" = "waiting" ] && [ "${_w_mode}" = "required" ]; then
      # Required bootstrap: certificate arrived. Fail closed: every step
      # must succeed before signaling the parent, which starts PgBouncer
      # and verifies the endpoint before publishing `active`.
      echo "Valid certificate detected for ${PUBLIC_HOST_SANITIZED}; preparing frontend TLS" >&2
      if install_runtime_cert "${_W_SRC_CERT}" "${_W_SRC_KEY}" && \
         update_config_tls_to_require && \
         verify_automatic_tls_config "${PG_CONFIG_FILE}" "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null; then
        echo "Valid certificate detected for ${PUBLIC_HOST_SANITIZED}; frontend TLS prepared, waiting for process verification" >&2
        FRONTEND_TLS_ACTIVE=1
        FRONTEND_TLS_STATE="prepared"
        EXPECT_PGBOUNCER=1
        write_state_file || true
        render_ui || true
        print_config_redacted >/dev/null 2>&1 || true
        _w_state="prepared"
      else
        echo "TLS setup: failed to prepare frontend TLS for ${PUBLIC_HOST_SANITIZED}; still waiting and retrying later." >&2
      fi
      continue
    fi
  done
}

# Publish a fully verified automatic activation as `active`.
# Call only after the live endpoint was externally verified to serve the
# expected certificate. Sets caller-shell state, writes state file + UI,
# then records the applied fingerprint last so an interruption retries
# instead of skipping. Args: src_cert src_key. Returns nonzero when the
# applied fingerprint cannot be recorded.
publish_tls_active() {
  _p_cert="$1"; _p_key="$2"
  FRONTEND_TLS_ACTIVE=1
  FRONTEND_TLS_STATE="active"
  EXPECT_PGBOUNCER=1
  write_state_file || return 1
  render_ui || true
  print_config_redacted >/dev/null 2>&1 || true
  commit_applied_fingerprint "${_p_cert}" "${_p_key}" || return 1
  return 0
}

# Revert a prepared automatic activation back to waiting (required).
# Used when verification or process confirmation fails and no PgBouncer
# is running (or after it was stopped). Clears the applied fingerprint
# so the watcher retries the same source version on its next poll.
revert_prepared_to_waiting() {
  FRONTEND_TLS_ACTIVE=0
  FRONTEND_TLS_STATE="waiting"
  EXPECT_PGBOUNCER=0
  clear_applied_fingerprint || true
  write_state_file || true
  render_ui || true
}

# Waiting supervision: HTTP UI + watcher stay alive with no PostgreSQL
# listener. When the watcher signals `prepared`, re-verify the config,
# start PgBouncer, verify the live endpoint serves the expected
# certificate, and only then publish `active`. Any failure reverts to
# waiting (fail closed) and the watcher retries; the listener is never
# exposed without confirmed TLS.
supervise_waiting() {
  while [ "${_SHUTDOWN}" != "1" ]; do
    if [ -n "${PGBOUNCER_PID}" ]; then
      wait "${PGBOUNCER_PID}" 2>/dev/null || _pgb_status=$?
      _pgb_status=${_pgb_status:-0}
      if [ "${_SHUTDOWN}" != "1" ]; then
        echo "PgBouncer exited (status ${_pgb_status}); shutting down." >&2
        _SHUTDOWN=1
        cleanup_children TERM
      fi
      wait 2>/dev/null || true
      rm -f "${PGBOUNCER_PID_FILE}" 2>/dev/null || true
      exit "${_pgb_status}"
    fi
    sleep 2 2>/dev/null || true
    if [ -f "${PGPOOLER_STATE_FILE}" ]; then
      _exp=$(grep -E '^EXPECT_PGBOUNCER=' "${PGPOOLER_STATE_FILE}" 2>/dev/null | tail -n 1 || true)
      _st=$(grep -E '^TLS_STATE=' "${PGPOOLER_STATE_FILE}" 2>/dev/null | tail -n 1 || true)
      case "${_exp}" in
        EXPECT_PGBOUNCER=1)
          case "${_st}" in
            TLS_STATE=prepared)
              if [ -z "${PGBOUNCER_PID}" ]; then
                _sw_cert="${CAPROVER_BASE}/live/${PUBLIC_HOST_SANITIZED}/fullchain.pem"
                _sw_key="${CAPROVER_BASE}/live/${PUBLIC_HOST_SANITIZED}/privkey.pem"
                # The state file alone is not proof: re-verify the require
                # config before exposing the PostgreSQL listener.
                if ! command -v verify_automatic_tls_config >/dev/null 2>&1 || \
                   ! verify_automatic_tls_config "${PG_CONFIG_FILE}" "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null; then
                  echo "TLS setup: signaled preparation failed parent verification; reverting to waiting." >&2
                  revert_prepared_to_waiting
                  continue
                fi
                FRONTEND_TLS_STATE="prepared"
                FRONTEND_TLS_ACTIVE=1
                EXPECT_PGBOUNCER=1
                start_pgbouncer "$@"
                if wait_pgbouncer_tcp 15 && \
                   verify_frontend_tls_endpoint_retry "${LISTEN_PORT:-5432}" "${PUBLIC_HOST_SANITIZED:-localhost}" && \
                   publish_tls_active "${_sw_cert}" "${_sw_key}"; then
                  echo "PgBouncer started with frontend TLS verified active." >&2
                else
                  echo "TLS setup: prepared endpoint did not verify live; reverting to waiting." >&2
                  kill "${PGBOUNCER_PID}" 2>/dev/null || true
                  wait "${PGBOUNCER_PID}" 2>/dev/null || true
                  PGBOUNCER_PID=""
                  rm -f "${PGBOUNCER_PID_FILE}" 2>/dev/null || true
                  revert_prepared_to_waiting
                  continue
                fi
                # Now supervise the verified PgBouncer below.
                wait "${PGBOUNCER_PID}" 2>/dev/null || _pgb_status=$?
                _pgb_status=${_pgb_status:-0}
                if [ "${_SHUTDOWN}" != "1" ]; then
                  echo "PgBouncer exited (status ${_pgb_status}); shutting down." >&2
                  _SHUTDOWN=1
                  cleanup_children TERM
                fi
                wait 2>/dev/null || true
                rm -f "${PGBOUNCER_PID_FILE}" 2>/dev/null || true
                exit "${_pgb_status}"
              fi
              ;;
            TLS_STATE=active)
              # Unreachable in normal operation: `active` is published only
              # after a verified start that also records the child pid.
              # Trip fail-closed rather than guessing.
              if [ -z "${PGBOUNCER_PID}" ]; then
                echo "TLS setup: unexpected active state with no supervised PgBouncer; shutting down." >&2
                _SHUTDOWN=1
                cleanup_children TERM
                wait 2>/dev/null || true
                exit 1
              fi
              ;;
          esac
          ;;
      esac
    fi
    # If httpd died unexpectedly, shut down.
    if [ -n "${HTTPD_PID}" ]; then
      if ! kill -0 "${HTTPD_PID}" 2>/dev/null; then
        echo "HTTP UI exited; shutting down." >&2
        _SHUTDOWN=1
        cleanup_children TERM
        wait 2>/dev/null || true
        exit 1
      fi
    fi
  done
  wait 2>/dev/null || true
  exit 0
}

# Boot supervised children.
start_httpd

if [ "${EXPECT_PGBOUNCER}" = "1" ]; then
  # shellcheck disable=SC2086
  start_pgbouncer "$@"
  if [ "${_BOOT_PREPARED:-0}" = "1" ]; then
    # Boot-time prepared activation: the endpoint must be externally
    # verified before `active` may be published (same rule as late
    # activation). Applied is committed only on success.
    if wait_pgbouncer_tcp 15 && \
       verify_frontend_tls_endpoint_retry "${LISTEN_PORT:-5432}" "${PUBLIC_HOST_SANITIZED:-localhost}" && \
       publish_tls_active "${_BOOT_TLS_CERT}" "${_BOOT_TLS_KEY}"; then
      echo "Frontend TLS verified active for ${PUBLIC_HOST_SANITIZED}." >&2
    else
      echo "TLS setup: boot-time prepared endpoint did not verify live." >&2
      kill "${PGBOUNCER_PID}" 2>/dev/null || true
      wait "${PGBOUNCER_PID}" 2>/dev/null || true
      PGBOUNCER_PID=""
      rm -f "${PGBOUNCER_PID_FILE}" 2>/dev/null || true
      if [ "${PGPOOLER_SSL_MODE}" = "required" ]; then
        revert_prepared_to_waiting
      else
        # Prefer falls back to what is actually running: plaintext.
        downgrade_config_tls_to_disable || true
        FRONTEND_TLS_ACTIVE=0
        FRONTEND_TLS_STATE="plaintext"
        EXPECT_PGBOUNCER=1
        write_state_file || true
        render_ui || true
        # shellcheck disable=SC2086
        start_pgbouncer "$@"
      fi
    fi
  fi
else
  echo "Frontend TLS policy requires a certificate; waiting before starting PgBouncer" >&2
  echo "HTTP documentation UI remains available on port ${HTTP_PORT}." >&2
fi

# Watcher runs in background only when automatic discovery is relevant.
# Forked after the initial start so a boot-time prepared endpoint is
# verified by the parent first; the watcher skips `prepared` states.
if [ "${AUTO_TLS_CANDIDATE}" = "1" ]; then
  cert_watcher &
  WATCHER_PID="$!"
fi

# Supervise: exit when any essential child exits. A boot-time required
# failure already reverted to waiting above; enter waiting supervision.
if [ "${EXPECT_PGBOUNCER}" = "1" ]; then
  # Wait for PgBouncer; forward httpd/watcher cleanup on its exit.
  wait "${PGBOUNCER_PID}" 2>/dev/null || _pgb_status=$?
  _pgb_status=${_pgb_status:-0}
  if [ "${_SHUTDOWN}" != "1" ]; then
    echo "PgBouncer exited (status ${_pgb_status}); shutting down." >&2
    _SHUTDOWN=1
    cleanup_children TERM
  fi
  wait 2>/dev/null || true
  rm -f "${PGBOUNCER_PID_FILE}" 2>/dev/null || true
  exit "${_pgb_status}"
else
  supervise_waiting "$@"
fi
