#!/usr/bin/env bash
# shellcheck shell=bash

_tpl() {
  local f="${TEST_TMPDIR}/t.tpl"
  printf '%s\n' "$1" >"$f"
  shift
  template::render "$f" "$@"
}

test_substitutes_placeholders() {
  assert_eq 'port 8080;' "$(_tpl 'port %%PORT%%;' 'PORT=8080')"
}

test_substitutes_every_occurrence() {
  assert_eq 'a a' "$(_tpl '%%X%% %%X%%' 'X=a')"
}

test_preserves_nginx_variables() {
  # This is the whole reason for the %%...%% syntax: "$host" and "${other}"
  # must never be interpreted by the template engine.
  local out; out=$(_tpl 'proxy_set_header Host $host; # ${other}' 'HOST=x')
  assert_contains "$out" '$host'
  assert_contains "$out" '${other}'
}

test_handles_conditional_blocks() {
  local tpl='before
%%IF FLAG%%
yes
%%ELSE%%
no
%%ENDIF%%
after'
  assert_contains     "$(_tpl "$tpl" 'FLAG=true')"  'yes'
  assert_not_contains "$(_tpl "$tpl" 'FLAG=true')"  'no'
  assert_contains     "$(_tpl "$tpl" 'FLAG=false')" 'no'
  assert_not_contains "$(_tpl "$tpl" 'FLAG=false')" 'yes'
  assert_contains     "$(_tpl "$tpl" 'FLAG=false')" 'before'
  assert_contains     "$(_tpl "$tpl" 'FLAG=false')" 'after'
}

test_treats_a_missing_variable_as_false() {
  local tpl=$'%%IF ABSENT%%\nvisible\n%%ENDIF%%\nend'
  assert_not_contains "$(_tpl "$tpl")" 'visible'
  assert_contains     "$(_tpl "$tpl")" 'end'
}

test_detects_forgotten_placeholders() {
  local f="${TEST_TMPDIR}/incomplete.conf"
  printf 'listen %%%%PORT%%%%;\n' >"$f"
  local out rc=0
  out=$(template::assert_complete "$f" 2>&1) || rc=$?
  assert_ne '0' "$rc" 'an unsubstituted placeholder must be reported'
  assert_contains "$out" 'PORT'
}

test_accepts_a_fully_substituted_file() {
  local f="${TEST_TMPDIR}/complete.conf"
  printf 'listen 443;\n' >"$f"
  assert_ok template::assert_complete "$f"
}

test_fails_cleanly_on_a_missing_template() {
  assert_fails template::render "${TEST_TMPDIR}/does-not-exist.tpl"
}
