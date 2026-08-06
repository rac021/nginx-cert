#!/usr/bin/env bash
# shellcheck shell=bash

test_parses_human_readable_durations() {
  assert_eq '3600'  "$(util::parse_duration 1h)"
  assert_eq '43200' "$(util::parse_duration 12h)"
  assert_eq '1800'  "$(util::parse_duration 30m)"
  assert_eq '86400' "$(util::parse_duration 1d)"
  assert_eq '90'    "$(util::parse_duration 90)"
  assert_eq '5400'  "$(util::parse_duration 1h30m)"
  assert_eq '0'     "$(util::parse_duration 12x)"
  assert_eq '0'     "$(util::parse_duration '')"
}

test_signals_invalid_durations_through_the_exit_code() {
  assert_fails util::parse_duration 'later'
  assert_ok    util::parse_duration '15m'
}

test_formats_durations() {
  assert_eq '12h'    "$(util::human_duration 43200)"
  assert_eq '1d 1h'  "$(util::human_duration 90000)"
  assert_eq '30s'    "$(util::human_duration 30)"
  assert_eq '0s'     "$(util::human_duration 0)"
}

test_interprets_booleans() {
  local v
  for v in true TRUE 1 yes Y on enabled; do
    assert_ok util::is_true "$v" "'$v' should be true"
  done
  for v in false 0 no off '' whatever; do
    assert_fails util::is_true "$v" "'$v' should be false"
  done
}

test_sanitises_lineage_names() {
  assert_eq 'wildcard.example.com' "$(util::sanitize_name '*.example.com')"
  assert_eq 'example.com'          "$(util::sanitize_name 'example.com')"
  assert_eq '192.168.1.1'          "$(util::sanitize_name '192.168.1.1')"
  # No sequence may escape the certificate directory, and no name may end up
  # hidden: a lineage the operator cannot see with "ls" is a support call.
  assert_not_contains "$(util::sanitize_name '../../etc/passwd')" '/'
  assert_eq '_.._etc_passwd' "$(util::sanitize_name '../../etc/passwd')"
}

test_splits_and_joins() {
  local -a parts=()
  util::split_into parts ',' ' a , b ,, c '
  assert_eq '3'     "${#parts[@]}"
  assert_eq 'a|b|c' "$(util::join '|' "${parts[@]}")"
}

test_trims_surrounding_whitespace() {
  assert_eq 'abc' "$(util::trim '   abc   ')"
  assert_eq ''    "$(util::trim '     ')"
}

test_compares_versions() {
  assert_ok    util::version_ge 3.1.4 3.1.0
  assert_ok    util::version_ge 3.1.4 3.1.4
  assert_fails util::version_ge 3.0.9 3.1.0
}
