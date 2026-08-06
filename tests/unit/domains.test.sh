#!/usr/bin/env bash
# Name classification: it decides the challenge, the eligible authorities and
# the fallback. A mistake here propagates everywhere else.
# shellcheck shell=bash

test_classifies_public_domains() {
  assert_eq 'fqdn' "$(domain::kind example.com)"
  assert_eq 'fqdn' "$(domain::kind sub.domain.example.co.uk)"
  assert_eq 'fqdn' "$(domain::kind xn--tst-bma.example.com)"
}

test_normalises_case() {
  assert_eq 'fqdn' "$(domain::kind EXAMPLE.COM)"
}

test_recognises_wildcards() {
  assert_eq 'wildcard' "$(domain::kind '*.example.com')"
  assert_eq 'invalid'  "$(domain::kind '*.*.example.com')" 'nested wildcard'
  assert_eq 'invalid'  "$(domain::kind 'www.*.example.com')" 'wildcard in an inner label'
  assert_eq 'invalid'  "$(domain::kind '*.com')" 'wildcard over a single label'
}

test_recognises_public_ipv4() {
  assert_eq 'ip4' "$(domain::kind 203.0.113.10)"
  assert_eq 'ip4' "$(domain::kind 8.8.8.8)"
}

test_classifies_private_ipv4_as_internal() {
  local ip
  for ip in 10.0.0.1 172.16.5.4 192.168.1.1 169.254.1.1 100.64.0.1; do
    assert_eq 'internal' "$(domain::kind "$ip")" "$ip should be internal"
  done
}

test_classifies_loopback_as_localhost() {
  assert_eq 'localhost' "$(domain::kind 127.0.0.1)"
  assert_eq 'localhost' "$(domain::kind 127.1.2.3)"
  assert_eq 'localhost' "$(domain::kind '::1')"
  assert_eq 'localhost' "$(domain::kind localhost)"
  assert_eq 'localhost' "$(domain::kind app.localhost)"
}

test_rejects_out_of_range_ipv4() {
  # 999.1.1.1 is not an address: it must not be mistaken for one.
  assert_ne 'ip4' "$(domain::kind 999.1.1.1)"
}

test_recognises_reserved_tlds() {
  local d
  for d in machine.local app.test svc.internal box.lan srv.invalid; do
    assert_eq 'internal' "$(domain::kind "$d")" "$d should be internal"
  done
}

test_treats_a_dotless_name_as_internal() {
  assert_eq 'internal' "$(domain::kind myserver)"
}

test_rejects_malformed_names() {
  assert_eq 'invalid' "$(domain::kind '')"
  assert_eq 'invalid' "$(domain::kind 'example..com')"
  assert_eq 'invalid' "$(domain::kind '-example.com')"
  assert_eq 'invalid' "$(domain::kind 'example.com-')"
  assert_eq 'invalid' "$(domain::kind 'ex ample.com')"
}

test_aggregates_to_the_strongest_constraint() {
  assert_eq 'fqdn'     "$(domain::aggregate_kind a.example.com b.example.com)"
  assert_eq 'wildcard' "$(domain::aggregate_kind '*.example.com' example.com)"
  assert_eq 'internal' "$(domain::aggregate_kind example.com localhost)"
  assert_eq 'ip'       "$(domain::aggregate_kind 203.0.113.1)"
  # No authority issues a certificate covering both an IP and an FQDN.
  assert_eq 'invalid'  "$(domain::aggregate_kind 203.0.113.1 example.com)"
}

test_builds_sans_with_the_right_type() {
  assert_eq 'DNS:example.com' "$(domain::san_string example.com)"
  # The subtle case: a private IP is classified "internal" but is still an IP
  # address in a SAN. Emitting "DNS:192.168.1.1" yields a certificate no client
  # will accept.
  assert_eq 'IP:192.168.1.1' "$(domain::san_string 192.168.1.1)"
  assert_eq 'IP:203.0.113.9' "$(domain::san_string 203.0.113.9)"
  assert_contains "$(domain::san_string localhost)" 'IP:127.0.0.1'
  assert_contains "$(domain::san_string '*.example.com' example.com)" 'DNS:*.example.com'
}

test_identifies_when_dns01_is_required() {
  assert_ok    domain::requires_dns01 wildcard
  assert_fails domain::requires_dns01 fqdn
}

test_identifies_publicly_certifiable_names() {
  assert_ok    domain::is_acme_capable fqdn
  assert_ok    domain::is_acme_capable wildcard
  assert_ok    domain::is_acme_capable ip4
  assert_fails domain::is_acme_capable internal
  assert_fails domain::is_acme_capable localhost
}

# The aggregate vocabulary is what gets stored per certificate and handed to
# is_acme_capable. It says "ip" where domain::kind says ip4/ip6, and the
# capability test only knew the latter -- so every IP-address certificate was
# judged impossible to certify and never left the local authority.
test_an_ip_certificate_can_be_issued_by_an_authority() {
  assert_eq 'ip' "$(domain::aggregate_kind '203.0.113.10')"
  assert_ok domain::is_acme_capable "$(domain::aggregate_kind '203.0.113.10')"
  assert_ok domain::is_acme_capable "$(domain::aggregate_kind '2001:db8::1')"
}

test_a_private_address_still_stays_local() {
  assert_eq 'internal' "$(domain::aggregate_kind '192.168.1.10')"
  assert_fails domain::is_acme_capable "$(domain::aggregate_kind '192.168.1.10')"
}
