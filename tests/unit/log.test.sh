#!/usr/bin/env bash
# Secret redaction is a security guarantee, not a convenience: version 1
# printed the ZeroSSL API key in clear text into docker logs.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   NC_LOG_* are set here to drive log.sh; shellcheck cannot see those reads.

test_masks_a_registered_secret() {
  ( NC_SECRETS=()
    log::secret 'very-secret-api-key'
    assert_eq 'token=********' "$(log::redact 'token=very-secret-api-key')" )
}

test_masks_every_occurrence() {
  ( NC_SECRETS=()
    log::secret 'password123'
    assert_not_contains "$(log::redact 'a=password123 b=password123')" 'password123' )
}

test_masks_inside_emitted_logs() {
  ( NC_SECRETS=(); NC_LOG_LEVEL=info
    log::secret 'ultra-confidential-hmac'
    local out; out=$(log::info 'EAB: ultra-confidential-hmac' 2>&1)
    assert_not_contains "$out" 'ultra-confidential-hmac'
    assert_contains     "$out" '********' )
}

test_ignores_values_that_are_too_short() {
  # Masking a 2-character string would redact fragments of ordinary words
  # throughout the logs.
  ( NC_SECRETS=()
    log::secret 'ab'
    assert_eq 'value ab here' "$(log::redact 'value ab here')" )
}

test_does_not_fail_on_empty_secrets() {
  # Regression: an implicit non-zero return aborted any caller running under
  # "set -e" when no secret variable was defined.
  ( set -e; NC_SECRETS=(); log::secret '' '' ''; )
  assert_eq '0' "$?"
}

test_partially_masks_for_display() {
  local out; out=$(log::mask 'abcdefghijklmnop')
  assert_contains "$out" 'abc'
  assert_contains "$out" 'nop'
  assert_not_contains "$out" 'defghijkl'
  assert_eq '********' "$(log::mask 'short')"
  assert_eq '(unset)'  "$(log::mask '')"
}

test_honours_the_log_level() {
  ( NC_LOG_LEVEL=warn
    assert_eq '' "$(log::info 'must not appear' 2>&1)"
    assert_contains "$(log::error 'must appear' 2>&1)" 'must appear' )
}

test_emits_valid_json_when_asked() {
  ( NC_LOG_FORMAT=json; NC_LOG_LEVEL=info
    local out; out=$(log::info 'message with "quotes"' 2>&1)
    assert_contains "$out" '"level":"info"'
    assert_contains "$out" '\"quotes\"'
    if command -v jq >/dev/null; then
      assert_ok bash -c "printf '%s' '$out' | jq -e . >/dev/null"
    fi )
}
