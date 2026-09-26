#!/bin/sh
# PgPoolito HTTP documentation UI helpers (POSIX sh).
# Generates a static informational page with no secrets, no login,
# no database API, no credential submission, no JavaScript framework.
# All displayed configuration values are HTML-escaped.

# Escape &, <, >, ", ' for HTML text/attribute contexts. No eval.
html_escape() {
  _e_rest="$1"
  _e_acc=""
  # Process character by character without external deps beyond POSIX.
  # Use sed for the four replacements in a safe fixed order (& first).
  printf '%s' "${_e_rest}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# Map internal TLS state to a clear display string.
tls_display_string() {
  case "$1" in
    disabled) printf 'Disabled' ;;
    plaintext) printf 'Not available - plaintext currently enabled' ;;
    active) printf 'Available and required' ;;
    waiting) printf 'Required - waiting for certificate' ;;
    prepared) printf 'Preparing secure PostgreSQL endpoint' ;;
    manual-require) printf 'Available and required (manual configuration)' ;;
    manual) printf 'Enabled (manual configuration)' ;;
    *) printf 'Not available - plaintext currently enabled' ;;
  esac
}

# Connection query parameters for the displayed example.
# Automatic active TLS uses the psql/libpq operating-system trust-store
# form so the copyable example works out of the box: the `&` below is
# HTML-escaped to `&amp;` at render time, so the browser still shows and
# copies a literal `&`. waiting/prepared show the same future libpq form
# but explicitly marked not yet available (see note below). Plaintext
# states stay on sslmode=disable with no trust-store parameter.
# Manual modes keep their previous output: a manual certificate is not
# necessarily publicly trusted, so no OS store is implied there.
ui_conn_params_for_state() {
  case "$1" in
    active|waiting|prepared) printf 'sslmode=verify-full&sslrootcert=system' ;;
    manual) printf 'sslmode=%s' "${2:-disable}" ;;
    manual-require) printf 'sslmode=verify-full' ;;
    *) printf 'sslmode=disable' ;;
  esac
}

# Generate /var/www/index.html.
# Args: tls_state public_host listen_port db_name
# When public_host is empty the page derives the host in the browser
# (window.location.hostname) and never guesses a certificate.
# The page always shows literal <USERNAME>/<PASSWORD> placeholders and
# never embeds PGBOUNCER_*/DB_* secrets.
generate_ui_page() {
  _u_state="$1"
  _u_host="$2"
  _u_port="$3"
  _u_db="$4"
  _u_out="${5:-/var/www/index.html}"

  _u_display=$(tls_display_string "${_u_state}")
  _u_host_esc=$(html_escape "${_u_host}")
  _u_port_esc=$(html_escape "${_u_port}")
  _u_db_esc=$(html_escape "${_u_db}")
  _u_display_esc=$(html_escape "${_u_display}")

  # Manual sslmode passthrough for display only (no secrets).
  _u_manual_sslmode="disable"
  case "${CLIENT_TLS_SSLMODE:-}" in
    allow|prefer|require|verify-ca|verify-full|disable)
      _u_manual_sslmode="${CLIENT_TLS_SSLMODE}"
      ;;
  esac
  _u_conn_params=$(ui_conn_params_for_state "${_u_state}" "${_u_manual_sslmode}")
  _u_conn_params_esc=$(html_escape "${_u_conn_params}")

  # Host block: static when PUBLIC_HOST is set, dynamic via browser
  # hostname otherwise (no certificate guessing involved).
  if [ -n "${_u_host}" ]; then
    _u_host_block="<p class=\"v\"><span class=\"pgpooler-host\">${_u_host_esc}</span></p>"
    _u_conn_host_esc="${_u_host_esc}"
    _u_js=""
  else
    _u_host_block="<p class=\"v\"><span class=\"pgpooler-host\" data-dynamic-host>this host</span></p>"
    _u_conn_host_esc="this host"
    _u_js="<script>(function(){try{var h=window.location.hostname||'localhost';var els=document.querySelectorAll('[data-dynamic-host]');for(var i=0;i<els.length;i++){els[i].textContent=h;}var c=document.getElementById('connstr');if(c){var t=c.textContent||'';c.textContent=t.split('this host').join(h);}}catch(e){}})();</script>"
  fi

  # TLS note: the active note documents the psql/libpq OS trust-store
  # form; waiting/prepared show the future string but explicitly mark the
  # endpoint as not yet available so it is never presented as usable.
  case "${_u_state}" in
    active)
      _u_tls_note="<p class=\"note\">For psql/libpq, use sslmode=verify-full with sslrootcert=system to verify the certificate and hostname using the operating system trust store. Other PostgreSQL drivers may use different CA/trust-store settings.</p>"
      ;;
    manual-require)
      _u_tls_note="<p class=\"note\">Use hostname verification on the client, for example <code>sslmode=verify-full</code>.</p>"
      ;;
    prepared)
      _u_tls_note="<p class=\"note\">The secure PostgreSQL endpoint is being prepared and is not yet available. Once ready, for psql/libpq use sslmode=verify-full with sslrootcert=system to verify using the operating system trust store.</p>"
      ;;
    waiting)
      _u_tls_note="<p class=\"note\">The secure PostgreSQL endpoint is not yet available; waiting for a certificate. Once ready, for psql/libpq use sslmode=verify-full with sslrootcert=system to verify using the operating system trust store.</p>"
      ;;
    *)
      _u_tls_note="<p class=\"note\">TLS is not currently active for PostgreSQL connections. The example below uses <code>sslmode=disable</code>.</p>"
      ;;
  esac

  mkdir -p "$(dirname "${_u_out}")" 2>/dev/null || true
  cat > "${_u_out}.tmp" <<HTML_EOF
<!DOCTYPE html>
<html lang="en-US">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PgPoolito</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:#0f172a;color:#e2e8f0}
.wrap{max-width:720px;margin:0 auto;padding:32px 20px}
.card{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:24px}
h1{margin:0 0 4px;font-size:28px}
.sub{margin:0 0 20px;color:#94a3b8}
.grid{display:grid;grid-template-columns:160px 1fr;gap:8px 16px;margin:16px 0}
.k{color:#94a3b8}
.v{margin:0;word-break:break-word}
code.conn{display:block;background:#0b1220;border:1px solid #334155;border-radius:8px;padding:12px;overflow-x:auto;white-space:pre-wrap;word-break:break-all}
.note{color:#94a3b8;font-size:14px}
a{color:#7dd3fc}
</style>
</head>
<body>
<div class="wrap">
<div class="card">
<h1>PgPoolito</h1>
<p class="sub">PostgreSQL Connection Pooler</p>
<div class="grid">
<div class="k">Host</div>
<div>${_u_host_block}</div>
<div class="k">Port</div>
<div><p class="v">${_u_port_esc}</p></div>
<div class="k">Database</div>
<div><p class="v">${_u_db_esc}</p></div>
<div class="k">TLS</div>
<div><p class="v">${_u_display_esc}</p></div>
</div>
<p class="k">Connection string</p>
<code class="conn" id="connstr">postgresql://&lt;USERNAME&gt;:&lt;PASSWORD&gt;@${_u_conn_host_esc}:${_u_port_esc}/${_u_db_esc}?${_u_conn_params_esc}</code>
${_u_tls_note}
<p class="note">PostgreSQL protocol on port ${_u_port_esc}. Documentation UI on port 8080. No login is required for this page and it never asks for credentials.</p>
</div>
</div>
${_u_js}
</body>
</html>
HTML_EOF
  mv -f "${_u_out}.tmp" "${_u_out}" 2>/dev/null || return 1
  chmod 0644 "${_u_out}" 2>/dev/null || true
  return 0
}
