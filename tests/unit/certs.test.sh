#!/usr/bin/env bash
# Verification of a certificate bundle before installation.
#
# Each of these cases maps to a real version-1 defect: incomplete chain,
# missing SAN, or a certificate installed with no prior check.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   The CFG_* variables are set here to drive the code under test; shellcheck
#   cannot see that the production modules read them.

# Bundles are created under CFG_CERT_DIR so that the functions resolving paths
# from a lineage name (days_left, is_selfsigned, ...) find them unchanged.
CFG_CERT_DIR="${TEST_TMPDIR}/certs"

_mkdir_bundle() { local d="${CFG_CERT_DIR}/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }

# Generate a complete self-signed bundle in a directory.
_gen_bundle() {
  local dir=$1 cn=$2 san=${3:-DNS:$2} days=${4:-90}
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -days "$days" -subj "/CN=${cn}" -addext "subjectAltName=${san}" \
    -keyout "${dir}/privkey.pem" -out "${dir}/cert.pem" 2>/dev/null
  cp "${dir}/cert.pem" "${dir}/chain.pem"
  cp "${dir}/cert.pem" "${dir}/fullchain.pem"
}

_setup_spec() {
  NC_SPEC_DOMAINS=(); NC_SPEC_DOMAINS[$1]=$2
}

# A bundle signed by a separate CA, so that issuer != subject and the
# self-signed heuristic does not fire. Needed to exercise the checks that come
# after it in certs::renewal_reason.
_gen_ca_signed_bundle() {
  local dir=$1 cn=$2 days=${3:-90}
  local ca="${TEST_TMPDIR}/testca"
  if [[ ! -s ${ca}.pem ]]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${ca}.key" 2>/dev/null
    openssl req -x509 -new -key "${ca}.key" -sha256 -days 3650 -out "${ca}.pem" \
      -subj '/O=Test/CN=Test Issuing CA' \
      -addext 'basicConstraints=critical,CA:TRUE' 2>/dev/null
  fi
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${dir}/privkey.pem" 2>/dev/null
  local csr ext; csr=$(mktemp); ext=$(mktemp)
  printf 'subjectAltName=DNS:%s\n' "$cn" >"$ext"
  openssl req -new -key "${dir}/privkey.pem" -out "$csr" -subj "/CN=${cn}" 2>/dev/null
  openssl x509 -req -in "$csr" -CA "${ca}.pem" -CAkey "${ca}.key" -CAcreateserial \
    -out "${dir}/cert.pem" -days "$days" -sha256 -extfile "$ext" 2>/dev/null
  rm -f "$csr" "$ext"
  cp "${ca}.pem" "${dir}/chain.pem"
  cat "${dir}/cert.pem" "${dir}/chain.pem" >"${dir}/fullchain.pem"
}

test_accepts_a_consistent_bundle() {
  local d; d=$(_mkdir_bundle ok)
  _gen_bundle "$d" 'example.com'
  _setup_spec 'ok' 'example.com'
  assert_ok certs::verify_bundle "$d" 'ok'
}

test_rejects_a_missing_file() {
  local d; d=$(_mkdir_bundle empty)
  _setup_spec 'empty' 'example.com'
  assert_fails certs::verify_bundle "$d" 'empty'
}

test_rejects_a_key_that_does_not_match_the_certificate() {
  local d; d=$(_mkdir_bundle mismatch)
  _gen_bundle "$d" 'example.com'
  # Key belonging to a different certificate: nginx would refuse to start.
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out "${d}/privkey.pem" 2>/dev/null
  _setup_spec 'mismatch' 'example.com'
  local out rc=0
  out=$(certs::verify_bundle "$d" 'mismatch' 2>&1) || rc=$?
  assert_ne '0' "$rc"
  assert_contains "$out" 'does not match'
}

test_rejects_an_already_expired_certificate() {
  local d; d=$(_mkdir_bundle expired)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -not_before 20200101000000Z -not_after 20200102000000Z \
    -subj '/CN=example.com' -addext 'subjectAltName=DNS:example.com' \
    -keyout "${d}/privkey.pem" -out "${d}/cert.pem" 2>/dev/null
  cp "${d}/cert.pem" "${d}/chain.pem"; cp "${d}/cert.pem" "${d}/fullchain.pem"
  _setup_spec 'expired' 'example.com'
  local out rc=0
  out=$(certs::verify_bundle "$d" 'expired' 2>&1) || rc=$?
  assert_ne '0' "$rc"
  assert_contains "$out" 'already expired'
}

test_rejects_a_fullchain_reduced_to_the_leaf() {
  # Exact version-1 defect: "certificate.crt" written straight into
  # fullchain.pem while an intermediate existed.
  local d; d=$(_mkdir_bundle leafonly)
  _gen_bundle "$d" 'example.com'
  local other="${TEST_TMPDIR}/inter"; rm -rf "$other"; mkdir -p "$other"
  _gen_bundle "$other" 'intermediate'
  cp "${other}/cert.pem" "${d}/chain.pem"      # a real chain exists...
  cp "${d}/cert.pem"     "${d}/fullchain.pem"  # ...but fullchain omits it
  _setup_spec 'leafonly' 'example.com'
  local out rc=0
  out=$(certs::verify_bundle "$d" 'leafonly' 2>&1) || rc=$?
  assert_ne '0' "$rc"
  assert_contains "$out" 'only the leaf'
}

test_accepts_a_selfsigned_bundle_whose_chain_is_the_leaf() {
  # Legitimate self-signed convention: chain.pem is a copy of cert.pem, so
  # there is no intermediate to include in fullchain.pem.
  local d; d=$(_mkdir_bundle ssbundle)
  _gen_bundle "$d" 'example.com'
  _setup_spec 'ssbundle' 'example.com'
  assert_ok certs::verify_bundle "$d" 'ssbundle'
}

test_rejects_a_certificate_missing_a_requested_domain() {
  local d; d=$(_mkdir_bundle sancheck)
  _gen_bundle "$d" 'example.com' 'DNS:example.com'
  _setup_spec 'sancheck' 'example.com www.example.com'
  local out rc=0
  out=$(certs::verify_bundle "$d" 'sancheck' 2>&1) || rc=$?
  assert_ne '0' "$rc"
  assert_contains "$out" 'does not cover'
}

test_accepts_a_wildcard_covering_a_subdomain() {
  local d; d=$(_mkdir_bundle wild)
  _gen_bundle "$d" '*.example.com' 'DNS:*.example.com'
  _setup_spec 'wild' '*.example.com api.example.com'
  assert_ok certs::verify_bundle "$d" 'wild'
}

test_reads_ipv4_sans_without_prefix_confusion() {
  # OpenSSL writes "IP Address:"; the prefix must be stripped correctly or the
  # coverage check fails for no reason.
  local d; d=$(_mkdir_bundle ipsan)
  _gen_bundle "$d" '192.168.1.50' 'IP:192.168.1.50'
  assert_eq '192.168.1.50' "$(certs::sans x "${d}/cert.pem")"
}

test_computes_days_remaining() {
  local d; d=$(_mkdir_bundle daysleft)
  _gen_bundle "$d" 'example.com' 'DNS:example.com' 90
  local days; days=$(certs::days_left 'daysleft')
  # One-day tolerance for rounding and timezone.
  assert_ok bash -c "[ '$days' -ge 88 ] && [ '$days' -le 90 ]"
}

# Leaving the staging environment is the normal go-live path, and nothing in
# the certificate itself signals it: a staging certificate is valid for 90 days
# and is properly signed, so only the recorded provider can catch it.
test_renews_when_leaving_the_staging_environment() {
  local d; d=$(_mkdir_bundle golive)
  _gen_ca_signed_bundle "$d" 'example.com' 90
  _setup_spec 'golive' 'example.com'
  NC_SPEC_PROVIDER=(); NC_SPEC_PROVIDER["golive"]=auto
  NC_SPEC_KIND=();     NC_SPEC_KIND["golive"]=fqdn
  CFG_STATE_DIR="${TEST_TMPDIR}/state-golive"
  CFG_RENEW_DAYS=30; CFG_FORCE_RENEW=false

  certs::record_provider 'golive' 'letsencrypt-staging'

  CFG_STAGING=true
  assert_eq '' "$(certs::renewal_reason 'golive')" 'still in staging: nothing to do'

  CFG_STAGING=false
  assert_contains "$(certs::renewal_reason 'golive')" 'CERT_STAGING is now off'
}

test_does_not_renew_a_production_certificate_on_the_staging_check() {
  local d; d=$(_mkdir_bundle prod)
  _gen_ca_signed_bundle "$d" 'example.com' 90
  _setup_spec 'prod' 'example.com'
  NC_SPEC_PROVIDER=(); NC_SPEC_PROVIDER["prod"]=auto
  NC_SPEC_KIND=();     NC_SPEC_KIND["prod"]=fqdn
  CFG_STATE_DIR="${TEST_TMPDIR}/state-prod"
  CFG_RENEW_DAYS=30; CFG_FORCE_RENEW=false; CFG_STAGING=false

  certs::record_provider 'prod' 'letsencrypt'
  assert_eq '' "$(certs::renewal_reason 'prod')" 'a production certificate must be left alone'
}

test_detects_a_selfsigned_certificate() {
  local d; d=$(_mkdir_bundle detectss)
  _gen_bundle "$d" 'example.com'
  assert_ok certs::is_selfsigned 'detectss'
}
