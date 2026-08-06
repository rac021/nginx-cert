#!/usr/bin/env bash
# providers/selfsigned.sh — Local issuance, the last link in the chain.
#
# Two roles:
#   1. local development (localhost, *.test, private addresses) where no public
#      authority can validate the name;
#   2. safety net: if every authority fails, nginx must still start with a
#      certificate, otherwise the whole service goes down over a renewal
#      problem.
#
# By default certificates are signed by a stable local authority
# (CERT_SELFSIGNED_CA): import /data/ca/rootCA.pem once into your browser or
# system trust store and every development certificate is accepted, including
# after regeneration.
# shellcheck shell=bash

[[ -n ${NC_PROVIDERS_SELFSIGNED_SH:-} ]] && return 0
readonly NC_PROVIDERS_SELFSIGNED_SH=1

# Translate CERT_KEY_TYPE into openssl genpkey arguments.
selfsigned::_genkey() {
  local key_type=$1 out=$2
  case $key_type in
    ec-256) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out" 2>/dev/null ;;
    ec-384) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$out" 2>/dev/null ;;
    ec-521) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-521 -out "$out" 2>/dev/null ;;
    *)      openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${key_type}" -out "$out" 2>/dev/null ;;
  esac
}

# Create the local authority if it does not exist yet. Idempotent.
selfsigned::ensure_ca() {
  local ca_dir="${CFG_DATA_DIR}/ca"
  NC_CA_KEY="${ca_dir}/rootCA.key"
  NC_CA_CRT="${ca_dir}/rootCA.pem"

  if [[ -s $NC_CA_KEY && -s $NC_CA_CRT ]]; then
    # An expired authority would sign immediately invalid certificates.
    if openssl x509 -in "$NC_CA_CRT" -noout -checkend 0 >/dev/null 2>&1; then
      return 0
    fi
    log::warn "The local authority has expired: regenerating it (certificates already issued must be renewed)."
  fi

  mkdir -p "$ca_dir"; chmod 700 "$ca_dir"
  log::info "Creating the local certificate authority (valid for 10 years)."

  selfsigned::_genkey ec-256 "$NC_CA_KEY" || return 1
  chmod 600 "$NC_CA_KEY"

  openssl req -x509 -new -key "$NC_CA_KEY" -sha256 -days 3650 -out "$NC_CA_CRT" \
    -subj "/O=nginx-cert/CN=nginx-cert local development CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null || return 1
  chmod 644 "$NC_CA_CRT"

  log::ok "Local authority ready: ${NC_CA_CRT}"
  log::detail info "Import this file into your browser or system trust store to trust development certificates."
}

# Common provider interface.
# usage: selfsigned::issue <name> <output_dir> <domain...>
selfsigned::issue() {
  local name=$1 outdir=$2; shift 2
  local -a domains=("$@")

  local key_type=${NC_SPEC_KEY_TYPE[$name]:-$CFG_KEY_TYPE}
  local days=${CFG_SELFSIGNED_DAYS:-365}
  local san; san=$(domain::san_string "${domains[@]}")

  mkdir -p "$outdir"
  local key="${outdir}/privkey.pem"
  local leaf="${outdir}/cert.pem"
  local chain="${outdir}/chain.pem"
  local full="${outdir}/fullchain.pem"

  log::info "Generating a local certificate for ${domains[*]} (SAN: ${san})."

  selfsigned::_genkey "$key_type" "$key" || {
    log::error "Could not generate the private key (type ${key_type})."
    return 1
  }
  chmod 600 "$key"

  local ext; ext=$(mktemp)
  cat >"$ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName   = ${san}
EOF

  if util::is_true "${CFG_SELFSIGNED_CA:-true}"; then
    selfsigned::ensure_ca || { rm -f "$ext"; return 1; }
    local csr; csr=$(mktemp)
    openssl req -new -key "$key" -out "$csr" -subj "/CN=${domains[0]}" 2>/dev/null || {
      rm -f "$ext" "$csr"; return 1; }
    openssl x509 -req -in "$csr" -CA "$NC_CA_CRT" -CAkey "$NC_CA_KEY" -CAcreateserial \
      -out "$leaf" -days "$days" -sha256 -extfile "$ext" 2>/dev/null || {
      rm -f "$ext" "$csr"
      log::error "Could not sign the certificate with the local authority."
      return 1
    }
    rm -f "$csr"
    cp "$NC_CA_CRT" "$chain"
    cat "$leaf" "$chain" >"$full"
  else
    # Same two-step as the CA branch, and for the same reason: "openssl req"
    # has no -extfile option (it belongs to "openssl x509"), so the one-shot
    # form silently failed with "Multiple digest or unknown options" and
    # CERT_SELFSIGNED_CA=false could never produce a certificate at all.
    # Without extensions the certificate would carry no SAN either, which
    # every modern client rejects.
    local csr; csr=$(mktemp)
    openssl req -new -key "$key" -out "$csr" -subj "/CN=${domains[0]}" 2>/dev/null || {
      rm -f "$ext" "$csr"
      log::error "Could not generate the certificate request."
      return 1
    }
    openssl x509 -req -in "$csr" -signkey "$key" -out "$leaf" -days "$days" \
      -sha256 -extfile "$ext" 2>/dev/null || {
      rm -f "$ext" "$csr"
      log::error "Could not generate the self-signed certificate."
      return 1
    }
    rm -f "$csr"
    # nginx needs a readable chain file even when there is no intermediate:
    # we put the certificate itself there.
    cp "$leaf" "$chain"
    cp "$leaf" "$full"
  fi

  rm -f "$ext"
  chmod 644 "$leaf" "$chain" "$full"
  log::ok "Local certificate issued for ${name} (valid ${days} days)."
  return 0
}
