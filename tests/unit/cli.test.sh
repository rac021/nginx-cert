#!/usr/bin/env bash
# `new`: each option becomes the CERT_* variable it stands for, and nothing else.
# shellcheck shell=bash

# Runs the parser in a subshell and prints the CERT_* it exported.
_env_of() {
  ( unset CERT_DOMAINS CERT_EMAIL CERT_CHALLENGE CERT_PROVIDER CERT_KEY_TYPE \
          CERT_DNS_PROVIDER CERT_STAGING CERT_FORCE_RENEW CERT_FALLBACK_SELFSIGNED
    NC_LOG_LEVEL=error cli::new_to_env "$@" || exit 1
    env | grep '^CERT_' | sort )
}

test_every_option_maps_to_its_variable() {
  local out
  out=$(_env_of --domain app.example.com --email a@b.co --challenge tls-alpn-01 \
          --provider zerossl --key-type ec-384 --dns dns_cf --staging --force)
  assert_contains "$out" 'CERT_DOMAINS=app.example.com' &&
    assert_contains "$out" 'CERT_EMAIL=a@b.co' &&
    assert_contains "$out" 'CERT_CHALLENGE=tls-alpn-01' &&
    assert_contains "$out" 'CERT_PROVIDER=zerossl' &&
    assert_contains "$out" 'CERT_KEY_TYPE=ec-384' &&
    assert_contains "$out" 'CERT_DNS_PROVIDER=dns_cf' &&
    assert_contains "$out" 'CERT_STAGING=true' &&
    assert_contains "$out" 'CERT_FORCE_RENEW=true'
}

test_several_domains_make_one_certificate() {
  assert_contains "$(_env_of -d example.com -d www.example.com)" 'CERT_DOMAINS=example.com,www.example.com'
}

test_the_equals_form_is_accepted() {
  assert_contains "$(_env_of --domain=app.example.com --challenge=http-01)" 'CERT_CHALLENGE=http-01'
}

test_no_self_signed_fallback_unless_asked() {
  assert_contains "$(_env_of -d app.example.com)" 'CERT_FALLBACK_SELFSIGNED=false' &&
    assert_contains "$(_env_of -d app.example.com --fallback-selfsigned)" 'CERT_FALLBACK_SELFSIGNED=true'
}

test_a_domain_is_required() {
  assert_fails _env_of --email a@b.co
}

test_an_unknown_option_is_refused() {
  assert_fails _env_of -d app.example.com --eab-kid secret
}

test_an_option_without_its_value_is_refused() {
  assert_fails _env_of -d app.example.com --challenge &&
    assert_fails _env_of --domain --staging
}
