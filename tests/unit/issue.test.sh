#!/usr/bin/env bash
# The post-failure backoff: the one piece of policy that decides how long a
# site stays on whatever certificate it currently has.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   The CFG_* variables are set here to drive the code under test; shellcheck
#   cannot see that the production modules read them.

_backoff_setup() {
  CFG_STATE_DIR="${TEST_TMPDIR}/state-$$-${RANDOM}"
  CFG_FAILURE_COOLDOWN_S=1800       # 30m
  CFG_FAILURE_COOLDOWN_MAX_S=43200  # 12h
  mkdir -p "${CFG_STATE_DIR}/failures"
}

# Write a failure record dated now, with the given consecutive-failure count.
_record_failures() {
  local name=$1 count=$2
  printf '%s %s\n' "$(date -u +%s)" "$count" >"${CFG_STATE_DIR}/failures/${name}"
}

# --- The ceiling depends on what is actually serving ------------------------
#
# Twelve hours is right while a trusted certificate is in place: nothing is
# degraded and the authority's quota is all that is at stake. It is wrong when
# the site runs on the local placeholder, where every visitor already gets a
# full-page browser warning.

test_the_ceiling_is_the_configured_maximum_when_a_trusted_certificate_serves() {
  assert_eq '43200' "$(issue::_cooldown_ceiling 1800 43200 0)"
}

test_the_ceiling_drops_to_the_base_delay_when_the_service_is_degraded() {
  assert_eq '1800' "$(issue::_cooldown_ceiling 1800 43200 1)"
}

# issue::ensure_placeholders installs a local certificate for every declared
# name before any of this runs, so "a certificate exists" said nothing about
# the service being protected: a single failed attempt parked a site on an
# untrusted certificate for up to twelve hours.
test_a_degraded_site_is_never_backed_off_past_the_base_delay() {
  _backoff_setup
  _record_failures degraded.example.com 8

  local protected degraded
  protected=$(issue::_cooldown_remaining degraded.example.com 0)
  degraded=$(issue::_cooldown_remaining degraded.example.com 1)

  # 1800 * 2^7 is far past the ceiling in both cases; only the ceiling differs.
  if ((protected < 43000 || protected > 43200)); then
    fail "eight failures with a trusted certificate should wait ~12h, got ${protected}s"
  fi
  if ((degraded < 1700 || degraded > 1800)); then
    fail "eight failures on a placeholder should wait ~30m, got ${degraded}s"
  fi
}

test_the_backoff_still_grows_between_failures() {
  _backoff_setup
  _record_failures grow.example.com 1
  local first; first=$(issue::_cooldown_remaining grow.example.com 0)
  _record_failures grow.example.com 3
  local third; third=$(issue::_cooldown_remaining grow.example.com 0)
  if ((third <= first)); then
    fail "the delay must grow with the failure count: 1 -> ${first}s, 3 -> ${third}s"
  fi
}

test_no_recorded_failure_means_no_wait() {
  _backoff_setup
  assert_eq '0' "$(issue::_cooldown_remaining never-failed.example.com 0)"
  assert_eq '0' "$(issue::_cooldown_remaining never-failed.example.com 1)"
}

# A truncated or hand-edited record must not turn into an arithmetic error that
# takes the whole run down.
test_a_corrupt_failure_record_is_ignored() {
  _backoff_setup
  printf 'not-a-date oops\n' >"${CFG_STATE_DIR}/failures/corrupt.example.com"
  assert_eq '0' "$(issue::_cooldown_remaining corrupt.example.com 0)"
}
