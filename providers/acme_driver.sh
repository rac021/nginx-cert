#!/usr/bin/env bash
# providers/acme_driver.sh — The single ACME driver (RFC 8555), via acme.sh.
#
# Let's Encrypt, ZeroSSL, Actalis, Buypass, Google Trust Services and SSL.com
# all speak the same protocol. The only differences are the directory URL, the
# presence of External Account Binding, and the accepted name types -- three
# pieces of data carried by providers.tsv. There is therefore exactly one
# issuance code path, whatever the authority.
# shellcheck shell=bash

[[ -n ${NC_PROVIDERS_ACME_SH:-} ]] && return 0
readonly NC_PROVIDERS_ACME_SH=1

NC_ACME_BIN="${NC_ACME_BIN:-/usr/local/bin/acme.sh}"

# acme.sh exit code meaning "certificate is not due for renewal".
readonly ACME_RENEW_SKIP=2

acme::available() { [[ -x $NC_ACME_BIN ]]; }

acme::version() {
  acme::available || { printf 'absent'; return 1; }
  "$NC_ACME_BIN" --version 2>/dev/null | tail -n1
}

# Some authorities require a specific certificate profile depending on the name
# type. Let's Encrypt only issues "shortlived" (160-hour) certificates for IP
# addresses: without that profile the request is rejected.
acme::_profile_for() {
  local provider=$1 kind=$2 explicit=$3
  [[ -n $explicit ]] && { printf '%s' "$explicit"; return; }
  if [[ $kind == ip && $provider == letsencrypt* ]]; then
    printf 'shortlived'
  fi
}

# Issue or renew a certificate.
#
# usage: acme::issue <name> <provider_id> <output_dir> <force:0|1> <domain...>
# returns: 0 = certificate written to the output directory
#          2 = nothing to do, the current certificate is still valid
#          1 = failure
acme::issue() {
  local name=$1 provider=$2 outdir=$3 force=$4; shift 4
  local -a domains=("$@")

  acme::available || { log::error "acme.sh not found (${NC_ACME_BIN})."; return 1; }

  local kind=${NC_SPEC_KIND[$name]:-fqdn}
  local key_type=${NC_SPEC_KEY_TYPE[$name]:-$CFG_KEY_TYPE}
  local challenge=${NC_SPEC_CHALLENGE[$name]:-$CFG_CHALLENGE}
  local dns_provider=${NC_SPEC_DNS[$name]:-$CFG_DNS_PROVIDER}
  local profile; profile=$(acme::_profile_for "$provider" "$kind" "${NC_SPEC_PROFILE[$name]:-$CFG_PROFILE}")

  # --- Challenge resolution ----------------------------------------------
  if [[ $challenge == auto ]]; then
    if domain::requires_dns01 "$kind"; then challenge=dns-01; else challenge=http-01; fi
  fi
  [[ $challenge == http ]] && challenge=http-01
  [[ $challenge == dns ]]  && challenge=dns-01

  if [[ $challenge == dns-01 && -z $dns_provider ]]; then
    log::error "'${name}' needs a DNS-01 challenge but no DNS provider is configured (CERT_DNS_PROVIDER)."
    return 1
  fi

  # --- EAB credentials ----------------------------------------------------
  provider::resolve_eab "$provider" || return 1

  # CERT_ACME_SERVER overrides the directory URL for any authority. This is the
  # escape hatch for a private or corporate ACME server (step-ca, Smallstep,
  # EJBCA, Vault) that has no entry in providers.tsv.
  local server; server=$(provider::server_arg "$provider")
  [[ -n ${CFG_ACME_SERVER:-} ]] && server=$CFG_ACME_SERVER

  mkdir -p "$outdir" "$CFG_ACME_HOME" "$CFG_WEBROOT"

  # --- Command assembly ---------------------------------------------------
  local -a cmd=(
    "$NC_ACME_BIN" --issue
    --home "$CFG_ACME_HOME"
    --config-home "$CFG_ACME_HOME"
    --cert-home "${CFG_ACME_HOME}/certs"
    --log "${CFG_ACME_HOME}/acme.log"
    --server "$server"
    --keylength "$key_type"
    --days "$CFG_RENEW_DAYS"
    --email "$CFG_EMAIL"
    --cert-file "${outdir}/cert.pem"
    --key-file "${outdir}/privkey.pem"
    --ca-file "${outdir}/chain.pem"
    --fullchain-file "${outdir}/fullchain.pem"
  )

  local d
  for d in "${domains[@]}"; do cmd+=(-d "$d"); done

  if [[ $challenge == dns-01 ]]; then
    cmd+=(--dns "$dns_provider" --dnssleep "$CFG_DNS_SLEEP")
  else
    cmd+=(--webroot "$CFG_WEBROOT")
  fi

  [[ -n ${NC_EAB_KID:-} ]]  && cmd+=(--eab-kid "$NC_EAB_KID")
  [[ -n ${NC_EAB_HMAC:-} ]] && cmd+=(--eab-hmac-key "$NC_EAB_HMAC")
  [[ -n $profile ]] && cmd+=(--cert-profile "$profile")
  ((force)) && cmd+=(--force)
  log::enabled debug && cmd+=(--debug)

  # Documented escape hatch: acme.sh options nginx-cert does not expose.
  if [[ -n ${CFG_ACME_ARGS:-} ]]; then
    local -a extra=(); read -r -a extra <<<"$CFG_ACME_ARGS"
    cmd+=(${extra[@]+"${extra[@]}"})
  fi

  log::info "-> $(provider::label "$provider"): requesting a certificate for ${domains[*]} (${challenge} challenge${profile:+, ${profile} profile})."
  log::debug "Command: $(log::redact "${cmd[*]}")"

  # --- Execution ----------------------------------------------------------
  #
  # The time bound is essential: when an authority's ACME directory is
  # unreachable, acme.sh retries internally for several minutes. Without it, a
  # single broken authority would stall the whole fallback chain and delay
  # service startup by just as long.
  local timeout_s; timeout_s=$(util::parse_duration "${CERT_ACME_TIMEOUT:-5m}")
  ((timeout_s > 0)) || timeout_s=300

  local out rc=0
  out=$(timeout "$timeout_s" "${cmd[@]}" 2>&1) || rc=$?

  if ((rc == 124)); then
    log::warn "$(provider::label "$provider") did not respond within $(util::human_duration "$timeout_s"): giving up on this authority."
    log::warn "  -> Raise CERT_ACME_TIMEOUT if your link is slow."
    return 1
  fi

  if ((rc == 0)); then
    log::ok "$(provider::label "$provider") issued certificate '${name}'."
    log::debug "$out"
    return 0
  fi

  if ((rc == ACME_RENEW_SKIP)); then
    log::info "'${name}': certificate still valid at $(provider::label "$provider"), nothing to do."
    return "$ACME_RENEW_SKIP"
  fi

  log::warn "$(provider::label "$provider") failed for '${name}' (exit ${rc})."
  acme::_explain_failure "$provider" "$out"
  return 1
}

# Translate the most common ACME errors into actionable advice. Without this
# the user only sees several hundred lines of acme.sh trace and no idea what to
# fix.
acme::_explain_failure() {
  local provider=$1 out=$2
  local hint=''

  case $out in
    *'invalidContact'*|*'forbidden domain'*)
      hint="CERT_EMAIL was rejected by $(provider::label "$provider"). Reserved example domains (example.com, test, ...) are refused: use a real address." ;;
    *'Cannot init API'*|*'Can not init api'*)
      hint="$(provider::label "$provider")'s ACME directory is unreachable from this container (egress, DNS, or the service is down)." ;;
    *'rateLimited'*|*'too many certificates'*|*'Rate Limit'*)
      hint="Quota reached at $(provider::label "$provider"). Wait for the reset window, or set CERT_STAGING=true while testing." ;;
    *'urn:ietf:params:acme:error:unauthorized'*|*'Invalid response from'*|*'404'*)
      hint="HTTP-01 validation failed: port 80 must be reachable from the internet and routed to this container. Check the domain's DNS, that port 80 is published, and any firewall." ;;
    *'externalAccountRequired'*|*'external account binding'*)
      hint="$(provider::label "$provider") requires valid External Account Binding credentials. $(provider::notes "$provider")" ;;
    *'DNS problem'*|*'NXDOMAIN'*|*'no valid A records'*)
      hint="The requested name does not resolve publicly. Fix the DNS record before retrying." ;;
    *'dnsapi'*|*'Add txt record error'*)
      hint="acme.sh's DNS module could not create the TXT record. Check your DNS provider's API credentials." ;;
    *'Timeout'*|*'timed out'*|*'Could not resolve host'*)
      hint="The ACME server is unreachable from the container (egress network or DNS)." ;;
  esac

  [[ -n $hint ]] && log::warn "  -> ${hint}"

  # The full trace stays available without polluting the nominal output.
  if log::enabled debug; then
    log::debug "$out"
  else
    log::warn "  -> Full trace: ${CFG_ACME_HOME}/acme.log (or CERT_LOG_LEVEL=debug)."
    printf '%s\n' "$out" | tail -n 12 | while IFS= read -r l; do log::warn "  | $(log::redact "$l")"; done
  fi
}

# Revoke a certificate with the authority that issued it.
acme::revoke() {
  local name=$1 provider=$2
  acme::available || return 1
  local -a doms=(); read -r -a doms <<<"${NC_SPEC_DOMAINS[$name]:-$name}"
  "$NC_ACME_BIN" --revoke \
    --home "$CFG_ACME_HOME" --config-home "$CFG_ACME_HOME" \
    --cert-home "${CFG_ACME_HOME}/certs" \
    --server "$(provider::server_arg "$provider")" \
    -d "${doms[0]}" 2>&1 | while IFS= read -r l; do log::info "$l"; done
}
