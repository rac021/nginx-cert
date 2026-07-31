#!/usr/bin/env bash
# CERT_DOMAINS parsing: the only syntax users write by hand, so the only one
# that must fail with an understandable message.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   The CFG_* variables are set here to drive the code under test; shellcheck
#   cannot see that the production modules read them.

_reset_specs() {
  NC_SPEC_NAMES=()
  NC_SPEC_DOMAINS=(); NC_SPEC_KIND=(); NC_SPEC_PROVIDER=(); NC_SPEC_UPSTREAM=()
  NC_SPEC_CHALLENGE=(); NC_SPEC_DNS=(); NC_SPEC_KEY_TYPE=(); NC_SPEC_PROFILE=()
  NC_SPEC_STAGING=(); NC_SPEC_HSTS=(); NC_SPEC_REDIRECT=()
  CFG_PROVIDER=auto; CFG_UPSTREAM=''; CFG_CHALLENGE=auto; CFG_DNS_PROVIDER=''
  CFG_KEY_TYPE=ec-256; CFG_PROFILE=''; CFG_STAGING=false
  CFG_HSTS='max-age=31536000'; CFG_HTTP_REDIRECT=true
}

_parse() { _reset_specs; CERT_DOMAINS=$1 config::_parse_domains; }

test_parses_a_single_certificate() {
  _parse 'example.com'
  assert_eq '1'           "${#NC_SPEC_NAMES[@]}"
  assert_eq 'example.com' "${NC_SPEC_NAMES[0]}"
  assert_eq 'example.com' "${NC_SPEC_DOMAINS[example.com]}"
  assert_eq 'fqdn'        "${NC_SPEC_KIND[example.com]}"
}

test_groups_domains_on_one_line_into_a_single_certificate() {
  _parse 'example.com, www.example.com'
  assert_eq '1' "${#NC_SPEC_NAMES[@]}" 'one line = one multi-SAN certificate'
  assert_eq 'example.com www.example.com' "${NC_SPEC_DOMAINS[example.com]}"
}

test_creates_one_certificate_per_line() {
  _parse $'example.com\napi.example.org\n192.168.0.9'
  assert_eq '3' "${#NC_SPEC_NAMES[@]}"
  assert_eq 'api.example.org' "${NC_SPEC_NAMES[1]}"
}

test_accepts_semicolon_as_a_separator() {
  _parse 'a.example.com; b.example.com'
  assert_eq '2' "${#NC_SPEC_NAMES[@]}"
}

test_ignores_blank_lines_and_comments() {
  _parse $'\n# a comment\nexample.com\n\n'
  assert_eq '1' "${#NC_SPEC_NAMES[@]}"
}

test_applies_per_line_options() {
  _parse 'example.com | upstream=app:8080 provider=actalis hsts=off'
  assert_eq 'app:8080' "${NC_SPEC_UPSTREAM[example.com]}"
  assert_eq 'actalis'  "${NC_SPEC_PROVIDER[example.com]}"
  assert_eq 'off'      "${NC_SPEC_HSTS[example.com]}"
}

test_per_line_options_override_global_values() {
  _reset_specs
  CFG_UPSTREAM='global:80'
  CERT_DOMAINS=$'a.example.com\nb.example.com | upstream=special:9000' config::_parse_domains
  assert_eq 'global:80'    "${NC_SPEC_UPSTREAM[a.example.com]}"
  assert_eq 'special:9000' "${NC_SPEC_UPSTREAM[b.example.com]}"
}

test_derives_a_safe_lineage_name_for_a_wildcard() {
  _parse '*.example.com'
  assert_eq 'wildcard.example.com' "${NC_SPEC_NAMES[0]}"
  assert_eq '*.example.com'        "${NC_SPEC_DOMAINS[wildcard.example.com]}"
}

test_accepts_an_explicit_lineage_name() {
  _parse 'example.com | name=primary'
  assert_eq 'primary' "${NC_SPEC_NAMES[0]}"
}

test_normalises_case_and_trailing_dot() {
  _parse 'EXAMPLE.COM.'
  assert_eq 'example.com' "${NC_SPEC_NAMES[0]}"
}

test_rejects_an_unknown_option() {
  local out rc=0
  out=$( _parse 'example.com | upstrem=app:8080' 2>&1 ) || rc=$?
  assert_ne '0' "$rc" 'a typo in an option must be fatal'
  assert_contains "$out" 'unknown option'
  assert_contains "$out" 'upstrem'
}

test_rejects_an_option_without_an_equals_sign() {
  local out rc=0
  out=$( _parse 'example.com | upstream' 2>&1 ) || rc=$?
  assert_ne '0' "$rc"
  assert_contains "$out" 'malformed option'
}

# --- The known-variable list must not drift from the code ------------------
#
# These two tests are what make config::warn_unknown_vars trustworthy: adding a
# CERT_* variable without declaring it would make the program warn about its own
# variable, and declaring one that nothing reads would advertise a setting that
# does nothing.

_referenced_cert_vars() {
  # \b anchors the match to a real identifier start, so substrings of longer
  # names (CFG_CERT_DIR, NC_KNOWN_CERT_VARS) are not mistaken for variables.
  # The %%CERT_NAME%% template placeholder does start on a boundary, hence the
  # explicit exclusion.
  grep -rhoE '\bCERT_[A-Z0-9_]+' \
      "$NC_ROOT"/lib "$NC_ROOT"/providers "$NC_ROOT"/entrypoint.sh "$NC_ROOT"/bin/certme \
    | grep -vxE 'CERT_NAME' | sort -u
}

test_every_variable_read_by_the_code_is_declared() {
  local v k found missing=()
  while IFS= read -r v; do
    [[ -n ${NC_REMOVED_CERT_VARS[$v]:-} ]] && continue
    found=0
    for k in "${NC_KNOWN_CERT_VARS[@]}"; do [[ $v == "$k" ]] && { found=1; break; }; done
    ((found)) || missing+=("$v")
  done < <(_referenced_cert_vars)
  assert_eq '' "${missing[*]}" 'read by the code but absent from NC_KNOWN_CERT_VARS'
}

test_every_declared_variable_is_read_somewhere() {
  local referenced; referenced=" $(_referenced_cert_vars | tr '\n' ' ')"
  local k dead=()
  for k in "${NC_KNOWN_CERT_VARS[@]}"; do
    [[ $referenced == *" $k "* ]] || dead+=("$k")
  done
  assert_eq '' "${dead[*]}" 'declared in NC_KNOWN_CERT_VARS but never read'
}

test_warns_about_a_variable_removed_since_version_1() {
  local out
  out=$( CERT_PROXY_PASS_PORT=8080 CERT_RENEWAL_THRESHOLD_DAYS=30 \
         NC_LOG_LEVEL=warn config::warn_unknown_vars 2>&1 )
  assert_contains "$out" 'CERT_PROXY_PASS_PORT is no longer supported'
  assert_contains "$out" 'webroot'
  assert_contains "$out" 'CERT_RENEWAL_THRESHOLD_DAYS'
  assert_contains "$out" 'CERT_RENEW_DAYS'
}

test_warns_about_a_misspelled_variable() {
  local out
  out=$( CERT_EMIAL=a@b.co NC_LOG_LEVEL=warn config::warn_unknown_vars 2>&1 )
  assert_contains "$out" 'CERT_EMIAL'
  assert_contains "$out" 'Unknown variable'
}

test_stays_silent_when_every_variable_is_known() {
  local out
  out=$( CERT_EMAIL=a@b.co CERT_DOMAINS=example.com NC_LOG_LEVEL=warn \
         config::warn_unknown_vars 2>&1 )
  assert_eq '' "$out"
}

test_rejects_two_certificates_with_the_same_name() {
  local out rc=0
  out=$( _parse $'example.com\nexample.com' 2>&1 ) || rc=$?
  assert_ne '0' "$rc"
  assert_contains "$out" 'same name'
}
