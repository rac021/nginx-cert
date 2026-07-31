#!/usr/bin/env bash
# Failure explanations.
#
# When an authority refuses, the operator sees an acme.sh trace of several
# hundred lines and no indication of what to change. These hints are the
# difference between "it does not work" and a precise next action, so each one
# is pinned by a test against the exact string the authority emits.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   CFG_* are set here to drive the code under test.

_hint_for() {
  CFG_ACME_HOME="${TEST_TMPDIR}/acme"
  NC_LOG_LEVEL=warn acme::_explain_failure "${2:-letsencrypt}" "$1" 2>&1
}

# The case that cost a real afternoon: a filtering appliance accepted the TCP
# connection, let the request through, then cut it. Reported as a plain
# "Connection reset by peer", it is indistinguishable from a closed port unless
# the message says otherwise.
test_distinguishes_a_reset_from_a_closed_port() {
  local out
  out=$(_hint_for "preprod.example.com: Invalid status. Verification error details: 203.0.113.10: Fetching http://preprod.example.com/.well-known/acme-challenge/xyz: Connection reset by peer")
  assert_contains "$out" 'firewall, WAF or IPS'
  assert_contains "$out" 'not a closed port'
  # The readable authority name, not the internal id.
  assert_contains     "$out" "Let's Encrypt reached your server"
  assert_not_contains "$out" 'letsencrypt validation traffic'
  # The hint must hand over a command that reproduces it, not just a theory.
  assert_contains "$out" 'curl -A'
  assert_contains "$out" 'User-Agent'
  # And the two ways out.
  assert_contains "$out" 'another authority'
  assert_contains "$out" 'dns-01'
}

test_reports_a_closed_port_differently() {
  local out
  out=$(_hint_for 'Fetching http://example.com/.well-known/acme-challenge/xyz: Connection refused')
  assert_contains     "$out" 'Nothing accepted the connection on port 80'
  assert_contains     "$out" '-p 80:80'
  assert_not_contains "$out" 'firewall, WAF or IPS'
}

test_explains_a_rejected_contact_address() {
  local out
  out=$(_hint_for '{"type":"urn:ietf:params:acme:error:invalidContact","detail":"contact email has forbidden domain \"example.com\""}')
  assert_contains "$out" 'CERT_EMAIL'
  assert_contains "$out" 'real address'
}

test_explains_a_rate_limit() {
  local out
  out=$(_hint_for 'urn:ietf:params:acme:error:rateLimited: too many certificates already issued')
  assert_contains "$out" 'Quota reached'
  assert_contains "$out" 'CERT_STAGING'
}

test_explains_a_missing_eab() {
  local out
  out=$(_hint_for 'urn:ietf:params:acme:error:externalAccountRequired' actalis)
  assert_contains "$out" 'External Account Binding'
  # The provider table's own note must be surfaced, not a generic sentence.
  assert_contains "$out" 'Actalis customer portal'
}

test_explains_an_unreachable_directory() {
  local out
  out=$(_hint_for 'Cannot init API for https://acme.zerossl.com/v2/DV90' zerossl)
  assert_contains "$out" 'unreachable'
}

test_explains_a_dns_failure() {
  local out
  out=$(_hint_for 'DNS problem: NXDOMAIN looking up A for example.com')
  assert_contains "$out" 'does not resolve publicly'
}

test_stays_quiet_on_an_unrecognised_error() {
  # No invented advice when the cause is unknown: the trace is shown instead.
  local out
  out=$(_hint_for 'some entirely unexpected failure')
  assert_not_contains "$out" 'firewall'
  assert_not_contains "$out" 'Quota reached'
  assert_contains     "$out" 'Full trace'
}

# "unauthorized" at account registration and "unauthorized" at challenge
# validation share a code but nothing else. Sending someone to inspect their
# firewall when the authority wants them to finish creating an account wastes
# an afternoon.
test_separates_a_registration_refusal_from_a_validation_failure() {
  local out
  out=$(_hint_for 'Account registration error: {"type":"urn:ietf:params:acme:error:unauthorized","detail":"Visit https://secure.ssl.com/billing_profiles to add your billing information"}' sslcom)
  assert_contains     "$out" 'refused to create the ACME account'
  assert_contains     "$out" 'not a validation problem'
  assert_not_contains "$out" 'port 80'
}

test_still_points_at_the_network_for_a_validation_failure() {
  local out
  out=$(_hint_for 'preprod.example.com: Invalid status. Verification error details: urn:ietf:params:acme:error:unauthorized')
  assert_contains "$out" 'port 80'
}
