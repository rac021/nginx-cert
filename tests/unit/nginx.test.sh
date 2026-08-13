#!/usr/bin/env bash
# Rendering of the http-level snippet: the redirect map is the one generated
# block whose contents depend on every declared certificate at once.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   The CFG_* and NC_SPEC_* variables are set here to drive the code under
#   test; shellcheck cannot see that the production modules read them.

_render_extras() {
  NC_NGINX_SNIPPETS="${TEST_TMPDIR}/snippets-$$-${RANDOM}"
  NC_NGINX_CONFD="${TEST_TMPDIR}/confd-$$-${RANDOM}"
  mkdir -p "$NC_NGINX_SNIPPETS" "$NC_NGINX_CONFD"
  CFG_MANAGE_NGINX=true
  CFG_HTTPS_PORT=${CFG_HTTPS_PORT:-443}
  nginx::_render_http_extras >/dev/null 2>&1 || return 1
  cat "${NC_NGINX_SNIPPETS}/nginx-cert-http.conf"
}

# usage: _declare <name> <domains> <redirect>
_declare() {
  NC_SPEC_NAMES+=("$1")
  NC_SPEC_DOMAINS[$1]=$2
  NC_SPEC_REDIRECT[$1]=$3
}

_reset() {
  NC_SPEC_NAMES=(); NC_SPEC_DOMAINS=(); NC_SPEC_REDIRECT=()
  CFG_HTTP_REDIRECT=true; CFG_HTTPS_PORT=443
}

# --- the map default follows the global setting ----------------------------

test_the_map_default_carries_the_redirect_target() {
  _reset
  local out; out=$(_render_extras)
  assert_contains "$out" 'default   "https://$host$request_uri"'
}

test_the_map_default_is_empty_when_the_redirect_is_off() {
  _reset; CFG_HTTP_REDIRECT=false
  local out; out=$(_render_extras)
  assert_contains "$out" 'default   ""'
}

test_a_non_standard_https_port_reaches_the_target() {
  _reset; CFG_HTTPS_PORT=8443
  local out; out=$(_render_extras)
  assert_contains "$out" 'https://$host:8443$request_uri'
}

# --- only the certificates that disagree get a line ------------------------

test_a_certificate_agreeing_with_the_default_adds_no_line() {
  _reset
  _declare keep.test 'keep.test www.keep.test' true
  local out; out=$(_render_extras)
  assert_not_contains "$out" 'keep.test"'
}

test_redirect_false_opts_a_host_out_of_a_global_redirect() {
  _reset
  _declare plain.test 'plain.test' false
  local out; out=$(_render_extras)
  assert_contains "$out" '"plain.test"   "";'
}

# The direction that did not exist. Only the opt-out was ever emitted, so with
# CERT_HTTP_REDIRECT=false the map default was empty and a per-certificate
# redirect=true had nothing to turn it back on.
test_redirect_true_opts_a_host_into_a_globally_disabled_redirect() {
  _reset; CFG_HTTP_REDIRECT=false
  _declare secure.test 'secure.test' true
  local out; out=$(_render_extras)
  assert_contains "$out" 'default   ""'
  assert_contains "$out" '"secure.test"   "https://$host$request_uri";'
}

test_the_opt_in_direction_honours_a_non_standard_port() {
  _reset; CFG_HTTP_REDIRECT=false; CFG_HTTPS_PORT=8443
  _declare secure.test 'secure.test' true
  local out; out=$(_render_extras)
  assert_contains "$out" '"secure.test"   "https://$host:8443$request_uri";'
}

# Both directions in one configuration: the map has to describe each host, not
# a single global exception rule.
test_both_directions_coexist() {
  _reset; CFG_HTTP_REDIRECT=false
  _declare secure.test 'secure.test' true
  _declare plain.test  'plain.test'  false
  local out; out=$(_render_extras)
  assert_contains     "$out" '"secure.test"   "https://$host$request_uri";'
  assert_not_contains "$out" '"plain.test"'  'a host agreeing with the default needs no line'
}

# nginx matches server names, not lineage names: every domain of a certificate
# needs its own key.
test_every_domain_of_a_certificate_gets_its_own_key() {
  _reset
  _declare site 'a.test b.test *.c.test' false
  local out; out=$(_render_extras)
  local d
  for d in 'a.test' 'b.test' '*.c.test'; do
    assert_contains "$out" "\"${d}\"   \"\";"
  done
}

# Wildcard keys only match through the "hostnames" parameter; without it
# "*.c.test" was compared literally against the Host header.
test_the_map_declares_hostnames() {
  _reset
  local out; out=$(_render_extras)
  assert_contains "$out" 'hostnames;'
}

test_no_placeholder_survives_rendering() {
  _reset
  _declare plain.test 'plain.test' false
  local out; out=$(_render_extras)
  assert_not_contains "$out" '%%'
}
