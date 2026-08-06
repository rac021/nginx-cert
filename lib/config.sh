#!/usr/bin/env bash
# lib/config.sh — Loading, validation and presentation of the configuration.
#
# All configuration flows through CERT_* environment variables. They are read
# exactly once here, validated immediately, and exposed to the rest of the
# program in normalised form. No other file reads the environment directly:
# that is what makes the configuration testable and the startup summary a
# faithful description of what will actually run.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   The CFG_* variables are this module's public surface: they are set here and
#   read by every other module. shellcheck analyses one file at a time and
#   cannot see those cross-file reads.

[[ -n ${NC_LIB_CONFIG_SH:-} ]] && return 0
readonly NC_LIB_CONFIG_SH=1

# --- Certificate specifications --------------------------------------------
# One entry per certificate, keyed by its lineage name.
declare -a NC_SPEC_NAMES=()
declare -A NC_SPEC_DOMAINS=()    # "d1 d2 d3"
declare -A NC_SPEC_KIND=()       # fqdn | wildcard | ip | internal | invalid
declare -A NC_SPEC_PROVIDER=()
declare -A NC_SPEC_UPSTREAM=()
declare -A NC_SPEC_CHALLENGE=()
declare -A NC_SPEC_DNS=()
declare -A NC_SPEC_KEY_TYPE=()
declare -A NC_SPEC_PROFILE=()
declare -A NC_SPEC_STAGING=()
declare -A NC_SPEC_HSTS=()
declare -A NC_SPEC_REDIRECT=()

readonly NC_SPEC_KEYS=(name provider upstream challenge dns key_type profile staging hsts redirect)

# Every CERT_* variable the program understands. Kept explicit rather than
# derived, so an unknown variable can be reported instead of silently ignored:
# a typo or a leftover setting from version 1 must not change behaviour without
# saying so. tests/unit/config.test.sh fails if this list drifts from the code.
readonly NC_KNOWN_CERT_VARS=(
  CERT_ENABLE CERT_DOMAINS CERT_EMAIL CERT_UPSTREAM
  CERT_PROVIDER CERT_PROVIDER_CHAIN CERT_ATTEMPTS CERT_RETRY_DELAY
  CERT_FALLBACK_SELFSIGNED CERT_STAGING CERT_ACME_SERVER CERT_ACME_ARGS
  CERT_ACME_TIMEOUT
  CERT_EAB_KID CERT_EAB_HMAC_KEY CERT_ZEROSSL_API_KEY
  CERT_KEY_TYPE CERT_CHALLENGE CERT_DNS_PROVIDER CERT_DNS_SLEEP CERT_PROFILE
  CERT_RENEW_DAYS CERT_RENEW_INTERVAL CERT_RENEW_JITTER CERT_FORCE_RENEW
  CERT_FAILURE_COOLDOWN CERT_FAILURE_COOLDOWN_MAX CERT_POST_HOOK
  CERT_ZEROSSL_VALIDITY_DAYS CERT_ZEROSSL_TIMEOUT
  CERT_SELFSIGNED_CA CERT_SELFSIGNED_DAYS
  CERT_MANAGE_NGINX CERT_MANAGE_VHOSTS CERT_HTTP_REDIRECT CERT_HSTS
  CERT_SSL_POLICY CERT_HTTP2 CERT_HTTP3 CERT_HTTP_PORT CERT_HTTPS_PORT
  CERT_CLIENT_MAX_BODY_SIZE CERT_PROXY_TIMEOUT CERT_PROXY_CONNECT_TIMEOUT
  CERT_WORKER_CONNECTIONS CERT_RESOLVER CERT_ACCESS_LOG CERT_REAL_IP_FROM
  CERT_DATA_DIR CERT_WEBROOT
  CERT_LOG_LEVEL CERT_LOG_FORMAT CERT_LOG_COLOR
)

# Variables that existed in version 1 and no longer do. Pasting an old
# "docker run" command is the most likely way to meet them, so each one gets a
# precise migration hint rather than a generic warning.
declare -A NC_REMOVED_CERT_VARS=(
  [CERT_PROXY_PASS_PORT]='removed: the ACME challenge is now served from a webroot, there is no internal proxy port to configure.'
  [CERT_CRON_SCHEDULE]='removed: use CERT_RENEW_INTERVAL with a duration instead, e.g. CERT_RENEW_INTERVAL=12h.'
  [CERT_RENEWAL_THRESHOLD_DAYS]='renamed: use CERT_RENEW_DAYS.'
  [CERT_SELF_SIGNED_CERTIFICATE]='removed: use CERT_PROVIDER=selfsigned.'
)

config::_default() {
  local var=$1 fallback=$2
  local current=${!var:-}
  printf '%s' "${current:-$fallback}"
}

config::load() {
  # --- General -----------------------------------------------------------
  CFG_ENABLE=$(config::_default CERT_ENABLE true)
  CFG_EMAIL=$(util::trim "${CERT_EMAIL:-}")
  CFG_DATA_DIR=$(config::_default CERT_DATA_DIR /data)
  CFG_WEBROOT=$(config::_default CERT_WEBROOT /var/www/acme)

  # --- Authority selection -----------------------------------------------
  CFG_PROVIDER=$(util::lower "$(config::_default CERT_PROVIDER auto)")
  CFG_PROVIDER_CHAIN=$(config::_default CERT_PROVIDER_CHAIN 'letsencrypt,zerossl,actalis,google')
  CFG_ATTEMPTS=$(config::_default CERT_ATTEMPTS 2)
  CFG_RETRY_DELAY=$(config::_default CERT_RETRY_DELAY 15)
  CFG_FALLBACK_SELFSIGNED=$(config::_default CERT_FALLBACK_SELFSIGNED true)
  CFG_STAGING=$(config::_default CERT_STAGING false)
  CFG_ACME_SERVER=$(util::trim "${CERT_ACME_SERVER:-}")
  CFG_ACME_ARGS=${CERT_ACME_ARGS:-}

  # --- Credentials --------------------------------------------------------
  CFG_EAB_KID=$(util::trim "${CERT_EAB_KID:-}")
  CFG_EAB_HMAC_KEY=$(util::trim "${CERT_EAB_HMAC_KEY:-}")
  CFG_ZEROSSL_API_KEY=$(util::trim "${CERT_ZEROSSL_API_KEY:-}")
  log::secret "$CFG_EAB_HMAC_KEY" "$CFG_ZEROSSL_API_KEY" "$CFG_EAB_KID"

  # --- Issuance -----------------------------------------------------------
  CFG_KEY_TYPE=$(util::lower "$(config::_default CERT_KEY_TYPE ec-256)")
  CFG_PROFILE=$(util::trim "${CERT_PROFILE:-}")
  CFG_CHALLENGE=$(util::lower "$(config::_default CERT_CHALLENGE auto)")
  CFG_DNS_PROVIDER=$(util::trim "${CERT_DNS_PROVIDER:-}")
  CFG_DNS_SLEEP=$(config::_default CERT_DNS_SLEEP 20)
  CFG_RENEW_DAYS=$(config::_default CERT_RENEW_DAYS 30)
  CFG_FORCE_RENEW=$(config::_default CERT_FORCE_RENEW false)
  CFG_RENEW_INTERVAL=$(config::_default CERT_RENEW_INTERVAL 12h)
  CFG_RENEW_JITTER=$(config::_default CERT_RENEW_JITTER 30m)
  CFG_POST_HOOK=${CERT_POST_HOOK:-}

  # --- Self-signed --------------------------------------------------------
  CFG_SELFSIGNED_CA=$(config::_default CERT_SELFSIGNED_CA true)
  CFG_SELFSIGNED_DAYS=$(config::_default CERT_SELFSIGNED_DAYS 365)

  # --- nginx --------------------------------------------------------------
  CFG_MANAGE_NGINX=$(config::_default CERT_MANAGE_NGINX true)
  CFG_MANAGE_VHOSTS=$(config::_default CERT_MANAGE_VHOSTS true)
  CFG_UPSTREAM=$(util::trim "${CERT_UPSTREAM:-}")
  CFG_HTTP_REDIRECT=$(config::_default CERT_HTTP_REDIRECT true)
  CFG_HSTS=$(config::_default CERT_HSTS 'max-age=31536000')
  CFG_SSL_POLICY=$(util::lower "$(config::_default CERT_SSL_POLICY intermediate)")
  CFG_HTTP2=$(config::_default CERT_HTTP2 true)
  CFG_HTTP3=$(config::_default CERT_HTTP3 false)
  CFG_HTTP_PORT=$(config::_default CERT_HTTP_PORT 80)
  CFG_HTTPS_PORT=$(config::_default CERT_HTTPS_PORT 443)
  CFG_PROXY_TIMEOUT=$(config::_default CERT_PROXY_TIMEOUT 60s)
  CFG_PROXY_CONNECT_TIMEOUT=$(config::_default CERT_PROXY_CONNECT_TIMEOUT 10s)
  CFG_CLIENT_MAX_BODY_SIZE=$(config::_default CERT_CLIENT_MAX_BODY_SIZE 16m)
  CFG_WORKER_CONNECTIONS=$(config::_default CERT_WORKER_CONNECTIONS 2048)
  CFG_RESOLVER=$(config::_default CERT_RESOLVER '127.0.0.11 1.1.1.1 8.8.8.8')
  CFG_ACCESS_LOG=$(config::_default CERT_ACCESS_LOG true)
  CFG_REAL_IP_FROM=$(util::trim "${CERT_REAL_IP_FROM:-}")

  # --- Derived paths ------------------------------------------------------
  CFG_CERT_DIR="${CFG_DATA_DIR}/certs"
  CFG_ACME_HOME="${CFG_DATA_DIR}/acme"
  CFG_STATE_DIR="${CFG_DATA_DIR}/state"
  CFG_BACKUP_DIR="${CFG_DATA_DIR}/backups"
  CFG_LOCK_FILE="${CFG_DATA_DIR}/state/nginx-cert.lock"

  config::warn_unknown_vars
  config::_parse_domains
  config::validate
}

# Report every CERT_* variable present in the environment that the program does
# not understand. Silently ignoring one means a setting the operator believes is
# active has no effect -- the failure mode is a configuration that looks right
# and behaves differently.
config::warn_unknown_vars() {
  local var name known k
  local -a unknown=()

  while IFS= read -r name; do
    if [[ -n ${NC_REMOVED_CERT_VARS[$name]:-} ]]; then
      log::warn "${name} is no longer supported and is being ignored."
      log::detail warn "${NC_REMOVED_CERT_VARS[$name]}"
      continue
    fi
    known=0
    for k in "${NC_KNOWN_CERT_VARS[@]}"; do [[ $name == "$k" ]] && { known=1; break; }; done
    ((known)) || unknown+=("$name")
  done < <(compgen -v | grep -E '^CERT_[A-Z0-9_]+$' | sort)

  if ((${#unknown[@]})); then
    log::warn "Unknown variable(s), ignored: ${unknown[*]}"
    log::detail warn "Check the spelling; 'certme config' lists what is actually in effect."
  fi
  return 0
}

# --- CERT_DOMAINS parsing --------------------------------------------------
#
# One line (or one segment separated by ";") describes one certificate:
#
#   example.com, www.example.com | upstream=app:8080 provider=letsencrypt
#   *.example.org                | dns=dns_cf
#   192.0.2.10
#
config::_parse_domains() {
  NC_SPEC_NAMES=()
  local raw=${CERT_DOMAINS:-}
  [[ -z $(util::trim "$raw") ]] && return 0

  raw=${raw//;/$'\n'}

  local line
  while IFS= read -r line; do
    line=$(util::trim "$line")
    [[ -z $line || $line == '#'* ]] && continue
    config::_parse_one_spec "$line"
  done <<<"$raw"
}

config::_parse_one_spec() {
  local spec=$1
  local domains_part=${spec%%|*}
  local opts_part=''
  [[ $spec == *'|'* ]] && opts_part=${spec#*|}

  local -a domains=()
  util::split_into domains ',' "$domains_part"
  ((${#domains[@]} == 0)) && return 0

  # Normalisation: lowercase, trailing dot removed.
  local i
  for i in "${!domains[@]}"; do
    domains[i]=$(util::lower "${domains[i]%.}")
  done

  local -A opt=()
  local -a tokens=()
  read -r -a tokens <<<"$opts_part"
  local tok key val known k
  for tok in ${tokens[@]+"${tokens[@]}"}; do
    [[ $tok == *=* ]] || log::die "$EX_CONFIG" \
      "CERT_DOMAINS: malformed option '${tok}' in '${spec}' (expected key=value)."
    key=$(util::lower "${tok%%=*}"); val=${tok#*=}
    known=0
    for k in "${NC_SPEC_KEYS[@]}"; do [[ $key == "$k" ]] && known=1; done
    ((known)) || log::die "$EX_CONFIG" \
      "CERT_DOMAINS: unknown option '${key}'. Accepted options: ${NC_SPEC_KEYS[*]}"
    opt[$key]=$val
  done

  # The name becomes a path component under /data/certs and a file name in
  # conf.d, so it goes through the same sanitiser whether we derived it or the
  # user supplied it. Taking name= verbatim let "name=../../evil" write outside
  # the certificate directory.
  local name=${opt[name]:-}
  [[ -z $name ]] && name=${domains[0]}
  name=$(util::sanitize_name "$name")
  [[ -z $name ]] && log::die "$EX_CONFIG" \
    "CERT_DOMAINS: the name for '${spec}' is empty once sanitised. Use name= with at least one letter or digit."

  if [[ -n ${NC_SPEC_DOMAINS[$name]:-} ]]; then
    log::die "$EX_CONFIG" \
      "CERT_DOMAINS: two certificates share the same name '${name}'. Use the name= option to tell them apart."
  fi

  NC_SPEC_NAMES+=("$name")
  NC_SPEC_DOMAINS[$name]="${domains[*]}"
  NC_SPEC_KIND[$name]=$(domain::aggregate_kind "${domains[@]}")
  NC_SPEC_PROVIDER[$name]=$(util::lower "${opt[provider]:-$CFG_PROVIDER}")
  NC_SPEC_UPSTREAM[$name]=${opt[upstream]:-$CFG_UPSTREAM}
  NC_SPEC_CHALLENGE[$name]=$(util::lower "${opt[challenge]:-$CFG_CHALLENGE}")
  NC_SPEC_DNS[$name]=${opt[dns]:-$CFG_DNS_PROVIDER}
  NC_SPEC_KEY_TYPE[$name]=$(util::lower "${opt[key_type]:-$CFG_KEY_TYPE}")
  NC_SPEC_PROFILE[$name]=${opt[profile]:-$CFG_PROFILE}
  NC_SPEC_STAGING[$name]=${opt[staging]:-$CFG_STAGING}
  NC_SPEC_HSTS[$name]=${opt[hsts]:-$CFG_HSTS}
  NC_SPEC_REDIRECT[$name]=${opt[redirect]:-$CFG_HTTP_REDIRECT}
}

# --- Validation ------------------------------------------------------------
config::validate() {
  local v
  for v in CERT_ENABLE CERT_FORCE_RENEW CERT_STAGING CERT_MANAGE_NGINX \
           CERT_MANAGE_VHOSTS CERT_HTTP_REDIRECT CERT_HTTP2 CERT_HTTP3 \
           CERT_ACCESS_LOG CERT_FALLBACK_SELFSIGNED CERT_SELFSIGNED_CA; do
    [[ -n ${!v:-} ]] && util::assert_bool "$v" "${!v}"
  done

  [[ $CFG_ATTEMPTS =~ ^[1-9][0-9]*$ ]] || log::die "$EX_CONFIG" \
    "CERT_ATTEMPTS='${CFG_ATTEMPTS}' must be a strictly positive integer."
  [[ $CFG_RENEW_DAYS =~ ^[0-9]+$ ]] || log::die "$EX_CONFIG" \
    "CERT_RENEW_DAYS='${CFG_RENEW_DAYS}' must be an integer."

  # Every duration goes through the same parser, so "5s" and "45m" mean the
  # same thing everywhere. These two used to be read as bare integers: a unit
  # suffix on CERT_RETRY_DELAY reached "$((delay * 2))" and killed the retry
  # loop with a raw bash arithmetic error, so the remaining authorities in the
  # chain were never tried.
  CFG_RETRY_DELAY_S=$(util::parse_duration "$CFG_RETRY_DELAY") || log::die "$EX_CONFIG" \
    "CERT_RETRY_DELAY='${CFG_RETRY_DELAY}' is invalid (examples: 15, 30s, 2m)."
  CFG_DNS_SLEEP_S=$(util::parse_duration "$CFG_DNS_SLEEP") || log::die "$EX_CONFIG" \
    "CERT_DNS_SLEEP='${CFG_DNS_SLEEP}' is invalid (examples: 20, 45s, 2m)."

  CFG_RENEW_INTERVAL_S=$(util::parse_duration "$CFG_RENEW_INTERVAL") || log::die "$EX_CONFIG" \
    "CERT_RENEW_INTERVAL='${CFG_RENEW_INTERVAL}' is invalid (examples: 12h, 45m, 3600)."
  CFG_RENEW_JITTER_S=$(util::parse_duration "$CFG_RENEW_JITTER") || log::die "$EX_CONFIG" \
    "CERT_RENEW_JITTER='${CFG_RENEW_JITTER}' is invalid (examples: 30m, 0)."
  ((CFG_RENEW_INTERVAL_S >= 60)) || log::die "$EX_CONFIG" \
    "CERT_RENEW_INTERVAL must be at least 60s (got: ${CFG_RENEW_INTERVAL})."

  local p
  for p in CFG_HTTP_PORT CFG_HTTPS_PORT; do
    [[ ${!p} =~ ^[0-9]+$ ]] && ((${!p} >= 1 && ${!p} <= 65535)) || log::die "$EX_CONFIG" \
      "${p/CFG_/CERT_}='${!p}' is not a valid port."
  done

  case $CFG_SSL_POLICY in
    intermediate|modern) ;;
    *) log::die "$EX_CONFIG" "CERT_SSL_POLICY='${CFG_SSL_POLICY}': expected intermediate or modern." ;;
  esac

  case $CFG_CHALLENGE in
    auto|http-01|http|dns-01|dns) ;;
    *) log::die "$EX_CONFIG" "CERT_CHALLENGE='${CFG_CHALLENGE}': expected auto, http-01 or dns-01." ;;
  esac

  case $CFG_KEY_TYPE in
    ec-256|ec-384|ec-521|2048|3072|4096) ;;
    *) log::die "$EX_CONFIG" \
         "CERT_KEY_TYPE='${CFG_KEY_TYPE}': expected ec-256, ec-384, ec-521, 2048, 3072 or 4096." ;;
  esac

  if [[ $CFG_PROVIDER != auto ]]; then
    provider::exists "$CFG_PROVIDER" || log::die "$EX_CONFIG" \
      "CERT_PROVIDER='${CFG_PROVIDER}' is unknown. Available: $(provider::list_ids | tr '\n' ' ')selfsigned"
  fi

  # Per-certificate consistency.
  #
  # Every per-line option is checked exactly like its global counterpart. They
  # used not to be, so "provider=lestencrypt" fell through to the whole auto
  # chain and "staging=ture" issued against production -- both silently, while
  # the same typo in CERT_PROVIDER or CERT_STAGING stopped the container with a
  # precise message.
  local name kind
  for name in ${NC_SPEC_NAMES[@]+"${NC_SPEC_NAMES[@]}"}; do
    kind=${NC_SPEC_KIND[$name]}
    local -a doms=(); read -r -a doms <<<"${NC_SPEC_DOMAINS[$name]}"

    util::assert_bool "CERT_DOMAINS staging= ('${name}')" "${NC_SPEC_STAGING[$name]}"
    util::assert_bool "CERT_DOMAINS redirect= ('${name}')" "${NC_SPEC_REDIRECT[$name]}"

    if [[ ${NC_SPEC_PROVIDER[$name]} != auto && ${NC_SPEC_PROVIDER[$name]} != selfsigned ]]; then
      provider::exists "${NC_SPEC_PROVIDER[$name]}" || log::die "$EX_CONFIG" \
        "CERT_DOMAINS: provider='${NC_SPEC_PROVIDER[$name]}' ('${name}') is unknown. Available: $(provider::list_ids | tr '\n' ' ')selfsigned"
    fi

    case ${NC_SPEC_CHALLENGE[$name]} in
      auto|http-01|http|dns-01|dns) ;;
      *) log::die "$EX_CONFIG" \
           "CERT_DOMAINS: challenge='${NC_SPEC_CHALLENGE[$name]}' ('${name}'): expected auto, http-01 or dns-01." ;;
    esac

    case ${NC_SPEC_KEY_TYPE[$name]} in
      ec-256|ec-384|ec-521|2048|3072|4096) ;;
      *) log::die "$EX_CONFIG" \
           "CERT_DOMAINS: key_type='${NC_SPEC_KEY_TYPE[$name]}' ('${name}'): expected ec-256, ec-384, ec-521, 2048, 3072 or 4096." ;;
    esac

    if [[ $kind == invalid ]]; then
      local d bad=()
      for d in "${doms[@]}"; do
        [[ $(domain::kind "$d") == invalid ]] && bad+=("$d")
      done
      if ((${#bad[@]})); then
        log::die "$EX_CONFIG" "CERT_DOMAINS: invalid name(s) for '${name}': ${bad[*]}"
      fi
      log::die "$EX_CONFIG" \
        "CERT_DOMAINS: '${name}' mixes IP addresses and domain names in a single certificate, which no authority issues. Declare them on two separate lines."
    fi

    if [[ $kind == wildcard ]]; then
      local ch=${NC_SPEC_CHALLENGE[$name]}
      [[ $ch == http-01 || $ch == http ]] && log::die "$EX_CONFIG" \
        "'${name}' is a wildcard certificate: the HTTP-01 challenge is impossible, use challenge=dns-01."
      if [[ -z ${NC_SPEC_DNS[$name]} ]]; then
        log::warn "'${name}' is a wildcard but no DNS provider is configured (CERT_DNS_PROVIDER or dns=...): it will fall back to a self-signed certificate."
      fi
    fi

    if domain::is_acme_capable "$kind" && [[ ${NC_SPEC_PROVIDER[$name]} != selfsigned ]]; then
      [[ -z $CFG_EMAIL ]] && log::die "$EX_CONFIG" \
        "CERT_EMAIL is required to request a certificate from a public authority ('${name}')."
    fi
  done

  # EAB credentials check when the authority is pinned.
  if [[ $CFG_PROVIDER != auto && $CFG_PROVIDER != selfsigned ]]; then
    if provider::needs_eab "$CFG_PROVIDER" && ! provider::eab_available "$CFG_PROVIDER"; then
      log::die "$EX_CONFIG" \
        "Provider '${CFG_PROVIDER}' requires External Account Binding. Set CERT_EAB_KID and CERT_EAB_HMAC_KEY$( [[ $CFG_PROVIDER == zerossl ]] && printf ', or simply CERT_ZEROSSL_API_KEY')."
    fi
  fi

  if util::is_true "$CFG_ENABLE" && ((${#NC_SPEC_NAMES[@]} == 0)); then
    log::warn "CERT_ENABLE is on but CERT_DOMAINS is empty: no certificate will be managed, nginx starts on its own."
  fi
}

# --- Presentation ----------------------------------------------------------
config::summary() {
  log::section "Effective configuration"
  if util::is_true "$CFG_ENABLE"; then
    log::kv_hl "Certificate management" 'enabled'  "$C_GREEN"
  else
    log::kv_hl "Certificate management" 'disabled' "$C_ORANGE"
  fi
  log::kv_hl "Provider" "$CFG_PROVIDER$( [[ $CFG_PROVIDER == auto ]] && printf ' -> %s -> selfsigned' "$CFG_PROVIDER_CHAIN")"
  log::kv "Attempts per authority" "$CFG_ATTEMPTS (initial delay $(util::human_duration "$CFG_RETRY_DELAY_S"), doubled each retry)"
  log::kv "Self-signed fallback"   "$CFG_FALLBACK_SELFSIGNED"
  # Staging is the single setting most likely to be forgotten: it yields
  # certificates no browser trusts, and everything else looks like success.
  if util::is_true "$CFG_STAGING"; then
    log::kv_hl "Staging environment" 'true -- certificates will NOT be publicly trusted' "$C_ORANGE"
  else
    log::kv "Staging environment" 'false'
  fi
  log::kv "Account e-mail"         "${CFG_EMAIL:-(unset)}"
  log::kv "Key type"               "$CFG_KEY_TYPE"
  log::kv "Renewal"                "at D-${CFG_RENEW_DAYS} before expiry, checked every $(util::human_duration "$CFG_RENEW_INTERVAL_S") (+/-$(util::human_duration "$CFG_RENEW_JITTER_S"))"
  log::kv "TLS policy"             "$CFG_SSL_POLICY"
  log::kv "Data directory"         "$CFG_DATA_DIR"

  if [[ -n $CFG_EAB_KID ]];         then log::kv "EAB KID"         "$(log::mask "$CFG_EAB_KID")"; fi
  if [[ -n $CFG_EAB_HMAC_KEY ]];    then log::kv "EAB HMAC"        "$(log::mask "$CFG_EAB_HMAC_KEY")"; fi
  if [[ -n $CFG_ZEROSSL_API_KEY ]]; then log::kv "ZeroSSL API key" "$(log::mask "$CFG_ZEROSSL_API_KEY")"; fi
  if [[ -n $CFG_DNS_PROVIDER ]];    then log::kv "DNS provider"    "$CFG_DNS_PROVIDER"; fi

  ((${#NC_SPEC_NAMES[@]} == 0)) && return 0

  log::section "Declared certificates (${#NC_SPEC_NAMES[@]})"
  local name
  for name in "${NC_SPEC_NAMES[@]}"; do
    log::kv "$name" "$(config::describe_spec "$name")"
  done
}

config::describe_spec() {
  local name=$1
  local desc="${NC_SPEC_DOMAINS[$name]}"
  desc+="  [${NC_SPEC_KIND[$name]}]"
  [[ ${NC_SPEC_PROVIDER[$name]} != "$CFG_PROVIDER" ]] && desc+=" provider=${NC_SPEC_PROVIDER[$name]}"
  [[ -n ${NC_SPEC_UPSTREAM[$name]} ]] && desc+=" -> ${NC_SPEC_UPSTREAM[$name]}"
  printf '%s' "$desc"
}

# Paths to a certificate's artefacts.
config::cert_path()      { printf '%s/%s' "$CFG_CERT_DIR" "$1"; }
config::fullchain_path() { printf '%s/%s/fullchain.pem' "$CFG_CERT_DIR" "$1"; }
config::privkey_path()   { printf '%s/%s/privkey.pem' "$CFG_CERT_DIR" "$1"; }
config::chain_path()     { printf '%s/%s/chain.pem' "$CFG_CERT_DIR" "$1"; }
config::leaf_path()      { printf '%s/%s/cert.pem' "$CFG_CERT_DIR" "$1"; }
