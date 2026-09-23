#!/bin/sh
# PgPooler-Uma frontend TLS helpers (POSIX sh).
# No secrets are printed. No eval. PUBLIC_HOST is treated as untrusted.
# Requires: openssl CLI for validation.

# Fixed conventional CapRover mount (no env knob per spec).
CAPROVER_BASE="/caprover-letsencrypt"
# Private runtime copies owned by the PgBouncer user.
TLS_RUNTIME_DIR="/run/pgbouncer/tls"
TLS_RUNTIME_CERT="${TLS_RUNTIME_DIR}/fullchain.pem"
TLS_RUNTIME_KEY="${TLS_RUNTIME_DIR}/privkey.pem"
TLS_FINGERPRINT_FILE="${TLS_RUNTIME_DIR}/.fingerprint"

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

# Atomically install validated source cert/key into the private runtime dir.
# Sets 0600 postgres ownership on runtime copies. Source files untouched.
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
  if ! cat "${_i_key}" > "${_i_tmp_key}" 2>/dev/null; then
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
  # Record content fingerprint for renewal detection.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${TLS_RUNTIME_CERT}" "${TLS_RUNTIME_KEY}" 2>/dev/null | awk '{print $1}' | tr '\n' ':' > "${TLS_FINGERPRINT_FILE}.tmp" 2>/dev/null || true
    mv -f "${TLS_FINGERPRINT_FILE}.tmp" "${TLS_FINGERPRINT_FILE}" 2>/dev/null || true
    chmod 0600 "${TLS_FINGERPRINT_FILE}" 2>/dev/null || true
  fi
  return 0
}

# Read stored runtime fingerprint (empty when none).
read_runtime_fingerprint() {
  if [ -f "${TLS_FINGERPRINT_FILE}" ]; then
    tr -d '\n' < "${TLS_FINGERPRINT_FILE}" 2>/dev/null || printf ''
  else
    printf ''
  fi
}
