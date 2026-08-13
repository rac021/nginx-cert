#!/usr/bin/env bash
# Declarative authority table and construction of the fallback chain.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   The CFG_* variables are set here to drive the code under test; shellcheck
#   cannot see that the production modules read them.

_reset_providers() {
  CFG_EAB_KID=''; CFG_EAB_HMAC_KEY=''; CFG_ZEROSSL_API_KEY=''
  CFG_PROVIDER_CHAIN='letsencrypt,zerossl,actalis,google'
  CFG_FALLBACK_SELFSIGNED=true
  CFG_STATE_DIR="${TEST_TMPDIR}/state"
  mkdir -p "$CFG_STATE_DIR"
}

_chain() { provider::chain_for "$1" "$2" "${3:-false}" | tr '\n' ' '; }

test_loads_the_provider_table() {
  _reset_providers
  assert_ok provider::exists letsencrypt
  assert_ok provider::exists actalis
  assert_ok provider::exists zerossl
  assert_ok provider::exists google
  assert_fails provider::exists nonexistent
  # Buypass Go SSL shut down its ACME service in April 2026; an entry that can
  # never issue would cost every "auto" run a connection timeout.
  assert_fails provider::exists buypass
}

test_exposes_directory_urls() {
  assert_eq 'https://acme-api.actalis.com/acme/directory'    "$(provider::directory actalis)"
  assert_eq 'https://acme.zerossl.com/v2/DV90'               "$(provider::directory zerossl)"
  assert_eq 'https://acme-v02.api.letsencrypt.org/directory' "$(provider::directory letsencrypt)"
}

test_uses_the_acme_sh_alias_when_one_exists() {
  # acme.sh knows "actalis" natively; providers without an alias fall back to
  # the raw directory URL.
  assert_eq 'actalis' "$(provider::server_arg actalis)"
  # SSL.com has no acme.sh alias either way; the raw URL must be passed.
  assert_eq 'sslcom' "$(provider::server_arg sslcom)"
}

test_declares_which_authorities_require_eab() {
  assert_ok    provider::needs_eab actalis
  assert_ok    provider::needs_eab zerossl
  assert_ok    provider::needs_eab google
  assert_ok    provider::needs_eab certum
  assert_ok    provider::needs_eab sectigo
  assert_fails provider::needs_eab letsencrypt
  # SSL.com's directory advertises externalAccountRequired:false. Declaring it
  # "required" removed it from every chain for anyone without EAB credentials.
  assert_fails provider::needs_eab sslcom
}

test_declares_accepted_name_kinds() {
  assert_ok    provider::supports letsencrypt wildcard
  assert_ok    provider::supports letsencrypt ip
  assert_fails provider::supports actalis wildcard
  assert_fails provider::supports zerossl ip
}

test_skips_authorities_without_eab_credentials() {
  _reset_providers
  local chain; chain=$(_chain auto fqdn)
  assert_contains     "$chain" 'letsencrypt'
  assert_not_contains "$chain" 'zerossl'  # no EAB
  assert_not_contains "$chain" 'actalis'  # no EAB
}

test_keeps_eab_authorities_when_credentials_are_supplied() {
  _reset_providers
  CFG_EAB_KID='some-kid'; CFG_EAB_HMAC_KEY='some-hmac-key'
  local chain; chain=$(_chain auto fqdn)
  assert_contains "$chain" 'zerossl'
  assert_contains "$chain" 'actalis'
}

test_derives_zerossl_eab_from_the_api_key() {
  _reset_providers
  CFG_ZEROSSL_API_KEY='some-api-key'
  assert_ok provider::eab_available zerossl
  # A ZeroSSL key does not unlock Actalis.
  assert_fails provider::eab_available actalis
}

test_honours_the_chain_order() {
  _reset_providers
  CFG_EAB_KID='k'; CFG_EAB_HMAC_KEY='h'
  CFG_PROVIDER_CHAIN='actalis,letsencrypt'
  assert_eq 'actalis letsencrypt selfsigned ' "$(_chain auto fqdn)"
}

test_always_ends_with_selfsigned() {
  _reset_providers
  assert_contains "$(_chain auto fqdn)" 'selfsigned'
}

test_selfsigned_fallback_can_be_disabled() {
  _reset_providers
  CFG_FALLBACK_SELFSIGNED=false
  assert_not_contains "$(_chain auto fqdn)" 'selfsigned'
}

test_skips_authorities_that_cannot_issue_the_requested_kind() {
  _reset_providers
  CFG_EAB_KID='k'; CFG_EAB_HMAC_KEY='h'
  local chain; chain=$(_chain auto wildcard)
  assert_contains     "$chain" 'letsencrypt'
  assert_contains     "$chain" 'zerossl'
  assert_not_contains "$chain" 'actalis'   # single-domain, no wildcard
}

test_switches_to_the_staging_environment() {
  _reset_providers
  assert_contains "$(_chain auto fqdn true)" 'letsencrypt-staging'
}

test_a_pinned_provider_does_not_traverse_the_chain() {
  _reset_providers
  CFG_EAB_KID='k'; CFG_EAB_HMAC_KEY='h'
  assert_eq 'actalis selfsigned ' "$(_chain actalis fqdn)"
}

test_selfsigned_short_circuits_the_whole_chain() {
  _reset_providers
  assert_eq 'selfsigned ' "$(_chain selfsigned fqdn)"
}

test_no_public_authority_for_an_internal_name() {
  _reset_providers
  assert_eq 'selfsigned ' "$(_chain auto internal)"
  assert_eq 'selfsigned ' "$(_chain auto localhost)"
}

# --- CERT_ACME_SERVER as an escape hatch -----------------------------------
#
# With the directory overridden, the table entry is only a carrier: what it
# says about EAB describes a server we are not talking to. Getting this wrong
# silently dropped the credentials and the real server answered
# "externalAccountRequired".

test_explicit_eab_credentials_win_over_the_table() {
  _reset_providers
  CFG_EAB_KID='kid-from-harica'; CFG_EAB_HMAC_KEY='hmac-from-harica'
  CFG_ACME_SERVER='https://acme-v02.harica.gr/acme/uuid/directory'

  # Called directly, not through assert_ok: that helper runs the command in a
  # subshell, where the variables it sets would be lost.
  NC_EAB_KID=''; NC_EAB_HMAC=''
  provider::resolve_eab letsencrypt
  # letsencrypt is declared "eab: no", yet the credentials must be forwarded.
  assert_eq 'kid-from-harica'  "$NC_EAB_KID"
  assert_eq 'hmac-from-harica' "$NC_EAB_HMAC"
}

test_no_eab_is_sent_when_none_is_configured() {
  _reset_providers
  CFG_ACME_SERVER=''
  NC_EAB_KID='stale'; NC_EAB_HMAC='stale'
  provider::resolve_eab letsencrypt
  assert_eq '' "$NC_EAB_KID"
  assert_eq '' "$NC_EAB_HMAC"
}

# ...but without an overridden directory the table is exact, and one
# authority's credentials have no business reaching another. In "auto" mode the
# chain starts at Let's Encrypt, so a KID issued by HARICA was offered to
# Boulder on the way past. Measured against the staging environment Boulder
# accepts the account and ignores the field, so nothing broke -- which is
# precisely why it went unnoticed.
test_credentials_do_not_reach_an_authority_that_asks_for_none() {
  _reset_providers
  CFG_EAB_KID='kid-from-harica'; CFG_EAB_HMAC_KEY='hmac-from-harica'
  CFG_ACME_SERVER=''

  local id
  for id in letsencrypt sslcom; do
    NC_EAB_KID='stale'; NC_EAB_HMAC='stale'
    provider::resolve_eab "$id"
    assert_eq '' "$NC_EAB_KID"  "${id} declares eab: no and must receive nothing"
    assert_eq '' "$NC_EAB_HMAC" "${id} declares eab: no and must receive nothing"
  done
}

test_credentials_still_reach_the_authorities_that_require_them() {
  _reset_providers
  CFG_EAB_KID='kid-from-harica'; CFG_EAB_HMAC_KEY='hmac-from-harica'
  CFG_ACME_SERVER=''

  local id
  for id in harica actalis google certum sectigo; do
    NC_EAB_KID=''; NC_EAB_HMAC=''
    provider::resolve_eab "$id"
    assert_eq 'kid-from-harica' "$NC_EAB_KID" "${id} requires an EAB and must receive it"
  done
}

test_an_overridden_directory_is_named_by_its_host() {
  _reset_providers
  CFG_ACME_SERVER='https://acme-v02.harica.gr/acme/uuid/directory'
  assert_eq 'the ACME server at acme-v02.harica.gr' "$(acme::_authority_label letsencrypt)"
  CFG_ACME_SERVER=''
  assert_eq "Let's Encrypt" "$(acme::_authority_label letsencrypt)"
}

test_harica_is_declared() {
  _reset_providers
  assert_ok provider::exists harica
  assert_ok provider::needs_eab harica
  assert_eq 'https://acme-v02.harica.gr/acme/directory' "$(provider::directory harica)"
  # No acme.sh alias: the raw URL must be passed.
  assert_eq 'https://acme-v02.harica.gr/acme/directory' "$(provider::server_arg harica)"
  assert_contains "$(provider::notes harica)" 'cm.harica.gr'
}

test_pinning_harica_still_ends_on_the_local_fallback() {
  _reset_providers
  CFG_EAB_KID='k'; CFG_EAB_HMAC_KEY='h'
  assert_eq 'harica selfsigned ' "$(_chain harica fqdn)"
}

# Adding an authority must not disturb the ones already in use.
test_letsencrypt_and_zerossl_remain_first_class() {
  _reset_providers
  assert_ok    provider::exists letsencrypt
  assert_ok    provider::exists letsencrypt-staging
  assert_ok    provider::exists zerossl
  assert_fails provider::needs_eab letsencrypt
  assert_ok    provider::needs_eab zerossl
  assert_ok    provider::supports letsencrypt ip
  # Default chain unchanged, Let's Encrypt still first.
  assert_eq 'letsencrypt,zerossl,actalis,google' "$CFG_PROVIDER_CHAIN"
  assert_contains "$(_chain auto fqdn)" 'letsencrypt'
}

test_certum_is_declared_as_a_european_authority() {
  _reset_providers
  assert_ok provider::exists certum
  assert_eq 'https://acme.certum.pl/directory' "$(provider::directory certum)"
  # No acme.sh alias: the raw URL is passed.
  assert_eq 'https://acme.certum.pl/directory' "$(provider::server_arg certum)"
  # Free tier is one domain plus www, so no wildcard.
  assert_fails provider::supports certum wildcard
}

# Skipping one candidate of an automatic chain is routine and stays at debug
# level. Skipping the provider the operator explicitly named must be loud:
# otherwise the run silently ends on a self-signed certificate.
test_warns_when_a_pinned_provider_is_skipped() {
  _reset_providers
  local out
  out=$( NC_LOG_LEVEL=warn provider::chain_for actalis wildcard false 2>&1 >/dev/null )
  assert_contains "$out" 'CERT_PROVIDER=actalis was skipped'
  assert_contains "$out" "does not issue 'wildcard'"
}

test_warns_when_a_pinned_provider_lacks_eab() {
  _reset_providers
  local out
  out=$( NC_LOG_LEVEL=warn provider::chain_for actalis fqdn false 2>&1 >/dev/null )
  assert_contains "$out" 'CERT_PROVIDER=actalis was skipped'
  assert_contains "$out" 'EAB credentials are missing'
}

test_an_automatic_chain_stays_quiet_about_skipped_candidates() {
  _reset_providers
  local out
  out=$( NC_LOG_LEVEL=warn provider::chain_for auto fqdn false 2>&1 >/dev/null )
  assert_not_contains "$out" 'was skipped'
}
