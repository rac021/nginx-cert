#!/usr/bin/env bash
# providers/zerossl_rest.sh — ZeroSSL REST API, reserved for IP addresses.
#
# Why this exception to the "everything goes through ACME" rule: ZeroSSL's ACME
# endpoint does not issue certificates for IP addresses, while its REST API
# does (paid plan). That is the only case the ACME driver cannot cover. For
# everything else -- including ZeroSSL on domain names -- the ACME driver is
# used, with an EAB derived from the very same API key.
#
# Fully-ACME alternative for IP addresses: Let's Encrypt with the "shortlived"
# profile (160-hour certificates), selected automatically.
# shellcheck shell=bash

[[ -n ${NC_PROVIDERS_ZEROSSL_REST_SH:-} ]] && return 0
readonly NC_PROVIDERS_ZEROSSL_REST_SH=1

readonly ZS_API='https://api.zerossl.com'

zerossl_rest::available() { [[ -n ${CFG_ZEROSSL_API_KEY:-} ]]; }

zerossl_rest::_url() {
  local path=$1
  local sep='?'; [[ $path == *'?'* ]] && sep='&'
  printf '%s%s%saccess_key=%s' "$ZS_API" "$path" "$sep" "$CFG_ZEROSSL_API_KEY"
}

# usage: zerossl_rest::issue <name> <output_dir> <domain...>
zerossl_rest::issue() {
  local name=$1 outdir=$2; shift 2
  local -a domains=("$@")

  zerossl_rest::available || {
    log::error "CERT_ZEROSSL_API_KEY is required for the ZeroSSL REST API."
    return 1
  }
  util::require_cmds curl jq openssl

  local key_type=${NC_SPEC_KEY_TYPE[$name]:-$CFG_KEY_TYPE}
  local validity=${CERT_ZEROSSL_VALIDITY_DAYS:-90}
  local timeout; timeout=$(util::parse_duration "${CERT_ZEROSSL_TIMEOUT:-5m}")

  mkdir -p "$outdir"
  local key="${outdir}/privkey.pem"
  local csr="${outdir}/request.csr"

  # --- Key and CSR --------------------------------------------------------
  selfsigned::_genkey "$key_type" "$key" || {
    log::error "Could not generate the private key."; return 1; }
  chmod 600 "$key"

  local san; san=$(domain::san_string "${domains[@]}")
  openssl req -new -key "$key" -out "$csr" -subj "/CN=${domains[0]}" \
    -addext "subjectAltName=${san}" 2>/dev/null || {
    log::error "Could not generate the CSR."; return 1; }

  # --- Draft certificate --------------------------------------------------
  log::info "-> ZeroSSL (REST): requesting a certificate for ${domains[*]} (${validity}-day validity)."
  local resp
  resp=$(curl -sS --max-time 60 -X POST "$(zerossl_rest::_url '/certificates')" \
           -d "certificate_domains=$(util::join ',' "${domains[@]}")" \
           -d "certificate_validity_days=${validity}" \
           --data-urlencode "certificate_csr@${csr}" 2>/dev/null) || {
    log::error "ZeroSSL is unreachable."; return 1; }

  local cert_id; cert_id=$(printf '%s' "$resp" | jq -r '.id // empty')
  if [[ -z $cert_id ]]; then
    log::error "ZeroSSL rejected the request: $(printf '%s' "$resp" | jq -rc '.error // .' 2>/dev/null)"
    return 1
  fi
  log::debug "ZeroSSL draft certificate: ${cert_id}"

  # From here on, any failure must cancel the draft: otherwise drafts pile up
  # silently and eat into the account's quota.
  local rc=1
  if zerossl_rest::_validate_and_download "$name" "$outdir" "$cert_id" "$resp" "$timeout" "${domains[@]}"; then
    rc=0
  else
    log::warn "Cancelling ZeroSSL draft ${cert_id}."
    curl -sS --max-time 30 -X POST "$(zerossl_rest::_url "/certificates/${cert_id}/cancel")" \
      >/dev/null 2>&1 || true
  fi
  rm -f "$csr"
  return "$rc"
}

zerossl_rest::_validate_and_download() {
  local name=$1 outdir=$2 cert_id=$3 draft=$4 timeout=$5; shift 5
  local -a domains=("$@")

  # --- Validation files ---------------------------------------------------
  local vpath="${CFG_WEBROOT}/.well-known/pki-validation"
  mkdir -p "$vpath"

  local d url content fname
  local -a written=()
  for d in "${domains[@]}"; do
    url=$(printf '%s' "$draft" | jq -r --arg d "$d" \
            '.validation.other_methods[$d].file_validation_url_http // empty')
    content=$(printf '%s' "$draft" | jq -r --arg d "$d" \
            '.validation.other_methods[$d].file_validation_content | if . == null then empty else join("\n") end')
    if [[ -z $url || -z $content ]]; then
      log::error "ZeroSSL returned no validation data for ${d}."
      return 1
    fi
    fname="${url##*/}"
    printf '%s\n' "$content" | util::atomic_write "${vpath}/${fname}" 0644
    written+=("${vpath}/${fname}")
    log::debug "Validation file written: ${vpath}/${fname}"
  done

  local ok=1
  if zerossl_rest::_run_validation "$cert_id" "$timeout" "$outdir"; then ok=0; fi

  rm -f ${written[@]+"${written[@]}"}
  return "$ok"
}

zerossl_rest::_run_validation() {
  local cert_id=$1 timeout=$2 outdir=$3

  # nginx already serves /var/www/acme: no temporary HTTP server is needed,
  # unlike in version 1.
  local resp
  resp=$(curl -sS --max-time 60 -X POST \
           "$(zerossl_rest::_url "/certificates/${cert_id}/challenges")" \
           -d 'validation_method=HTTP_CSR_HASH' 2>/dev/null) || {
    log::error "Could not trigger ZeroSSL validation."; return 1; }

  local status; status=$(printf '%s' "$resp" | jq -r '.status // empty')
  if [[ -z $status ]]; then
    log::error "ZeroSSL rejected the validation: $(printf '%s' "$resp" | jq -rc '.error // .' 2>/dev/null)"
    return 1
  fi

  # --- Poll instead of sleeping a fixed amount ----------------------------
  local waited=0 interval=5
  while ((waited < timeout)); do
    resp=$(curl -sS --max-time 30 "$(zerossl_rest::_url "/certificates/${cert_id}")" 2>/dev/null) || true
    status=$(printf '%s' "$resp" | jq -r '.status // "unknown"')
    case $status in
      issued) log::debug "ZeroSSL: certificate issued after ${waited}s."; break ;;
      cancelled|expired|revoked)
        log::error "ZeroSSL aborted the request (status ${status})."; return 1 ;;
      *)
        log::debug "ZeroSSL: status '${status}', checking again in ${interval}s (${waited}/${timeout}s)."
        sleep "$interval"
        waited=$((waited + interval))
        ((interval < 20)) && interval=$((interval + 5))
        ;;
    esac
  done

  if [[ $status != issued ]]; then
    log::error "ZeroSSL did not issue the certificate within the deadline (${timeout}s, last status: ${status})."
    log::error "  -> Check that http://<your-ip>/.well-known/pki-validation/... is reachable from the internet."
    return 1
  fi

  # --- Download -----------------------------------------------------------
  resp=$(curl -sS --max-time 60 \
           "$(zerossl_rest::_url "/certificates/${cert_id}/download/return")" 2>/dev/null) || {
    log::error "Could not download the ZeroSSL certificate."; return 1; }

  local leaf bundle
  leaf=$(printf '%s' "$resp"   | jq -r '.["certificate.crt"] // empty')
  bundle=$(printf '%s' "$resp" | jq -r '.["ca_bundle.crt"] // empty')
  if [[ -z $leaf || -z $bundle ]]; then
    log::error "Incomplete ZeroSSL download response."
    return 1
  fi

  printf '%s\n' "$leaf"   | util::atomic_write "${outdir}/cert.pem" 0644
  printf '%s\n' "$bundle" | util::atomic_write "${outdir}/chain.pem" 0644
  # fullchain = leaf THEN intermediates. Version 1 wrote only the leaf here,
  # which broke validation for every client without a cached intermediate.
  cat "${outdir}/cert.pem" "${outdir}/chain.pem" | util::atomic_write "${outdir}/fullchain.pem" 0644

  log::ok "ZeroSSL (REST) issued the certificate."
  return 0
}
