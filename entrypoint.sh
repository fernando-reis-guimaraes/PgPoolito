#!/bin/sh
# Based on https://raw.githubusercontent.com/brainsam/pgbouncer/master/entrypoint.sh

set -e

# Here are some parameters. See all on
# https://pgbouncer.github.io/config.html

PG_CONFIG_DIR=/etc/pgbouncer
PG_CONFIG_FILE="${PG_CONFIG_DIR}/pgbouncer.ini"
_AUTH_FILE="${AUTH_FILE:-$PG_CONFIG_DIR/userlist.txt}"

# Workaround userlist.txt missing issue
# https://github.com/edoburu/docker-pgbouncer/issues/33
if [ ! -e "${_AUTH_FILE}" ]; then
  touch "${_AUTH_FILE}"
fi
# Restrict auth file permissions (contains credentials).
chmod 0600 "${_AUTH_FILE}" 2>/dev/null || true

# PgPooler-Uma extension: optional independent frontend credentials.
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
  if [ ! -e "${_AUTH_FILE}" ]; then
    touch "${_AUTH_FILE}"
  fi
  chmod 0600 "${_AUTH_FILE}" 2>/dev/null || true
  if grep -q "^\"${_w_user}\"" "${_AUTH_FILE}"; then
    return 0
  fi
  if [ "${AUTH_TYPE:-}" = "plain" ] || [ "${AUTH_TYPE:-}" = "scram-sha-256" ]; then
    _w_hash="${_w_pass}"
  else
    _w_hash="md5$(printf '%s' "${_w_pass}${_w_user}" | md5sum | cut -f 1 -d ' ')"
  fi
  printf '"%s" "%s"\n' "${_w_user}" "${_w_hash}" >> "${_AUTH_FILE}"
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
generate_config_db_entry() {
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
${DB_NAME:-*} = host=${_q_host} \
port=${DB_PORT:-5432}${_forced_user}${_backend_password}
${CLIENT_ENCODING:+client_encoding = ${CLIENT_ENCODING}\n}\
" >> "${PG_CONFIG_FILE}"
  else
    printf "\
${DB_NAME:-*} = host=${DB_HOST:?"Setup pgbouncer config error! You must set DB_HOST env"} \
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
    generate_userlist_if_needed
  done
  ensure_frontend_auth
else
  if [ -n "${DATABASE_URL:-}" ]; then
    parse_url "${DATABASE_URL}"
  fi
  generate_userlist_if_needed
  ensure_frontend_auth
fi

if [ ! -f "${PG_CONFIG_FILE}" ]; then
  echo "Creating pgbouncer config in ${PG_CONFIG_DIR}"

  # Config file is in "ini" format. Section names are between "[" and "]".
  # Lines starting with ";" or "#" are taken as comments and ignored.
  # The characters ";" and "#" are not recognized when they appear later in the line.
  printf "\
################## Auto generated ##################
[databases]
" > "${PG_CONFIG_FILE}"

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
      generate_config_db_entry
    done
  else
    if [ -n "${DATABASE_URL:-}" ]; then
      parse_url "${DATABASE_URL}"
    fi
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
${CLIENT_TLS_SSLMODE:+client_tls_sslmode = ${CLIENT_TLS_SSLMODE}\n}\
${CLIENT_TLS_KEY_FILE:+client_tls_key_file = ${CLIENT_TLS_KEY_FILE}\n}\
${CLIENT_TLS_CERT_FILE:+client_tls_cert_file = ${CLIENT_TLS_CERT_FILE}\n}\
${CLIENT_TLS_CA_FILE:+client_tls_ca_file = ${CLIENT_TLS_CA_FILE}\n}\
${CLIENT_TLS_PROTOCOLS:+client_tls_protocols = ${CLIENT_TLS_PROTOCOLS}\n}\
${CLIENT_TLS_CIPHERS:+client_tls_ciphers = ${CLIENT_TLS_CIPHERS}\n}\
${CLIENT_TLS_ECDHCURVE:+client_tls_ecdhcurve = ${CLIENT_TLS_ECDHCURVE}\n}\
${CLIENT_TLS_DHEPARAMS:+client_tls_dheparams = ${CLIENT_TLS_DHEPARAMS}\n}\
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
  print_config_redacted
fi

# Ensure restrictive permissions on generated files (may already exist).
chmod 0600 "${PG_CONFIG_FILE}" 2>/dev/null || true
chmod 0600 "${_AUTH_FILE}" 2>/dev/null || true

echo "Starting $*..."
exec "$@"
