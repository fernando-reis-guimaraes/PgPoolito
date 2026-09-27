#!/bin/sh
# PgPoolito frontend TLS helpers (POSIX sh).
# No secrets are printed. No eval. PUBLIC_HOST is treated as untrusted.
# Requires: openssl CLI for validation.

# Fixed conventional CapRover mount (no env knob per spec).
CAPROVER_BASE="/caprover-letsencrypt"
# Private runtime copies owned by the PgBouncer user.
TLS_RUNTIME_DIR="/run/pgbouncer/tls"
TLS_RUNTIME_CERT="${TLS_RUNTIME_DIR}/fullchain.pem"
TLS_RUNTIME_KEY="${TLS_RUNTIME_DIR}/privkey.pem"
# Applied fingerprint: content fingerprint of the source certificate/key
# pair that was last CONFIRMED applied to the running PgBouncer, not merely
# copied to disk. It advances only after the full sequence succeeds
# (install + config rewrite + config verification + reload or verified
# process start). A failed step leaves it unchanged so the next polling
# iteration retries the same source version.
TLS_APPLIED_FILE="${TLS_RUNTIME_DIR}/.fingerprint"
# Previous known-good runtime pair, kept only across a renewal reload
# attempt so a failed reload can restore the last working files.
TLS_PREV_CERT="${TLS_RUNTIME_DIR}/.fullchain.pem.prev"
TLS_PREV_KEY="${TLS_RUNTIME_DIR}/.privkey.pem.prev"
# Test-only fault-injection flags (runtime files, absent by default).
# The test harness creates/removes them inside a running container to
# force deterministic backup or endpoint-verification failures. They are
# never set in production and change nothing when absent. Never secrets.
TLS_FAIL_BACKUP_FILE="${TLS_FAIL_BACKUP_FILE:-/run/pgbouncer/.fail-tls-backup}"
TLS_FAIL_ENDPOINT_FILE="${TLS_FAIL_ENDPOINT_FILE:-/run/pgbouncer/.fail-tls-endpoint-verification}"
# Test-only install fault: while present, the installed key file receives
# certificate content (unloadable as a private key), so a subsequent
# RELOAD is really rejected by PgBouncer while the process survives.
TLS_FAIL_INSTALL_FILE="${TLS_FAIL_INSTALL_FILE:-/run/pgbouncer/.fail-tls-install}"

# Validate PUBLIC_HOST as a single DNS hostname.
# Prints the sanitized value on success, returns 1 on failure.
# Allowed: 1-253 chars, labels of [A-Za-z0-9-], dots, no leading/trailing
# dot or hyphen, no empty label, no slash, no spaces, no shell metachars.
sanitize_public_host() {
  _s_host="$1"
  case "${_s_host}" in
    "" ) return 1 ;;
  esac
  # Length guard (POSIX: use case + expr via shell).
  _s_len=$(printf '%s' "${_s_host}" | wc -c)
  _s_len=$(printf '%s' "${_s_len}" | tr -d ' ')
  if [ "${_s_len}" -gt 253 ] || [ "${_s_len}" -lt 1 ]; then
    return 1
  fi
  case "${_s_host}" in
    *[!A-Za-z0-9.-]*) return 1 ;;
    .*) return 1 ;;
    *.) return 1 ;;
    -*) return 1 ;;
    *-) return 1 ;;
    *..*) return 1 ;;
  esac
  # Each dot-separated label: 1-63 chars, no leading/trailing hyphen.
  _s_rest="${_s_host}."
  while [ -n "${_s_rest}" ]; do
    _s_label="${_s_rest%%.*}"
    case "${_s_rest}" in
      *.*) _s_rest="${_s_rest#*.}" ;;
      *) _s_rest="" ;;
    esac
    if [ -z "${_s_label}" ]; then
      return 1
    fi
    _s_llen=$(printf '%s' "${_s_label}" | wc -c)
    _s_llen=$(printf '%s' "${_s_llen}" | tr -d ' ')
    if [ "${_s_llen}" -gt 63 ]; then
      return 1
    fi
    case "${_s_label}" in
      -*|*-) return 1 ;;
    esac
  done
  printf '%s' "${_s_host}"
  return 0
}

# Resolve and validate PGPOOLER_SSL_MODE. Prints value, fails on invalid.
# Default: prefer. Never prints secrets.
resolve_ssl_mode() {
  _m="${PGPOOLER_SSL_MODE:-prefer}"
  case "${_m}" in
    disabled|prefer|required)
      printf '%s' "${_m}"
      return 0
      ;;
    *)
      echo "error: invalid PGPOOLER_SSL_MODE='${_m}' (expected disabled|prefer|required)." >&2
      return 1
      ;;
  esac
}

# True (0) when any manual frontend TLS identity is configured.
# Only CERT_FILE / KEY_FILE / SSLMODE count as the certificate pair identity.
# CA/protocols/ciphers alone do not trigger manual mode.
has_manual_frontend_tls() {
  if [ -n "${CLIENT_TLS_CERT_FILE:-}" ] || [ -n "${CLIENT_TLS_KEY_FILE:-}" ] || [ -n "${CLIENT_TLS_SSLMODE:-}" ]; then
    return 0
  fi
  return 1
}

# Source CapRover paths for a sanitized host. Prints "cert key".
caprover_source_paths() {
  _c_host="$1"
  printf '%s %s' \
    "${CAPROVER_BASE}/live/${_c_host}/fullchain.pem" \
    "${CAPROVER_BASE}/live/${_c_host}/privkey.pem"
}

# Content fingerprint of two files (follows symlinks).
# Prints sha256 hex lines or returns 1 when unreadable.
source_fingerprint() {
  _f_cert="$1"
  _f_key="$2"
  if [ ! -r "${_f_cert}" ] || [ ! -r "${_f_key}" ]; then
    return 1
  fi
  # sha256sum is provided by busybox/coreutils in Alpine.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${_f_cert}" "${_f_key}" 2>/dev/null | awk '{print $1}' | tr '\n' ':' || return 1
    return 0
  fi
  # Fallback: openssl digests follow symlinks as well.
  _h1=$(openssl dgst -sha256 "${_f_cert}" 2>/dev/null) || return 1
  _h2=$(openssl dgst -sha256 "${_f_key}" 2>/dev/null) || return 1
  printf '%s:%s' "${_h1}" "${_h2}"
  return 0
}

# Validate a CapRover certificate/key pair for the expected host.
# Logs only the reason (no paths with secrets, no key material).
# Returns 0 when usable, 1 otherwise.
validate_caprover_cert() {
  _v_cert="$1"
  _v_key="$2"
  _v_host="$3"
  if [ ! -e "${_v_cert}" ] || [ ! -e "${_v_key}" ]; then
    echo "TLS validation: certificate or key missing for '${_v_host}'." >&2
    return 1
  fi
  if [ ! -r "${_v_cert}" ] || [ ! -r "${_v_key}" ]; then
    echo "TLS validation: certificate or key not readable for '${_v_host}'." >&2
    return 1
  fi
  if ! openssl x509 -in "${_v_cert}" -noout >/dev/null 2>&1; then
    echo "TLS validation: certificate is not parseable for '${_v_host}'." >&2
    return 1
  fi
  # Currently valid (not expired and not before validity).
  if ! openssl x509 -in "${_v_cert}" -noout -checkend 0 >/dev/null 2>&1; then
    echo "TLS validation: certificate is expired or not currently valid for '${_v_host}'." >&2
    return 1
  fi
  # notBefore check without GNU date (BusyBox date cannot parse OpenSSL
  # dates). Normalize both times to YYYYMMDDHHMMSS numbers via shell.
  _v_start=$(openssl x509 -in "${_v_cert}" -noout -startdate 2>/dev/null | cut -d= -f2-)
  if [ -n "${_v_start}" ]; then
    # OpenSSL format: "Sep 23 10:47:59 2026 GMT" (day may be space-padded).
    _v_mon=$(printf '%s' "${_v_start}" | awk '{print $1}' 2>/dev/null || printf '')
    _v_day=$(printf '%s' "${_v_start}" | awk '{print $2}' 2>/dev/null || printf '')
    _v_time=$(printf '%s' "${_v_start}" | awk '{print $3}' 2>/dev/null || printf '')
    _v_year=$(printf '%s' "${_v_start}" | awk '{print $4}' 2>/dev/null || printf '')
    _v_mon_num=""
    case "${_v_mon}" in
      Jan) _v_mon_num="01" ;; Feb) _v_mon_num="02" ;; Mar) _v_mon_num="03" ;;
      Apr) _v_mon_num="04" ;; May) _v_mon_num="05" ;; Jun) _v_mon_num="06" ;;
      Jul) _v_mon_num="07" ;; Aug) _v_mon_num="08" ;; Sep) _v_mon_num="09" ;;
      Oct) _v_mon_num="10" ;; Nov) _v_mon_num="11" ;; Dec) _v_mon_num="12" ;;
    esac
    if [ -n "${_v_mon_num}" ] && [ -n "${_v_day}" ] && [ -n "${_v_time}" ] && [ -n "${_v_year}" ]; then
      # Zero-pad day, strip colons from time.
      _v_day=$(printf '%02d' "${_v_day}" 2>/dev/null || printf '%s' "${_v_day}")
      _v_tdigits=$(printf '%s' "${_v_time}" | tr -d ':' 2>/dev/null || printf '')
      _v_start_num="${_v_year}${_v_mon_num}${_v_day}${_v_tdigits}"
      _v_now_num=$(date -u "+%Y%m%d%H%M%S" 2>/dev/null || printf '')
      case "${_v_start_num}${_v_now_num}" in
        ''|*[!0-9]*) ;;
        *)
          if [ "${_v_start_num}" -gt "${_v_now_num}" ]; then
            echo "TLS validation: certificate is not yet valid for '${_v_host}'." >&2
            return 1
          fi
          ;;
      esac
    fi
  fi
  # Hostname match via OpenSSL (SAN + wildcard aware). No fragile parsing.
  if ! openssl x509 -in "${_v_cert}" -noout -checkhost "${_v_host}" >/dev/null 2>&1; then
    echo "TLS validation: certificate hostname mismatch for '${_v_host}'." >&2
    return 1
  fi
  # Key correspondence without printing material (compare public parts).
  _v_cert_pub=$(openssl x509 -in "${_v_cert}" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null) || _v_cert_pub=""
  _v_key_pub=$(openssl pkey -in "${_v_key}" -pubout 2>/dev/null | openssl sha256 2>/dev/null) || _v_key_pub=""
  if [ -z "${_v_cert_pub}" ] || [ -z "${_v_key_pub}" ]; then
    echo "TLS validation: private key is not parseable for '${_v_host}'." >&2
    return 1
  fi
  if [ "${_v_cert_pub}" != "${_v_key_pub}" ]; then
    echo "TLS validation: private key does not match certificate for '${_v_host}'." >&2
    return 1
  fi
  return 0
}

# Atomically install a validated source cert/key into the private runtime
# dir. Sets 0600 postgres ownership on runtime copies. Source files are
# never modified. This step alone does NOT mark the version applied; the
# caller must complete config rewrite, verification, and reload (or a
# verified process start) and then call commit_applied_fingerprint.
# Args: src_cert src_key ; run as root. Never prints secrets.
install_runtime_cert() {
  _i_cert="$1"
  _i_key="$2"
  mkdir -p "${TLS_RUNTIME_DIR}" 2>/dev/null || return 1
  # Restrict the directory (owner root or postgres; require no group/other).
  chmod 0700 "${TLS_RUNTIME_DIR}" 2>/dev/null || true
  if id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${TLS_RUNTIME_DIR}" 2>/dev/null || true
  fi
  _i_tmp_cert="${TLS_RUNTIME_DIR}/.fullchain.pem.tmp.$$"
  _i_tmp_key="${TLS_RUNTIME_DIR}/.privkey.pem.tmp.$$"
  # Clean stale temps from a previous interrupted install.
  rm -f "${_i_tmp_cert}" "${_i_tmp_key}" 2>/dev/null || true
  if ! cat "${_i_cert}" > "${_i_tmp_cert}" 2>/dev/null; then
    rm -f "${_i_tmp_cert}" "${_i_tmp_key}" 2>/dev/null || true
    return 1
  fi
  # Test-only fault: install certificate content as the key so the pair
  # is unloadable and a later RELOAD is rejected (process must survive).
  _i_key_src="${_i_key}"
  if [ -f "${TLS_FAIL_INSTALL_FILE}" ]; then
    _i_key_src="${_i_cert}"
  fi
  if ! cat "${_i_key_src}" > "${_i_tmp_key}" 2>/dev/null; then
    rm -f "${_i_tmp_cert}" "${_i_tmp_key}" 2>/dev/null || true
    return 1
  fi
  chmod 0600 "${_i_tmp_cert}" "${_i_tmp_key}" 2>/dev/null || true
  if id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${_i_tmp_cert}" "${_i_tmp_key}" 2>/dev/null || true
  fi
  # Atomic replacement of each file (same filesystem: /run tmpfs).
  if ! mv -f "${_i_tmp_cert}" "${TLS_RUNTIME_CERT}" 2>/dev/null; then
    rm -f "${_i_tmp_cert}" "${_i_tmp_key}" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "${_i_tmp_key}" "${TLS_RUNTIME_KEY}" 2>/dev/null; then
    rm -f "${_i_tmp_key}" 2>/dev/null || true
    return 1
  fi
  chmod 0600 "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null || true
  if id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null || true
  fi
  return 0
}

# Save the current runtime pair as the previous known-good backup.
# Callers must treat a nonzero return as fatal for the renewal attempt:
# without a usable backup the active pair must not be touched. Backup
# files are restrictive (0600) like the active copies.
backup_runtime_cert() {
  # Test-only fault flag for deterministic backup-failure tests.
  if [ -f "${TLS_FAIL_BACKUP_FILE:-/run/pgbouncer/.fail-tls-backup}" ]; then
    return 1
  fi
  if [ -f "${TLS_RUNTIME_CERT}" ] && [ -f "${TLS_RUNTIME_KEY}" ]; then
    cp -f "${TLS_RUNTIME_CERT}" "${TLS_PREV_CERT}" 2>/dev/null || return 1
    cp -f "${TLS_RUNTIME_KEY}" "${TLS_PREV_KEY}" 2>/dev/null || return 1
    chmod 0600 "${TLS_PREV_CERT}" "${TLS_PREV_KEY}" 2>/dev/null || true
    if id postgres >/dev/null 2>&1; then
      chown postgres:postgres "${TLS_PREV_CERT}" "${TLS_PREV_KEY}" 2>/dev/null || true
    fi
    [ -s "${TLS_PREV_CERT}" ] && [ -s "${TLS_PREV_KEY}" ] || return 1
  fi
  return 0
}

# Restore the previous known-good runtime pair after a failed reload.
# Best effort; the running PgBouncer keeps its previous in-memory TLS
# context regardless, so no reload is issued here.
restore_runtime_cert_backup() {
  if [ -f "${TLS_PREV_CERT}" ] && [ -f "${TLS_PREV_KEY}" ]; then
    cp -f "${TLS_PREV_CERT}" "${TLS_RUNTIME_CERT}" 2>/dev/null || return 1
    cp -f "${TLS_PREV_KEY}" "${TLS_RUNTIME_KEY}" 2>/dev/null || return 1
    chmod 0600 "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null || true
    if id postgres >/dev/null 2>&1; then
      chown postgres:postgres "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null || true
    fi
  fi
  return 0
}

# Drop the previous-pair backup (fewer private-key copies on disk).
clear_runtime_cert_backup() {
  rm -f "${TLS_PREV_CERT}" "${TLS_PREV_KEY}" 2>/dev/null || true
  return 0
}

# Remove active and backup runtime pairs plus the applied record.
# Used when starting (or restarting) with no usable source certificate
# so a stale previously-applied version cannot suppress a future
# activation of a reappearing certificate.
clear_runtime_cert_files() {
  rm -f "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" "${TLS_PREV_CERT}" "${TLS_PREV_KEY}" 2>/dev/null || true
  clear_applied_fingerprint || true
  return 0
}

# Record the source pair fingerprint as successfully applied. Call only
# after the version is confirmed live (config verified plus reload
# delivered to a surviving process, or a verified fresh process start).
# Args: src_cert src_key. Never prints secrets.
commit_applied_fingerprint() {
  _c_fp=$(source_fingerprint "$1" "$2" 2>/dev/null) || return 1
  if [ -z "${_c_fp}" ]; then
    return 1
  fi
  printf '%s' "${_c_fp}" > "${TLS_APPLIED_FILE}.tmp" 2>/dev/null || return 1
  mv -f "${TLS_APPLIED_FILE}.tmp" "${TLS_APPLIED_FILE}" 2>/dev/null || return 1
  chmod 0600 "${TLS_APPLIED_FILE}" 2>/dev/null || true
  if id postgres >/dev/null 2>&1; then
    chown postgres:postgres "${TLS_APPLIED_FILE}" 2>/dev/null || true
  fi
  return 0
}

# Read the stored applied fingerprint (empty when nothing applied yet).
read_applied_fingerprint() {
  if [ -f "${TLS_APPLIED_FILE}" ]; then
    tr -d '\n' < "${TLS_APPLIED_FILE}" 2>/dev/null || printf ''
  else
    printf ''
  fi
}

# Forget the applied version (used when reverting a failed activation).
clear_applied_fingerprint() {
  rm -f "${TLS_APPLIED_FILE}" 2>/dev/null || true
  return 0
}

# Verify that a PgBouncer config file carries exactly the expected
# automatic frontend TLS identity. Matching is anchored per line so
# comments or malformed values cannot satisfy the check. Values are
# compared as literal strings after trimming surrounding whitespace.
# Args: config_file [expected_cert_file] [expected_key_file].
# Returns 0 only when sslmode is exactly `require` (single directive)
# and both paths match exactly (single directive each).
verify_automatic_tls_config() {
  _v_cfg="$1"
  _v_cert="${2:-${TLS_RUNTIME_CERT}}"
  _v_key="${3:-${TLS_RUNTIME_KEY}}"
  [ -f "${_v_cfg}" ] || return 1
  # NOTE: `grep -c` prints 0 but exits nonzero on no match, so plain
  # `|| printf '0'` would concatenate a second 0 ("00"). Use `|| true`
  # to keep the printed count intact.
  _v_mode_count=$(grep -c -E '^[[:space:]]*client_tls_sslmode[[:space:]]*=' "${_v_cfg}" 2>/dev/null || true)
  _v_cert_count=$(grep -c -E '^[[:space:]]*client_tls_cert_file[[:space:]]*=' "${_v_cfg}" 2>/dev/null || true)
  _v_key_count=$(grep -c -E '^[[:space:]]*client_tls_key_file[[:space:]]*=' "${_v_cfg}" 2>/dev/null || true)
  # Normalize counts (grep -c prints 0 with status 1 when nothing matches).
  _v_mode_count=$(printf '%s' "${_v_mode_count}" | tr -d ' \n')
  _v_cert_count=$(printf '%s' "${_v_cert_count}" | tr -d ' \n')
  _v_key_count=$(printf '%s' "${_v_key_count}" | tr -d ' \n')
  if [ "${_v_mode_count}" != "1" ] || [ "${_v_cert_count}" != "1" ] || [ "${_v_key_count}" != "1" ]; then
    return 1
  fi
  _v_mode=$(sed -n -E 's/^[[:space:]]*client_tls_sslmode[[:space:]]*=[[:space:]]*([^[:space:]#;]+)[[:space:]]*([#;].*)?$/\1/p' "${_v_cfg}" 2>/dev/null | tail -n 1 || printf '')
  _v_cert_val=$(sed -n -E 's/^[[:space:]]*client_tls_cert_file[[:space:]]*=[[:space:]]*([^#;]+[^#; ])[[:space:]]*([#;].*)?$/\1/p' "${_v_cfg}" 2>/dev/null | tail -n 1 || printf '')
  _v_key_val=$(sed -n -E 's/^[[:space:]]*client_tls_key_file[[:space:]]*=[[:space:]]*([^#;]+[^#; ])[[:space:]]*([#;].*)?$/\1/p' "${_v_cfg}" 2>/dev/null | tail -n 1 || printf '')
  # Trim residual surrounding whitespace without touching inner content.
  _v_mode=$(printf '%s' "${_v_mode}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  _v_cert_val=$(printf '%s' "${_v_cert_val}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  _v_key_val=$(printf '%s' "${_v_key_val}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ "${_v_mode}" != "require" ]; then
    return 1
  fi
  if [ "${_v_cert_val}" != "${_v_cert}" ]; then
    return 1
  fi
  if [ "${_v_key_val}" != "${_v_key}" ]; then
    return 1
  fi
  return 0
}

# SHA-256 fingerprint of the leaf certificate in a local PEM file (reads
# the first certificate block, i.e. the leaf of a fullchain file).
# Prints bare uppercase hex without colons. No secrets, no keys.
runtime_leaf_fingerprint() {
  _l_file="${1:-${TLS_RUNTIME_CERT}}"
  [ -r "${_l_file}" ] || return 1
  _l_fp=""
  _l_fp=$(openssl x509 -in "${_l_file}" -noout -fingerprint -sha256 2>/dev/null | sed -e 's/^[^=]*=//' | tr -d ':\n' | tr 'a-z' 'A-Z' 2>/dev/null) || return 1
  [ -n "${_l_fp}" ] || return 1
  printf '%s' "${_l_fp}"
  return 0
}

# SHA-256 fingerprint of the leaf certificate currently served on the
# PostgreSQL frontend port. Performs a real TLS handshake: PgBouncer
# auto-detects a direct TLS ClientHello, so no PostgreSQL SSLRequest
# framing is needed. Bounded by `timeout`, never blocks indefinitely.
# Prints bare uppercase hex without colons. No credentials, no keys.
served_frontend_leaf_fp() {
  _s_port="${1:-5432}"
  _s_name="${2:-localhost}"
  _s_fp=""
  _s_fp=$(timeout 10 openssl s_client -connect "127.0.0.1:${_s_port}" -servername "${_s_name}" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed -e 's/^[^=]*=//' | tr -d ':\n' | tr 'a-z' 'A-Z' 2>/dev/null) || return 1
  [ -n "${_s_fp}" ] || return 1
  printf '%s' "${_s_fp}"
  return 0
}

# Externally verify that the frontend endpoint serves the expected
# runtime leaf certificate. This is the only accepted proof that a TLS
# activation (or renewal) actually took effect: a delivered SIGHUP plus
# a live PID plus an open TCP port are NOT sufficient, because PgBouncer
# keeps the previous TLS context when it rejects new TLS settings.
# Args: [port] [servername]. No credentials, no private key material.
# Test-only fault flag forces failure for deterministic retry tests.
verify_frontend_tls_endpoint() {
  if [ -f "${TLS_FAIL_ENDPOINT_FILE:-/run/pgbouncer/.fail-tls-endpoint-verification}" ]; then
    return 1
  fi
  _e_port="${1:-${LISTEN_PORT:-5432}}"
  _e_name="${2:-localhost}"
  _e_expected=""
  _e_expected=$(runtime_leaf_fingerprint "${TLS_RUNTIME_CERT}" 2>/dev/null) || return 1
  [ -n "${_e_expected}" ] || return 1
  _e_served=""
  _e_served=$(served_frontend_leaf_fp "${_e_port}" "${_e_name}" 2>/dev/null) || return 1
  [ -n "${_e_served}" ] || return 1
  [ "${_e_served}" = "${_e_expected}" ]
}

# Bounded retry wrapper around verify_frontend_tls_endpoint for paths
# where asynchronous SIGHUP processing may need a short settle window.
# Attempts: immediately, after 1s, after 2s more, after 2s more. Total
# added delay stays small; no unbounded wait, no busy loop. Returns
# success only when the expected certificate is actually served.
verify_frontend_tls_endpoint_retry() {
  _r_port="${1:-${LISTEN_PORT:-5432}}"
  _r_name="${2:-localhost}"
  if verify_frontend_tls_endpoint "${_r_port}" "${_r_name}"; then
    return 0
  fi
  sleep 1 2>/dev/null || true
  if verify_frontend_tls_endpoint "${_r_port}" "${_r_name}"; then
    return 0
  fi
  sleep 2 2>/dev/null || true
  if verify_frontend_tls_endpoint "${_r_port}" "${_r_name}"; then
    return 0
  fi
  sleep 2 2>/dev/null || true
  verify_frontend_tls_endpoint "${_r_port}" "${_r_name}"
}

# Verify that a PgBouncer config file explicitly disables frontend TLS
# with no contradicting automatic cert/key directives. Anchored matching
# like verify_automatic_tls_config. Returns 0 only for exactly one
# `client_tls_sslmode = disable` line and zero cert/key file lines.
verify_frontend_tls_disabled_config() {
  _d_cfg="$1"
  [ -f "${_d_cfg}" ] || return 1
  # NOTE: `grep -c` prints 0 but exits nonzero on no match, so plain
  # `|| printf '0'` would concatenate a second 0 ("00"). Use `|| true`
  # to keep the printed count intact.
  _d_mode_count=$(grep -c -E '^[[:space:]]*client_tls_sslmode[[:space:]]*=' "${_d_cfg}" 2>/dev/null || true)
  _d_cert_count=$(grep -c -E '^[[:space:]]*client_tls_cert_file[[:space:]]*=' "${_d_cfg}" 2>/dev/null || true)
  _d_key_count=$(grep -c -E '^[[:space:]]*client_tls_key_file[[:space:]]*=' "${_d_cfg}" 2>/dev/null || true)
  _d_mode_count=$(printf '%s' "${_d_mode_count}" | tr -d ' \n')
  _d_cert_count=$(printf '%s' "${_d_cert_count}" | tr -d ' \n')
  _d_key_count=$(printf '%s' "${_d_key_count}" | tr -d ' \n')
  if [ "${_d_mode_count}" != "1" ] || [ "${_d_cert_count}" != "0" ] || [ "${_d_key_count}" != "0" ]; then
    return 1
  fi
  _d_mode=$(sed -n -E 's/^[[:space:]]*client_tls_sslmode[[:space:]]*=[[:space:]]*([^[:space:]#;]+)[[:space:]]*([#;].*)?$/\1/p' "${_d_cfg}" 2>/dev/null | tail -n 1 || printf '')
  _d_mode=$(printf '%s' "${_d_mode}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ "${_d_mode}" != "disable" ]; then
    return 1
  fi
  return 0
}
