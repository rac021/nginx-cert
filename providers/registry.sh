#!/usr/bin/env bash
# providers/registry.sh — Reads the declarative table of ACME authorities.
#
# Everything the rest of the program knows about an authority comes from here.
# Adding one means adding a line to providers.tsv: no extra conditional branch
# anywhere.
# shellcheck shell=bash

[[ -n ${NC_PROVIDERS_REGISTRY_SH:-} ]] && return 0
readonly NC_PROVIDERS_REGISTRY_SH=1

declare -a NC_PROVIDER_IDS=()
declare -A NC_PROVIDER_LABEL=() NC_PROVIDER_ALIAS=() NC_PROVIDER_DIRECTORY=()
declare -A NC_PROVIDER_EAB=() NC_PROVIDER_STAGING=() NC_PROVIDER_CAPS=() NC_PROVIDER_NOTES=()

NC_PROVIDERS_LOADED=0

provider::load() {
  ((NC_PROVIDERS_LOADED)) && return 0
  local file="${NC_ROOT}/providers/providers.tsv"
  [[ -r $file ]] || log::die "$EX_DEPS" "Provider table not found: ${file}"

  local id label alias directory eab staging caps notes
  while IFS=$'\t' read -r id label alias directory eab staging caps notes; do
    [[ -z $id || $id == '#'* ]] && continue
    NC_PROVIDER_IDS+=("$id")
    NC_PROVIDER_LABEL[$id]=$label
    NC_PROVIDER_ALIAS[$id]=$alias
    NC_PROVIDER_DIRECTORY[$id]=$directory
    NC_PROVIDER_EAB[$id]=$eab
    NC_PROVIDER_STAGING[$id]=$staging
    NC_PROVIDER_CAPS[$id]=$caps
    NC_PROVIDER_NOTES[$id]=$notes
  done <"$file"

  ((${#NC_PROVIDER_IDS[@]})) || log::die "$EX_DEPS" "Provider table is empty: ${file}"
  NC_PROVIDERS_LOADED=1
}

provider::list_ids() { provider::load; printf '%s\n' "${NC_PROVIDER_IDS[@]}"; }
provider::exists()   { provider::load; [[ -n ${NC_PROVIDER_LABEL[${1:-}]:-} ]]; }
provider::label()    { provider::load; printf '%s' "${NC_PROVIDER_LABEL[$1]:-$1}"; }
provider::alias()    { provider::load; printf '%s' "${NC_PROVIDER_ALIAS[$1]:--}"; }
provider::directory(){ provider::load; printf '%s' "${NC_PROVIDER_DIRECTORY[$1]:-}"; }
provider::notes()    { provider::load; printf '%s' "${NC_PROVIDER_NOTES[$1]:-}"; }
provider::needs_eab(){ provider::load; [[ ${NC_PROVIDER_EAB[$1]:-no} == required ]]; }

# Identifier to hand to acme.sh: its alias when the tool knows one, otherwise
# the full directory URL.
provider::server_arg() {
  provider::load
  local id=$1 a=${NC_PROVIDER_ALIAS[$1]:--}
  [[ $a != '-' && -n $a ]] && { printf '%s' "$a"; return; }
  printf '%s' "${NC_PROVIDER_DIRECTORY[$id]}"
}

# Switch to the matching staging environment when the authority has one.
provider::staging_variant() {
  provider::load
  local id=$1 s=${NC_PROVIDER_STAGING[$1]:--}
  [[ $s != '-' && -n $s ]] && { printf '%s' "$s"; return; }
  printf '%s' "$id"
}

# provider::supports <id> <fqdn|wildcard|ip>
provider::supports() {
  provider::load
  local caps=",${NC_PROVIDER_CAPS[$1]:-},"
  [[ $caps == *",$2,"* ]]
}

# --- External Account Binding ----------------------------------------------

# Are usable EAB credentials available for this authority?
provider::eab_available() {
  local id=$1
  provider::needs_eab "$id" || return 0
  [[ -n ${CFG_EAB_KID:-} && -n ${CFG_EAB_HMAC_KEY:-} ]] && return 0
  # ZeroSSL can mint an EAB from a plain API key.
  [[ $id == zerossl && -n ${CFG_ZEROSSL_API_KEY:-} ]] && return 0
  return 1
}

# Populate NC_EAB_KID / NC_EAB_HMAC for the given authority.
# Returns 1 when the authority requires an EAB we cannot provide.
provider::resolve_eab() {
  local id=$1
  NC_EAB_KID=''; NC_EAB_HMAC=''

  # Explicitly supplied credentials always win, whatever the table says.
  #
  # This is not a nicety: with CERT_ACME_SERVER pointing at another directory,
  # the table entry is only a carrier and its "eab: no" describes a server we
  # are not talking to. Consulting the table first meant the credentials were
  # silently dropped and the real server answered "externalAccountRequired".
  # A server that does not need an EAB ignores one that is sent.
  if [[ -n ${CFG_EAB_KID:-} && -n ${CFG_EAB_HMAC_KEY:-} ]]; then
    NC_EAB_KID=$CFG_EAB_KID
    NC_EAB_HMAC=$CFG_EAB_HMAC_KEY
    return 0
  fi

  provider::needs_eab "$id" || return 0

  if [[ $id == zerossl && -n ${CFG_ZEROSSL_API_KEY:-} ]]; then
    provider::_zerossl_eab && return 0
    return 1
  fi

  log::error "$(provider::label "$id") requires External Account Binding: set CERT_EAB_KID and CERT_EAB_HMAC_KEY."
  log::detail error "$(provider::notes "$id")"
  return 1
}

# Derive and cache ZeroSSL EAB credentials from the API key.
# ZeroSSL credentials are reusable, so one derivation is enough.
provider::_zerossl_eab() {
  local cache="${CFG_STATE_DIR}/zerossl-eab.env"

  if [[ -r $cache ]]; then
    # shellcheck disable=SC1090
    source "$cache"
    if [[ -n ${NC_EAB_KID:-} && -n ${NC_EAB_HMAC:-} ]]; then
      log::debug "Reusing cached ZeroSSL EAB credentials."
      log::secret "$NC_EAB_HMAC" "$NC_EAB_KID"
      return 0
    fi
  fi

  log::info "Deriving ZeroSSL EAB credentials from the API key…"
  local resp
  # The key is registered as a secret (log::secret), so it is masked in all of
  # our output even if the URL were ever logged.
  resp=$(curl -sS --max-time 30 -X POST \
           "https://api.zerossl.com/acme/eab-credentials?access_key=${CFG_ZEROSSL_API_KEY}" 2>/dev/null) || {
    log::error "Could not reach the ZeroSSL API (network or quota)."
    return 1
  }

  local ok kid hmac
  ok=$(printf '%s' "$resp"   | jq -r '.success // 0')
  kid=$(printf '%s' "$resp"  | jq -r '.eab_kid // empty')
  hmac=$(printf '%s' "$resp" | jq -r '.eab_hmac_key // empty')

  if [[ $ok != 1 || -z $kid || -z $hmac ]]; then
    local err; err=$(printf '%s' "$resp" | jq -r '.error.type // .error.info // "unexpected response"')
    log::error "ZeroSSL refused the EAB derivation: ${err}"
    return 1
  fi

  NC_EAB_KID=$kid
  NC_EAB_HMAC=$hmac
  log::secret "$hmac" "$kid"

  mkdir -p "$CFG_STATE_DIR"
  { printf 'NC_EAB_KID=%q\n' "$kid"; printf 'NC_EAB_HMAC=%q\n' "$hmac"; } \
    | util::atomic_write "$cache" 0600
  log::ok "ZeroSSL EAB credentials obtained and cached."
  return 0
}

# --- Fallback chain --------------------------------------------------------
#
# Builds the ordered list of authorities to try for a given certificate.
# Discarded: those that cannot issue this kind of name, and those whose EAB
# credentials are missing. "selfsigned" always closes the list when
# CERT_FALLBACK_SELFSIGNED is on -- the container must start even when every
# authority is unreachable.
#
# usage: provider::chain_for <requested_provider> <kind> <staging>
provider::chain_for() {
  local requested=$1 kind=$2 staging=$3
  local -a candidates=()

  if [[ $requested == selfsigned ]]; then
    printf 'selfsigned\n'; return 0
  fi

  if [[ $requested == auto ]]; then
    util::split_into candidates ',' "$CFG_PROVIDER_CHAIN"
  else
    candidates=("$requested")
  fi

  local cap=$kind
  [[ $kind == internal || $kind == localhost ]] && cap='none'

  # An internal name is unreachable for a *public* authority, which is why it
  # normally collapses to the local one. It is not unreachable for a private
  # ACME server: pointing CERT_ACME_SERVER at step-ca or EJBCA and naming a
  # carrier provider is the documented way to certify *.internal, *.lan or a
  # single label -- and it could never work, because the name was filtered out
  # before the overridden directory was ever consulted.
  if [[ $cap == none && -n ${CFG_ACME_SERVER:-} && $requested != auto ]]; then
    log::debug "CERT_ACME_SERVER is set and '${requested}' is pinned: '${kind}' names are sent to it rather than to the local authority."
    cap=$kind
    [[ $kind == internal || $kind == localhost ]] && cap='fqdn'
  fi

  local id out=() skipped=()
  for id in ${candidates[@]+"${candidates[@]}"}; do
    if ! provider::exists "$id"; then
      log::warn "CERT_PROVIDER_CHAIN: '${id}' is not in providers.tsv, ignoring it."
      continue
    fi
    if util::is_true "$staging"; then
      local prod=$id
      id=$(provider::staging_variant "$id")
      [[ $id == "$prod" ]] && log::warn \
        "CERT_STAGING is on but $(provider::label "$prod") has no staging environment: issuance will hit production."
    fi

    local reason=''
    if [[ $cap == none ]] || ! provider::supports "$id" "$cap"; then
      reason="it does not issue '${kind}' certificates"
    elif ! provider::eab_available "$id"; then
      reason="its EAB credentials are missing (CERT_EAB_KID / CERT_EAB_HMAC_KEY)"
    fi

    if [[ -n $reason ]]; then
      # Skipping one candidate of an automatic chain is routine. Skipping the
      # provider the operator explicitly asked for is not: without a warning
      # the run ends on a self-signed certificate with no visible reason.
      if [[ $requested == auto ]]; then
        skipped+=("${id} (${reason})")
      else
        log::warn "CERT_PROVIDER=${requested} was skipped because ${reason}."
        log::detail warn "$(provider::notes "$id")"
      fi
      continue
    fi
    out+=("$id")
  done

  ((${#skipped[@]})) && log::debug "Authorities skipped: ${skipped[*]}"

  local final=(${out[@]+"${out[@]}"})
  if util::is_true "${CFG_FALLBACK_SELFSIGNED:-true}"; then
    final+=("selfsigned")
  fi
  ((${#final[@]})) || return 1
  printf '%s\n' "${final[@]}"
}
