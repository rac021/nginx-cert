#!/usr/bin/env bash
# lib/issue.sh — Issuance orchestration: authority chain and retries.
#
# Strategy, for each certificate:
#
#   for each authority in the chain (CERT_PROVIDER_CHAIN in auto mode)
#       up to CERT_ATTEMPTS attempts, delay doubled between attempts
#       if all attempts fail -> move to the next authority
#   if every authority fails -> self-signed certificate (last link)
#
# The last link is not an admission of defeat: it guarantees nginx starts and
# the service stays reachable even when every authority is unavailable. A real
# authority takes over again at the next scheduled run.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   NC_LAST_PROVIDER is read by bin/certme (revoke command).

[[ -n ${NC_LIB_ISSUE_SH:-} ]] && return 0
readonly NC_LIB_ISSUE_SH=1

declare -a NC_CHANGED=()   # certificates actually renewed
declare -a NC_FAILED=()    # certificates no authority could deliver
declare -a NC_SKIPPED=()   # certificates still valid
declare -A NC_LAST_PROVIDER=()  # authority that actually issued each certificate

# --- Post-failure backoff --------------------------------------------------
#
# Without this, a container stuck in a restart loop fires a fresh request on
# every boot and exhausts the authority's quota within minutes -- the single
# most common way to get blocked by Let's Encrypt.

issue::_failure_file() { printf '%s/failures/%s' "$CFG_STATE_DIR" "$1"; }

issue::_record_failure() {
  local name=$1 file; file=$(issue::_failure_file "$name")
  mkdir -p "$(dirname "$file")"
  local count=0
  [[ -r $file ]] && count=$(cut -d' ' -f2 <"$file" 2>/dev/null || printf 0)
  [[ $count =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  printf '%s %s\n' "$(date -u +%s)" "$count" | util::atomic_write "$file" 0644
}

issue::_clear_failure() { rm -f "$(issue::_failure_file "$1")"; }

# Remaining backoff in seconds, 0 when a retry is allowed.
issue::_cooldown_remaining() {
  local name=$1 file; file=$(issue::_failure_file "$name")
  [[ -r $file ]] || { printf '0'; return; }

  local last count base max wait now
  read -r last count <"$file" 2>/dev/null || { printf '0'; return; }
  [[ $last =~ ^[0-9]+$ && $count =~ ^[0-9]+$ ]] || { printf '0'; return; }

  base=$(util::parse_duration "${CERT_FAILURE_COOLDOWN:-30m}")
  max=$(util::parse_duration "${CERT_FAILURE_COOLDOWN_MAX:-12h}")
  ((base > 0)) || base=1800
  ((max > 0)) || max=43200

  wait=$base
  local i=1
  while ((i < count && wait < max)); do wait=$((wait * 2)); i=$((i + 1)); done
  ((wait > max)) && wait=$max

  now=$(date -u +%s)
  local remaining=$(( last + wait - now ))
  ((remaining < 0)) && remaining=0
  printf '%s' "$remaining"
}

# --- Effective chain -------------------------------------------------------
issue::_chain() {
  local name=$1
  local kind=${NC_SPEC_KIND[$name]}
  local requested=${NC_SPEC_PROVIDER[$name]}
  local staging=${NC_SPEC_STAGING[$name]:-$CFG_STAGING}

  local -a chain=()
  local line
  while IFS= read -r line; do [[ -n $line ]] && chain+=("$line"); done \
    < <(provider::chain_for "$requested" "$kind" "$staging" || true)

  # ZeroSSL's REST API is the only route to a long-lived IP-address
  # certificate; it slots in just before the self-signed fallback.
  if [[ $kind == ip ]] && zerossl_rest::available && [[ $requested == auto || $requested == zerossl* ]]; then
    local -a with_rest=()
    local p inserted=0
    for p in ${chain[@]+"${chain[@]}"}; do
      if [[ $p == selfsigned && $inserted -eq 0 ]]; then with_rest+=("zerossl-rest"); inserted=1; fi
      with_rest+=("$p")
    done
    ((inserted)) || with_rest+=("zerossl-rest")
    chain=("${with_rest[@]}")
  fi

  printf '%s\n' ${chain[@]+"${chain[@]}"}
}

issue::_provider_label() {
  case $1 in
    selfsigned)   printf 'local self-signed certificate' ;;
    zerossl-rest) printf 'ZeroSSL (REST API)' ;;
    *)            provider::label "$1" ;;
  esac
}

# Dispatch to the right driver. Returns 0 success, 2 nothing to do, 1 failure.
issue::_call_provider() {
  local provider=$1 name=$2 staging_dir=$3 force=$4; shift 4
  local -a domains=("$@")
  case $provider in
    selfsigned)   selfsigned::issue "$name" "$staging_dir" "${domains[@]}" ;;
    zerossl-rest) zerossl_rest::issue "$name" "$staging_dir" "${domains[@]}" ;;
    *)            acme::issue "$name" "$provider" "$staging_dir" "$force" "${domains[@]}" ;;
  esac
}

# Ensure a certificate exists on disk for every declared name.
#
# nginx refuses to start when an ssl_certificate points at a missing file,
# while the HTTP-01 challenge requires nginx to already be listening on port
# 80. We break that circular dependency by first dropping in a temporary local
# certificate -- instantaneous and network-free -- which the real authority
# replaces seconds later. This is what makes the first boot reliable, whereas
# v1 tried to issue before nginx had even started.
issue::ensure_placeholders() {
  local name created=0
  for name in ${NC_SPEC_NAMES[@]+"${NC_SPEC_NAMES[@]}"}; do
    certs::exists "$name" && continue
    local -a domains=(); read -r -a domains <<<"${NC_SPEC_DOMAINS[$name]}"
    log::info "'${name}': installing a temporary local certificate until the real one arrives."
    local dir; dir=$(mktemp -d "${CFG_DATA_DIR}/.staging.XXXXXX") || return 1
    if selfsigned::issue "$name" "$dir" "${domains[@]}" && certs::install "$name" "$dir"; then
      created=$((created + 1))
    else
      rm -rf "$dir"
      log::error "Could not create the temporary certificate for '${name}'."
      return 1
    fi
  done
  ((created)) && log::debug "${created} temporary certificate(s) created."
  return 0
}

# --- Issuing one certificate -----------------------------------------------
# Returns: 0 = renewed, 2 = unchanged, 1 = failed
issue::one() {
  local name=$1
  local -a domains=(); read -r -a domains <<<"${NC_SPEC_DOMAINS[$name]}"

  local reason; reason=$(certs::renewal_reason "$name")
  if [[ -z $reason ]]; then
    log::info "'${name}': still valid for $(certs::days_left "$name") day(s), nothing to do."
    NC_SKIPPED+=("$name")
    return 2
  fi

  log::section "Certificate '${name}' -- ${reason}"

  # An existing certificate protects the service, so we honour the backoff.
  # With no certificate at all we try immediately, falling back to self-signed
  # if needed.
  if certs::exists "$name"; then
    local cooldown; cooldown=$(issue::_cooldown_remaining "$name")
    if ((cooldown > 0)); then
      log::warn "'${name}': recent failure, next attempt in $(util::human_duration "$cooldown") (quota protection)."
      NC_SKIPPED+=("$name")
      return 2
    fi
  fi

  local -a chain=()
  local line
  while IFS= read -r line; do [[ -n $line ]] && chain+=("$line"); done < <(issue::_chain "$name")

  if ((${#chain[@]} == 0)); then
    log::error "'${name}': no eligible authority (kind '${NC_SPEC_KIND[$name]}', provider '${NC_SPEC_PROVIDER[$name]}')."
    log::error "  -> Enable CERT_FALLBACK_SELFSIGNED=true or pick a compatible provider."
    NC_FAILED+=("$name")
    return 1
  fi
  log::debug "Authority chain for '${name}': ${chain[*]}"

  # acme.sh keeps its own bookkeeping; we force renewal when our copy is
  # missing or when the user explicitly asked for it.
  local force=0
  { util::is_true "${CFG_FORCE_RENEW:-false}" || ! certs::exists "$name"; } && force=1

  local provider attempt rc staging_dir
  for provider in "${chain[@]}"; do
    local max_attempts=$CFG_ATTEMPTS
    # Local issuance depends on no network: retrying it is pointless.
    [[ $provider == selfsigned ]] && max_attempts=1

    local delay=$CFG_RETRY_DELAY
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
      staging_dir=$(mktemp -d "${CFG_DATA_DIR}/.staging.XXXXXX") || {
        log::error "Could not create a staging directory under ${CFG_DATA_DIR}."
        NC_FAILED+=("$name"); return 1; }

      ((max_attempts > 1)) && log::info "  Attempt ${attempt}/${max_attempts} with $(issue::_provider_label "$provider")."

      rc=0
      issue::_call_provider "$provider" "$name" "$staging_dir" "$force" "${domains[@]}" || rc=$?

      if ((rc == 0)); then
        if certs::install "$name" "$staging_dir"; then
          issue::_clear_failure "$name"
          NC_CHANGED+=("$name")
          NC_LAST_PROVIDER[$name]=$provider
          certs::record_provider "$name" "$provider"
          log::ok "'${name}' issued by $(issue::_provider_label "$provider") -- expires $(certs::not_after "$name")."
          [[ $provider == selfsigned ]] && log::warn \
            "  -> This certificate is NOT publicly trusted. The service is up, but browsers will warn."
          return 0
        fi
        log::error "  The certificate returned by $(issue::_provider_label "$provider") failed verification and was discarded."
        rm -rf "$staging_dir"
        rc=1
      elif ((rc == 2)); then
        rm -rf "$staging_dir"
        issue::_clear_failure "$name"
        NC_SKIPPED+=("$name")
        return 2
      else
        rm -rf "$staging_dir"
      fi

      if ((attempt < max_attempts)); then
        log::info "  Retrying in ${delay}s…"
        sleep "$delay"
        delay=$((delay * 2)); ((delay > 300)) && delay=300
      fi
    done

    log::warn "$(issue::_provider_label "$provider") did not deliver '${name}' after ${max_attempts} attempt(s)."
    [[ $provider != "${chain[-1]}" ]] && log::info "-> Falling back to the next authority."
  done

  issue::_record_failure "$name"
  log::error "'${name}': no authority in the chain delivered a certificate (${chain[*]})."
  NC_FAILED+=("$name")
  return 1
}

# Process every declared certificate.
# Returns: 0 if anything changed, 2 if nothing did, 1 if anything failed.
issue::all() {
  NC_CHANGED=(); NC_FAILED=(); NC_SKIPPED=()
  local name
  for name in ${NC_SPEC_NAMES[@]+"${NC_SPEC_NAMES[@]}"}; do
    issue::one "$name" || true
  done

  ((${#NC_FAILED[@]}))  && return 1
  ((${#NC_CHANGED[@]})) && return 0
  return 2
}

issue::_summarize() {
  local -n _a=$1
  ((${#_a[@]} == 0)) && { printf '0'; return; }
  printf '%d: %s' "${#_a[@]}" "${_a[*]}"
}

issue::report() {
  log::section "Summary"
  log::kv "Renewed"   "$(issue::_summarize NC_CHANGED)"
  log::kv "Unchanged" "$(issue::_summarize NC_SKIPPED)"
  log::kv "Failed"    "$(issue::_summarize NC_FAILED)"
}
