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
  NC_SPEC_STAGING=(); NC_SPEC_HSTS=(); NC_SPEC_REDIRECT=(); NC_SPEC_RENEW_DAYS=()
  CFG_PROVIDER=auto; CFG_UPSTREAM=''; CFG_CHALLENGE=auto; CFG_DNS_PROVIDER=''
  CFG_KEY_TYPE=ec-256; CFG_PROFILE=''; CFG_STAGING=false
  CFG_HSTS='max-age=31536000'; CFG_HTTP_REDIRECT=true; CFG_RENEW_DAYS=30
}

_parse() { _reset_specs; CERT_DOMAINS=$1 config::_parse_domains; }

# The whole loader: parse *and* validate. Takes VAR=value arguments.
#
# The success form runs in this shell so the resulting CFG_*/NC_SPEC_* values
# can be asserted on; the failure form runs in a subshell because rejecting a
# value means calling log::die, which exits.
_load_config() {
  _reset_specs
  local kv
  for kv in "$@"; do export "${kv?}"; done
  config::load
}

_load_config_fails() {
  ( _load_config "$@" >/dev/null 2>&1 )
}

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

# --- Per-line options are validated exactly like their global counterparts ---
#
# They used not to be: "provider=lestencrypt" fell through to the whole auto
# chain and "staging=ture" issued against production, both without a word,
# while the same typo in CERT_PROVIDER or CERT_STAGING stopped the container.

test_rejects_an_unknown_per_certificate_provider() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=example.com | provider=lestencrypt"
}

test_rejects_a_non_boolean_per_certificate_staging() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=example.com | staging=ture"
}

test_rejects_an_unknown_per_certificate_key_type() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=example.com | key_type=rubbish"
}

test_rejects_an_unknown_per_certificate_challenge() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=example.com | challenge=rubbish"
}

test_accepts_a_valid_per_certificate_provider() {
  assert_ok _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=example.com | provider=letsencrypt staging=true key_type=ec-384"
}

# The name becomes a path component under /data/certs and a file name in
# conf.d. Taken verbatim, "name=../../evil" wrote outside the data directory.
test_sanitises_a_user_supplied_certificate_name() {
  _load_config CERT_EMAIL=a@b.com "CERT_DOMAINS=example.com | name=../../evil"
  assert_not_contains "${NC_SPEC_NAMES[0]}" '/'
  assert_eq '_.._evil' "${NC_SPEC_NAMES[0]}" 'every path separator is neutralised'
}

# Every duration is read by the same parser, so a unit suffix is either
# understood or refused -- never handed to arithmetic that aborts the run.
test_accepts_a_duration_for_the_retry_delay() {
  _load_config CERT_EMAIL=a@b.com CERT_DOMAINS=example.com CERT_RETRY_DELAY=2m
  assert_eq '120' "$CFG_RETRY_DELAY_S"
}

test_rejects_an_invalid_retry_delay() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_RETRY_DELAY=soon
}

test_rejects_an_invalid_dns_sleep() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_DNS_SLEEP=later
}

# --- CERT_UPSTREAM is the value users touch most, and reaches nginx ---------

test_accepts_the_usual_upstream_forms() {
  local u
  for u in '' 'app' 'app:8080' 'http://app:8080' 'https://app:8443' \
           '10.0.0.5:8080' 'my-app.internal:3000' '[2001:db8::1]:8080' 'app:8080/'; do
    assert_ok config::valid_upstream "$u" "should accept '${u}'"
  done
}

test_rejects_an_upstream_that_would_break_the_generated_configuration() {
  local u
  # A double quote closed the generated nginx string and injected directives;
  # the rest are typos that produced a 502 at request time and nothing in the
  # logs to explain it.
  for u in 'app:8080"; return 444; #' 'app:notaport' 'app:99999' 'app:0' \
           'app:8080/api' 'app 8080' 'app;8080'; do
    assert_fails config::valid_upstream "$u" "should reject '${u}'"
  done
}

test_rejects_an_invalid_upstream_at_startup() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    'CERT_UPSTREAM=app:notaport'
}

# nginx keeps the first server block for a duplicated server_name and warns.
# The second certificate was issued and renewed forever without serving anyone.
test_rejects_the_same_domain_in_two_certificates() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=$(printf 'example.com | name=one\nexample.com, www.example.com | name=two')"
}

# A threshold only means something relative to a lifetime: 30 days is right for
# a 90-day certificate and absurd for a 160-hour one, and one container can
# legitimately hold both.
test_accepts_a_per_certificate_renewal_threshold() {
  _parse $'www.example.com | upstream=site:8080\n203.0.113.10 | renew_days=2'
  assert_eq '30' "${NC_SPEC_RENEW_DAYS[www.example.com]}" 'the global value by default'
  assert_eq '2'  "${NC_SPEC_RENEW_DAYS[203.0.113.10]}"
}

test_rejects_a_non_numeric_per_certificate_threshold() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com \
    "CERT_DOMAINS=example.com | renew_days=soon"
}

# --- selfsigned is a value of CERT_PROVIDER, not just of "provider=" --------
#
# It has no line in providers.tsv because it speaks no ACME, so the existence
# check rejected it -- while the error message listed it as available, the
# README documented it, and the removal notice for CERT_SELF_SIGNED_CERTIFICATE
# told the operator to switch to it. Following that advice stopped the
# container.
test_accepts_selfsigned_as_the_global_provider() {
  _load_config CERT_PROVIDER=selfsigned CERT_DOMAINS=example.com
  assert_eq 'selfsigned' "$CFG_PROVIDER"
  assert_eq 'selfsigned' "${NC_SPEC_PROVIDER[example.com]}"
}

# ...and it must not drag CERT_EMAIL in with it: the local authority asks for
# no account.
test_selfsigned_needs_no_account_email() {
  assert_ok _load_config CERT_PROVIDER=selfsigned CERT_DOMAINS=example.com
}

test_still_rejects_a_misspelt_global_provider() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_PROVIDER=selfsignd
}

# --- every duration is validated, wherever it is consumed ------------------
#
# These four were read straight from the environment at the point of use and
# fell back to their default on anything the parser rejected. The same typo
# that stopped the container on CERT_RETRY_DELAY was silently ignored here.
test_rejects_invalid_durations_consumed_outside_config() {
  local v
  for v in CERT_ACME_TIMEOUT CERT_FAILURE_COOLDOWN CERT_FAILURE_COOLDOWN_MAX \
           CERT_ZEROSSL_TIMEOUT; do
    assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
      "${v}=30min" "should reject ${v}=30min"
  done
}

test_rejects_a_zero_acme_timeout() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_ACME_TIMEOUT=0
}

# A ceiling below the base delay would make the backoff shrink with every
# failure instead of growing.
test_rejects_a_cooldown_ceiling_below_the_base_delay() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_FAILURE_COOLDOWN=2h CERT_FAILURE_COOLDOWN_MAX=30m
}

test_rejects_a_non_numeric_zerossl_validity() {
  assert_fails _load_config_fails CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_ZEROSSL_VALIDITY_DAYS=ninety
}

test_exposes_the_parsed_durations_in_seconds() {
  _load_config CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
    CERT_ACME_TIMEOUT=90s CERT_FAILURE_COOLDOWN=45m CERT_FAILURE_COOLDOWN_MAX=6h
  assert_eq '90'    "$CFG_ACME_TIMEOUT_S"
  assert_eq '2700'  "$CFG_FAILURE_COOLDOWN_S"
  assert_eq '21600' "$CFG_FAILURE_COOLDOWN_MAX_S"
}

# CERT_ACME_SERVER replaces the directory URL of every authority in the chain,
# so a summary that names the chain without naming the override describes a run
# that will not happen.
test_the_summary_names_the_acme_directory_override() {
  local out
  out=$( _load_config CERT_EMAIL=a@b.com CERT_DOMAINS=example.com \
           CERT_ACME_SERVER=https://ca.internal/acme/directory >/dev/null 2>&1
         NC_LOG_LEVEL=info config::summary 2>&1 )
  assert_contains "$out" 'https://ca.internal/acme/directory'
  assert_contains "$out" 'CERT_ACME_SERVER'
}
