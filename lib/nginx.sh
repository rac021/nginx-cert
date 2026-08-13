#!/usr/bin/env bash
# lib/nginx.sh — Configuration rendering, validation, reload.
#
# The configuration is never edited in place (no sed at startup): it is fully
# regenerated from the templates, then validated with "nginx -t" before being
# put into service. An invalid configuration therefore cannot reach a running
# nginx.
# shellcheck shell=bash

[[ -n ${NC_LIB_NGINX_SH:-} ]] && return 0
readonly NC_LIB_NGINX_SH=1

NC_NGINX_CONF="${NC_NGINX_CONF:-/etc/nginx/nginx.conf}"
NC_NGINX_CONFD="${NC_NGINX_CONFD:-/etc/nginx/conf.d}"
NC_NGINX_SNIPPETS="${NC_NGINX_SNIPPETS:-/etc/nginx/snippets}"
NC_GENERATED_PREFIX='nginx-cert.'

# Our own configuration puts the pid under /var/run/nginx/, but a user who
# brings their own nginx.conf (CERT_MANAGE_NGINX=false) usually keeps the stock
# location -- so both are accepted.
readonly NC_NGINX_PID_FILES=(/var/run/nginx/nginx.pid /var/run/nginx.pid)

nginx::pid() {
  local f
  for f in "${NC_NGINX_PID_FILES[@]}"; do
    [[ -s $f ]] && { cat "$f"; return 0; }
  done
  return 1
}

nginx::is_running() {
  local pid; pid=$(nginx::pid) || return 1
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

# --- Rendering -------------------------------------------------------------

nginx::render() {
  mkdir -p "$NC_NGINX_CONFD" "$NC_NGINX_SNIPPETS" "$CFG_WEBROOT" /var/www/html

  nginx::_render_tls_policy || return 1

  if util::is_true "$CFG_MANAGE_NGINX"; then
    nginx::_render_main || return 1
  else
    log::debug "CERT_MANAGE_NGINX=false: ${NC_NGINX_CONF} left untouched."
  fi

  # We only ever delete files we generated ourselves; anything the user drops
  # into conf.d is left alone.
  rm -f "${NC_NGINX_CONFD}/${NC_GENERATED_PREFIX}"*.conf

  # Rendered unconditionally, including when CERT_ENABLE=false. This block
  # carries /healthz -- which the Docker HEALTHCHECK polls -- and the
  # HTTP-to-HTTPS redirect. Skipping it with certificate management disabled
  # left the container permanently unhealthy. The challenge locations simply
  # return 404 when nothing uses them, which costs nothing.
  #
  # Its failure is fatal like every other render here. It used not to be, so a
  # conf.d that could not be written (a ":ro" bind mount, a wrong owner) took
  # /healthz, the redirect and the ACME challenge away while nginx::render
  # still returned 0 and the container reported a successful start.
  nginx::_render_http_extras || return 1
  nginx::_render_acme || return 1

  if util::is_true "$CFG_MANAGE_VHOSTS"; then
    nginx::_render_sites || return 1
  fi

  return 0
}

nginx::_render_main() {
  local real_ip_directives='' has_real_ip=false
  if [[ -n $CFG_REAL_IP_FROM ]]; then
    has_real_ip=true
    local -a cidrs=(); util::split_into cidrs ',' "$CFG_REAL_IP_FROM"
    local c
    for c in "${cidrs[@]}"; do real_ip_directives+="    set_real_ip_from ${c};"$'\n'; done
    real_ip_directives=${real_ip_directives%$'\n'}
  fi

  template::render_to "${NC_ROOT}/templates/nginx.conf.tpl" "$NC_NGINX_CONF" \
    "WORKER_CONNECTIONS=$CFG_WORKER_CONNECTIONS" \
    "CLIENT_MAX_BODY_SIZE=$CFG_CLIENT_MAX_BODY_SIZE" \
    "RESOLVER=$CFG_RESOLVER" \
    "ACCESS_LOG=$CFG_ACCESS_LOG" \
    "REAL_IP=$has_real_ip" \
    "REAL_IP_DIRECTIVES=$real_ip_directives" || return 1
  template::assert_complete "$NC_NGINX_CONF"
}

nginx::_render_tls_policy() {
  local modern=false
  [[ $CFG_SSL_POLICY == modern ]] && modern=true
  template::render_to "${NC_ROOT}/templates/tls-policy.conf.tpl" \
    "${NC_NGINX_SNIPPETS}/nginx-cert-tls.conf" \
    "MODERN=$modern" "SSL_POLICY=$CFG_SSL_POLICY" || return 1
  template::assert_complete "${NC_NGINX_SNIPPETS}/nginx-cert-tls.conf"
}

# http-level directives the generated servers depend on.
#
# Our own nginx.conf includes the snippet directly. With CERT_MANAGE_NGINX=false
# we cannot touch nginx.conf, so the snippet is pulled in through conf.d --
# which the user's configuration includes at http level, exactly where a "map"
# belongs. Without this, a generated server block referenced
# $connection_upgrade and nginx refused to start.
nginx::_render_http_extras() {
  local default_target='https://$host$request_uri'
  [[ $CFG_HTTPS_PORT != 443 ]] && default_target='https://$host:'"${CFG_HTTPS_PORT}"'$request_uri'
  util::is_true "$CFG_HTTP_REDIRECT" || default_target=''

  # Hosts that opted out per certificate. nginx matches server names here, so
  # one line per name, not per lineage.
  local opted_out='' name d
  for name in ${NC_SPEC_NAMES[@]+"${NC_SPEC_NAMES[@]}"}; do
    util::is_true "${NC_SPEC_REDIRECT[$name]:-true}" && continue
    local -a doms=(); read -r -a doms <<<"${NC_SPEC_DOMAINS[$name]}"
    for d in ${doms[@]+"${doms[@]}"}; do
      # A wildcard server name is written "*.example.com" in a map key too.
      opted_out+="    \"${d}\"   \"\";"$'\n'
    done
  done
  opted_out=${opted_out%$'\n'}

  template::render_to "${NC_ROOT}/templates/http-extras.conf.tpl" \
    "${NC_NGINX_SNIPPETS}/nginx-cert-http.conf" \
    "DEFAULT_TARGET=$default_target" \
    "NO_REDIRECT_HOSTS=$opted_out" || return 1
  template::assert_complete "${NC_NGINX_SNIPPETS}/nginx-cert-http.conf" || return 1

  local bridge="${NC_NGINX_CONFD}/${NC_GENERATED_PREFIX}00-http.conf"
  if util::is_true "$CFG_MANAGE_NGINX"; then
    # nginx.conf already includes both; a second include would redefine the map.
    rm -f "$bridge"
    return 0
  fi
  # The TLS policy travels through the same bridge, and for the same reason.
  # It was rendered to disk and included by nothing: with CERT_MANAGE_NGINX=false
  # the generated servers ran on nginx's compiled-in defaults, so
  # CERT_SSL_POLICY=modern still completed a TLS 1.2 handshake and
  # "ssl_session_tickets off" / "ssl_early_data off" were never applied. A
  # setting that looks active and is not is the failure mode this program
  # exists to avoid.
  printf '# Generated by nginx-cert -- do not edit, changes are overwritten.\ninclude %s/nginx-cert-http.conf;\ninclude %s/nginx-cert-tls.conf;\n' \
    "$NC_NGINX_SNIPPETS" "$NC_NGINX_SNIPPETS" | util::atomic_write "$bridge" 0644
}

nginx::_render_acme() {
  # The ACME server owns "default_server" on the HTTP port: it answers requests
  # whose Host header matches no declared server.
  local dest="${NC_NGINX_CONFD}/${NC_GENERATED_PREFIX}00-acme.conf"
  template::render_to "${NC_ROOT}/templates/acme.conf.tpl" "$dest" \
    "HTTP_PORT=$CFG_HTTP_PORT" \
    "DEFAULT_SUFFIX= default_server" \
    "WEBROOT=$CFG_WEBROOT" || return 1
  template::assert_complete "$dest"
}

nginx::_render_sites() {
  local index=10 first=1 name
  for name in ${NC_SPEC_NAMES[@]+"${NC_SPEC_NAMES[@]}"}; do
    # A server referencing a missing certificate prevents nginx from starting.
    if ! certs::exists "$name"; then
      log::warn "No certificate for '${name}': its HTTPS server is not generated."
      continue
    fi
    nginx::_render_one_site "$name" "$index" "$first" || return 1
    first=0
    index=$((index + 1))
  done
  return 0
}

nginx::_render_one_site() {
  local name=$1 index=$2 is_first=$3
  local dest; dest=$(printf '%s/%s%02d-%s.conf' "$NC_NGINX_CONFD" "$NC_GENERATED_PREFIX" "$index" "$name")

  local upstream=${NC_SPEC_UPSTREAM[$name]:-}
  local has_upstream=false upstream_scheme=http upstream_hostport=''
  if [[ -n $upstream ]]; then
    has_upstream=true
    case $upstream in
      https://*) upstream_scheme=https; upstream_hostport=${upstream#https://} ;;
      http://*)  upstream_scheme=http;  upstream_hostport=${upstream#http://} ;;
      *)         upstream_scheme=http;  upstream_hostport=$upstream ;;
    esac
    upstream_hostport=${upstream_hostport%/}
  fi

  local hsts_value=${NC_SPEC_HSTS[$name]:-$CFG_HSTS}
  local hsts=true
  case "$(util::lower "$hsts_value")" in
    ''|off|false|no|0|disabled) hsts=false ;;
  esac

  local http2=off; util::is_true "$CFG_HTTP2" && http2=on
  local http3=false; util::is_true "$CFG_HTTP3" && http3=true

  # "default_server" and "reuseport" may appear only once per address/port
  # pair: only the first generated server carries them.
  local default_suffix='' quic_extra=''
  if ((is_first)); then
    default_suffix=' default_server'
    quic_extra=' reuseport'
  fi

  local no_stapling=false
  certs::is_selfsigned "$name" && no_stapling=true

  local -a doms=(); read -r -a doms <<<"${NC_SPEC_DOMAINS[$name]}"

  template::render_to "${NC_ROOT}/templates/site.conf.tpl" "$dest" \
    "NO_STAPLING=$no_stapling" \
    "CERT_NAME=$name" \
    "SERVER_NAMES=${doms[*]}" \
    "HTTPS_PORT=$CFG_HTTPS_PORT" \
    "DEFAULT_SUFFIX=$default_suffix" \
    "QUIC_EXTRA=$quic_extra" \
    "HTTP2=$http2" \
    "HTTP3=$http3" \
    "FULLCHAIN=$(config::fullchain_path "$name")" \
    "PRIVKEY=$(config::privkey_path "$name")" \
    "CHAIN=$(config::chain_path "$name")" \
    "WEBROOT=$CFG_WEBROOT" \
    "HSTS=$hsts" \
    "HSTS_VALUE=$hsts_value" \
    "HAS_UPSTREAM=$has_upstream" \
    "UPSTREAM_SCHEME=$upstream_scheme" \
    "UPSTREAM_HOSTPORT=$upstream_hostport" \
    "PROXY_TIMEOUT=$CFG_PROXY_TIMEOUT" \
    "PROXY_CONNECT_TIMEOUT=$CFG_PROXY_CONNECT_TIMEOUT" || return 1
  template::assert_complete "$dest"
}

# --- Validation and lifecycle ----------------------------------------------

nginx::test() {
  local out rc=0
  out=$(nginx -t 2>&1) || rc=$?
  if ((rc == 0)); then
    log::debug "nginx configuration is valid."
    return 0
  fi
  log::error "Invalid nginx configuration:"
  log::quote error "$out"
  return "$EX_NGINX"
}

nginx::reload() {
  nginx::is_running || { log::debug "nginx is not running: nothing to reload."; return 0; }
  nginx::test || return "$EX_NGINX"
  if nginx -s reload 2>/dev/null; then
    log::ok "nginx configuration reloaded."
    return 0
  fi
  log::error "Could not reload nginx."
  return "$EX_NGINX"
}

# Graceful shutdown: SIGQUIT lets in-flight requests finish, unlike SIGTERM
# which cuts them immediately.
nginx::quit() {
  nginx::is_running || return 0
  local pid; pid=$(nginx::pid)
  log::info "Gracefully stopping nginx (SIGQUIT to PID ${pid})…"
  kill -QUIT "$pid" 2>/dev/null || return 0
  local waited=0 limit=${NC_SHUTDOWN_TIMEOUT:-25}
  while nginx::is_running && ((waited < limit)); do
    sleep 1; waited=$((waited + 1))
  done
  if nginx::is_running; then
    log::warn "nginx did not stop within ${limit}s: forcing shutdown."
    kill -TERM "$pid" 2>/dev/null || true
  else
    log::ok "nginx stopped cleanly after ${waited}s."
  fi
}
