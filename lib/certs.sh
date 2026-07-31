#!/usr/bin/env bash
# lib/certs.sh — Inspection, verification and atomic installation.
#
# Golden rule: a new certificate only overwrites the live one after it has been
# verified. A failed renewal must leave the service exactly as it was, never in
# a half-written state.
# shellcheck shell=bash

[[ -n ${NC_LIB_CERTS_SH:-} ]] && return 0
readonly NC_LIB_CERTS_SH=1

# --- Inspection ------------------------------------------------------------

certs::exists() { [[ -s $(config::fullchain_path "$1") && -s $(config::privkey_path "$1") ]]; }

# Expiry date in ISO 8601.
#
# OpenSSL's default format ("Oct 29 00:29:43 2026 GMT") cannot be parsed by
# BusyBox date(1). -dateopt iso_8601 (OpenSSL >= 3.0) yields
# "2026-10-29 00:29:43Z", which BusyBox does understand.
certs::not_after() {
  local f; f=$(config::fullchain_path "$1")
  [[ -s $f ]] || return 1
  openssl x509 -in "$f" -noout -enddate -dateopt iso_8601 2>/dev/null | cut -d= -f2-
}

# Days remaining (may be negative).
certs::days_left() {
  local end epoch now
  end=$(certs::not_after "$1") || { printf '0'; return 1; }
  [[ -n $end ]] || { printf '0'; return 1; }
  epoch=$(date -u -d "${end%Z}" +%s 2>/dev/null) || { printf '0'; return 1; }
  now=$(date -u +%s)
  printf '%s' "$(( (epoch - now) / 86400 ))"
}

certs::issuer() {
  local f; f=$(config::fullchain_path "$1")
  [[ -s $f ]] || return 1
  openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer=//'
}

# Names covered by the certificate, one per line, without the type prefix.
#
# OpenSSL writes "IP Address:192.0.2.1"; the space is stripped before
# splitting, hence the "IPAddress" prefix -- which must be handled BEFORE "IP",
# otherwise the sed alternation stops on the shorter prefix.
certs::sans() {
  local f=${2:-$(config::fullchain_path "$1")}
  [[ -s $f ]] || return 1
  openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null \
    | tail -n +2 | tr -d ' ' | tr ',' '\n' \
    | sed 's/^\(DNS\|IPAddress\|IP\|email\|URI\|otherName\)://' \
    | grep -v '^$'
}

# A certificate signed by our local authority is not publicly trusted: it must
# be replaced as soon as a real authority becomes reachable again.
certs::is_selfsigned() {
  local f; f=$(config::fullchain_path "$1")
  [[ -s $f ]] || return 1
  local issuer; issuer=$(openssl x509 -in "$f" -noout -issuer 2>/dev/null)
  [[ $issuer == *'nginx-cert'* ]] && return 0
  local subject; subject=$(openssl x509 -in "$f" -noout -subject 2>/dev/null)
  [[ ${issuer#issuer=} == "${subject#subject=}" ]]
}

# --- Renewal decision ------------------------------------------------------
#
# A renewal is triggered when any of the following holds:
#   - no certificate exists;
#   - it expires in fewer than CERT_RENEW_DAYS days;
#   - it no longer covers every requested name (a domain was added);
#   - it is self-signed while a public authority is now conceivable;
#   - CERT_FORCE_RENEW is set.
#
# Output: the reason, or an empty string when no renewal is required.
certs::renewal_reason() {
  local name=$1

  if ! certs::exists "$name"; then
    printf 'no certificate in place'; return 0
  fi
  if util::is_true "${CFG_FORCE_RENEW:-false}"; then
    printf 'CERT_FORCE_RENEW is set'; return 0
  fi

  local days; days=$(certs::days_left "$name") || { printf 'certificate unreadable'; return 0; }
  if ((days < CFG_RENEW_DAYS)); then
    printf 'expires in %s day(s), threshold is %s' "$days" "$CFG_RENEW_DAYS"; return 0
  fi

  local -a want=(); read -r -a want <<<"${NC_SPEC_DOMAINS[$name]}"
  local have; have=$(certs::sans "$name" | tr '\n' ' ')
  local d
  for d in "${want[@]}"; do
    [[ " $have " == *" $d "* ]] || { printf 'does not cover %s' "$d"; return 0; }
  done

  if certs::is_selfsigned "$name" && [[ ${NC_SPEC_PROVIDER[$name]} != selfsigned ]] \
     && domain::is_acme_capable "${NC_SPEC_KIND[$name]}"; then
    printf 'local certificate in place, a public authority is possible'; return 0
  fi

  printf ''
}

# --- Verification of a freshly issued bundle -------------------------------
#
# This step is what prevents a partial or inconsistent issuance from ever
# reaching nginx.
certs::verify_bundle() {
  local dir=$1 name=$2
  local leaf="${dir}/cert.pem" key="${dir}/privkey.pem"
  local chain="${dir}/chain.pem" full="${dir}/fullchain.pem"

  local f
  for f in "$leaf" "$key" "$full"; do
    [[ -s $f ]] || { log::error "Verification: missing or empty file (${f})."; return 1; }
  done

  if ! openssl x509 -in "$leaf" -noout >/dev/null 2>&1; then
    log::error "Verification: ${leaf} is not a valid X.509 certificate."; return 1
  fi
  if ! openssl pkey -in "$key" -noout >/dev/null 2>&1; then
    log::error "Verification: ${key} is not a valid private key."; return 1
  fi

  # The key must match the certificate, otherwise nginx refuses to start.
  local ck kk
  ck=$(openssl x509 -in "$leaf" -noout -pubkey 2>/dev/null | openssl md5)
  kk=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5)
  if [[ $ck != "$kk" ]] || [[ -z $ck ]]; then
    log::error "Verification: the private key does not match the certificate."; return 1
  fi

  # The certificate must be valid right now (clock drift, botched issuance).
  if ! openssl x509 -in "$leaf" -noout -checkend 0 >/dev/null 2>&1; then
    log::error "Verification: the issued certificate is already expired."; return 1
  fi

  # When a real intermediate exists, fullchain.pem must contain it as well.
  # This is exactly the v1 defect: ZeroSSL's leaf-only "certificate.crt" was
  # written straight into fullchain.pem, breaking chain validation for every
  # client without a cached intermediate.
  #
  # A self-signed bundle legitimately has chain.pem identical to cert.pem, so
  # byte-comparison -- not a mere certificate count -- decides whether an
  # intermediate is actually present.
  if [[ -s $chain ]] && ! cmp -s "$leaf" "$chain"; then
    local n_full; n_full=$(grep -c 'BEGIN CERTIFICATE' "$full" 2>/dev/null || printf 0)
    if ((n_full < 2)); then
      log::error "Verification: fullchain.pem contains only the leaf while an intermediate chain exists."
      return 1
    fi
  fi

  # Every requested name must be covered.
  local -a want=(); read -r -a want <<<"${NC_SPEC_DOMAINS[$name]:-}"
  if ((${#want[@]})); then
    local have; have=$(certs::sans "$name" "$leaf" | tr '\n' ' ')
    local d
    for d in "${want[@]}"; do
      if [[ " $have " != *" $d "* ]]; then
        # A wildcard *.example.org covers a.example.org.
        local covered=0 s
        for s in $have; do
          [[ $s == '*.'* && $d == *.${s#\*.} ]] && covered=1
        done
        ((covered)) || { log::error "Verification: the issued certificate does not cover ${d} (SAN: ${have})."; return 1; }
      fi
    done
  fi

  log::debug "Verification passed for '${name}' ($(openssl x509 -in "$leaf" -noout -subject | sed 's/^subject=//'))."
  return 0
}

# --- Atomic installation ---------------------------------------------------

certs::_apply_permissions() {
  local dir=$1
  chmod 750 "$dir" 2>/dev/null || true
  chmod 600 "${dir}/privkey.pem" 2>/dev/null || true
  local f
  for f in cert.pem chain.pem fullchain.pem; do
    [[ -e "${dir}/${f}" ]] && chmod 644 "${dir}/${f}"
  done
  return 0
}

# Replace the live certificate with the one from the staging directory.
# The previous one is kept so a rollback stays possible.
certs::install() {
  local name=$1 staging=$2
  local live; live=$(config::cert_path "$name")

  certs::verify_bundle "$staging" "$name" || return 1

  mkdir -p "$CFG_CERT_DIR"
  local backup="${CFG_BACKUP_DIR}/${name}"
  if [[ -d $live ]]; then
    rm -rf "$backup"
    mkdir -p "$CFG_BACKUP_DIR"
    cp -a "$live" "$backup"
    log::debug "Previous certificate backed up to ${backup}."
  fi

  certs::_apply_permissions "$staging"

  # Swap by rename: the destination directory is never partially written.
  local previous="${live}.previous.$$"
  if [[ -d $live ]]; then mv "$live" "$previous"; fi
  if ! mv "$staging" "$live"; then
    log::error "Could not install certificate '${name}'."
    [[ -d $previous ]] && mv "$previous" "$live"
    return 1
  fi
  rm -rf "$previous"
  log::debug "Certificate '${name}' installed in ${live}."
  return 0
}

# Restore the last known-good backup.
certs::rollback() {
  local name=$1
  local live backup
  live=$(config::cert_path "$name")
  backup="${CFG_BACKUP_DIR}/${name}"
  [[ -d $backup ]] || { log::error "No backup available for '${name}'."; return 1; }
  rm -rf "$live"
  cp -a "$backup" "$live"
  certs::_apply_permissions "$live"
  log::warn "Rolled back '${name}' to the previous certificate."
}

# --- Machine-readable state ------------------------------------------------

certs::status_json_one() {
  local name=$1
  local exists=false days='null' not_after='' issuer='' selfsigned=false reason
  if certs::exists "$name"; then
    exists=true
    days=$(certs::days_left "$name" 2>/dev/null || printf 'null')
    not_after=$(certs::not_after "$name" 2>/dev/null || printf '')
    issuer=$(certs::issuer "$name" 2>/dev/null || printf '')
    certs::is_selfsigned "$name" && selfsigned=true
  fi
  reason=$(certs::renewal_reason "$name")

  printf '{"name":"%s","domains":[%s],"kind":"%s","provider":"%s","exists":%s,"days_left":%s,"not_after":"%s","issuer":"%s","self_signed":%s,"renewal_needed":%s,"renewal_reason":"%s"}' \
    "$(log::_json_escape "$name")" \
    "$(printf '"%s",' ${NC_SPEC_DOMAINS[$name]} | sed 's/,$//')" \
    "${NC_SPEC_KIND[$name]}" \
    "${NC_SPEC_PROVIDER[$name]}" \
    "$exists" "${days:-null}" \
    "$(log::_json_escape "$not_after")" \
    "$(log::_json_escape "$issuer")" \
    "$selfsigned" \
    "$( [[ -n $reason ]] && printf true || printf false)" \
    "$(log::_json_escape "$reason")"
}
