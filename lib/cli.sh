#!/usr/bin/env bash
# lib/cli.sh — The options of `new`, turned into the CERT_* variables they stand
# for. lib/config.sh stays the only reader of the environment: this file only
# writes it, before config::load runs, so an option and its variable can never
# mean two different things.
#
#   docker run --rm -p 80:80 -p 443:443 -v nginx-cert-data:/data \
#     rac021/nginx-cert new --domain app.example.com --email you@example.com
#
# Secrets (EAB, ZeroSSL API key) are not options: an argument shows in `ps` and
# `docker inspect`. They stay in the environment (-e or --env-file).
# shellcheck shell=bash

[[ -n ${NC_LIB_CLI_SH:-} ]] && return 0
readonly NC_LIB_CLI_SH=1

# usage: cli::new_to_env [option...]
# Exports the CERT_* variables of a one-shot issuance; returns 1 with a message
# on an unknown option, a missing value or no --domain.
cli::new_to_env() {
  local -a domains=()
  local fallback=false opt value

  while (($#)); do
    opt=$1
    # --name=value is accepted as well as --name value.
    if [[ $opt == --*=* ]]; then
      set -- "${opt%%=*}" "${opt#*=}" "${@:2}"
      opt=$1
    fi
    case $opt in
      --staging)             export CERT_STAGING=true;     shift; continue ;;
      --force)               export CERT_FORCE_RENEW=true; shift; continue ;;
      --fallback-selfsigned) fallback=true;                shift; continue ;;
      --domain|-d|--email|--challenge|--provider|--key-type|--dns) ;;
      *)
        log::error "new: unknown option '${opt}'."
        log::detail error "See: help"
        return 1 ;;
    esac

    value=${2:-}
    if [[ -z $value || $value == --* ]]; then
      log::error "new: ${opt} needs a value."
      return 1
    fi
    case $opt in
      --domain|-d)  domains+=("$value") ;;
      --email)      export CERT_EMAIL=$value ;;
      --challenge)  export CERT_CHALLENGE=$value ;;
      --provider)   export CERT_PROVIDER=$value ;;
      --key-type)   export CERT_KEY_TYPE=$value ;;
      --dns)        export CERT_DNS_PROVIDER=$value ;;
    esac
    shift 2
  done

  if ((${#domains[@]} == 0)); then
    log::error "new: --domain is required."
    log::detail error "Example: new --domain app.example.com --email you@example.com"
    return 1
  fi

  # Every --domain goes into ONE certificate (one line of CERT_DOMAINS).
  CERT_DOMAINS=$(IFS=,; printf '%s' "${domains[*]}")
  export CERT_DOMAINS
  # A one-shot that quietly wrote a self-signed certificate would look like a
  # success: off unless asked for.
  export CERT_FALLBACK_SELFSIGNED=$fallback
}
