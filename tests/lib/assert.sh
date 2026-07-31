#!/usr/bin/env bash
# tests/lib/assert.sh -- Dependency-free micro test harness.
#
# bats would have done the job, but it would have to be installed before a
# single test could run. Here "./tests/run.sh" works on any machine that has
# bash -- including inside a minimal container.
#
# Every "test_*" function of a file runs in a subshell under "set -e": the
# first failing assertion aborts that test case and marks it failed, without
# affecting the others. All assertions use the "if ... then return 0; fi" form:
# a bare "&& return 0" would trip set -e before the error message is printed.
# shellcheck shell=bash

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=''

_t_red=''; _t_green=''; _t_dim=''; _t_reset=''
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  _t_red=$'\033[31m'; _t_green=$'\033[32m'; _t_dim=$'\033[2m'; _t_reset=$'\033[0m'
fi

fail() {
  printf '%s  [FAIL] %s%s\n' "$_t_red" "$CURRENT_TEST" "$_t_reset" >&2
  local line
  while IFS= read -r line; do printf '         %s\n' "$line" >&2; done <<<"$1"
  return 1
}

assert_eq() {
  local expected=$1 actual=$2 msg=${3:-}
  if [[ $expected == "$actual" ]]; then return 0; fi
  fail "${msg:+${msg}
}expected : '${expected}'
actual   : '${actual}'"
}

assert_ne() {
  local unexpected=$1 actual=$2 msg=${3:-}
  if [[ $unexpected != "$actual" ]]; then return 0; fi
  fail "${msg:+${msg}
}value should not have been '${unexpected}'"
}

assert_contains() {
  local haystack=$1 needle=$2 msg=${3:-}
  if [[ $haystack == *"$needle"* ]]; then return 0; fi
  fail "${msg:+${msg}
}'${needle}' is missing from:
${haystack}"
}

assert_not_contains() {
  local haystack=$1 needle=$2 msg=${3:-}
  if [[ $haystack != *"$needle"* ]]; then return 0; fi
  fail "${msg:+${msg}
}'${needle}' should NOT appear in:
${haystack}"
}

assert_ok() {
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if ((rc == 0)); then return 0; fi
  fail "command should have succeeded: $*
exit   : ${rc}
output :
${out}"
}

assert_fails() {
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if ((rc != 0)); then return 0; fi
  fail "command should have failed: $*
output :
${out}"
}

assert_exit_code() {
  local expected=$1; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if ((rc == expected)); then return 0; fi
  fail "expected exit code ${expected}, got ${rc} for: $*
output :
${out}"
}

# Run every "test_*" function defined in the current file.
run_tests_in_file() {
  printf '%s-- %s%s\n' "$_t_dim" "${1##*/}" "$_t_reset"
  local fn
  while IFS= read -r fn; do
    CURRENT_TEST=${fn#test_}
    CURRENT_TEST=${CURRENT_TEST//_/ }
    TESTS_RUN=$((TESTS_RUN + 1))
    if ( set -e; "$fn" ); then
      printf '%s  [ ok ] %s%s\n' "$_t_green" "$CURRENT_TEST" "$_t_reset"
    else
      TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
}
