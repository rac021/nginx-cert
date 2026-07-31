#!/usr/bin/env bash
# lib/domains.sh — Classification of the names to be certified.
#
# Classification drives all routing: which challenge is possible, which
# authorities are eligible, and when to fall back to a self-signed certificate
# because no public CA can validate the name.
# shellcheck shell=bash

[[ -n ${NC_LIB_DOMAINS_SH:-} ]] && return 0
readonly NC_LIB_DOMAINS_SH=1

# Top-level domains that are not publicly resolvable.
# RFC 2606, RFC 6761, RFC 8375 plus de-facto conventions.
readonly NC_RESERVED_TLDS=(
  local localdomain localhost internal intranet private corp home lan
  test example invalid onion alt home-arpa
)

domain::_valid_label() {
  local l=$1
  ((${#l} >= 1 && ${#l} <= 63)) || return 1
  [[ $l =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

# Validate a full host name (no wildcard).
domain::valid_hostname() {
  local h=${1:-}
  [[ -z $h ]] && return 1
  ((${#h} <= 253)) || return 1
  [[ $h == *.. || $h == .* || $h == *. ]] && return 1
  local label
  local IFS='.'
  for label in $h; do
    domain::_valid_label "$label" || return 1
  done
  return 0
}

domain::is_ipv4() {
  local ip=${1:-} o
  [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  for o in $ip; do
    ((10#$o <= 255)) || return 1
  done
  return 0
}

# IPv6 recognition is deliberately permissive: we rule out what cannot be an
# address rather than reimplementing the full grammar.
domain::is_ipv6() {
  local ip=${1:-}
  [[ $ip == *:* ]] || return 1
  [[ $ip =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  [[ $ip == *:::* ]] && return 1
  local colons=${ip//[^:]/}
  ((${#colons} >= 2 && ${#colons} <= 7)) || return 1
  return 0
}

domain::_ipv4_is_private() {
  local ip=$1
  local IFS='.'; read -r a b _ _ <<<"$ip"
  a=$((10#$a)); b=$((10#$b))
  ((a == 10)) && return 0                          # 10.0.0.0/8
  ((a == 172 && b >= 16 && b <= 31)) && return 0    # 172.16.0.0/12
  ((a == 192 && b == 168)) && return 0              # 192.168.0.0/16
  ((a == 169 && b == 254)) && return 0              # 169.254.0.0/16 link-local
  ((a == 100 && b >= 64 && b <= 127)) && return 0   # 100.64.0.0/10 CGNAT
  ((a == 192 && b == 0)) && return 0                # 192.0.0.0/24 + TEST-NET-1
  ((a == 198 && (b == 18 || b == 19))) && return 0  # 198.18.0.0/15 benchmarking
  ((a == 0)) && return 0                            # 0.0.0.0/8
  ((a >= 224)) && return 0                          # multicast and reserved
  return 1
}

domain::_ipv6_is_private() {
  local ip; ip=$(util::lower "$1")
  [[ $ip == fc* || $ip == fd* ]] && return 0        # fc00::/7 unique-local
  [[ $ip == fe8* || $ip == fe9* || $ip == fea* || $ip == feb* ]] && return 0  # fe80::/10
  return 1
}

# Classify a name.
# Output: wildcard | fqdn | ip4 | ip6 | localhost | internal | invalid
domain::kind() {
  local d; d=$(util::lower "$(util::trim "${1:-}")")
  [[ -z $d ]] && { printf 'invalid'; return; }

  # Wildcards: only a single leftmost label wildcard is valid (RFC 8555 §7.1.3).
  if [[ $d == \*.* ]]; then
    local base=${d#\*.}
    [[ $base == *\** ]] && { printf 'invalid'; return; }
    if domain::valid_hostname "$base" && [[ $base == *.* ]]; then
      case "$(domain::kind "$base")" in
        fqdn) printf 'wildcard' ;;
        *)    printf 'internal' ;;
      esac
    else
      printf 'invalid'
    fi
    return
  fi
  [[ $d == *\** ]] && { printf 'invalid'; return; }

  if domain::is_ipv4 "$d"; then
    [[ $d == 127.* ]] && { printf 'localhost'; return; }
    domain::_ipv4_is_private "$d" && { printf 'internal'; return; }
    printf 'ip4'; return
  fi

  if domain::is_ipv6 "$d"; then
    [[ $d == '::1' ]] && { printf 'localhost'; return; }
    domain::_ipv6_is_private "$d" && { printf 'internal'; return; }
    printf 'ip6'; return
  fi

  domain::valid_hostname "$d" || { printf 'invalid'; return; }

  [[ $d == localhost || $d == *.localhost ]] && { printf 'localhost'; return; }

  # A single label with no dot can never be certified publicly.
  [[ $d != *.* ]] && { printf 'internal'; return; }

  local tld=${d##*.} reserved
  for reserved in "${NC_RESERVED_TLDS[@]}"; do
    [[ $tld == "$reserved" ]] && { printf 'internal'; return; }
  done

  printf 'fqdn'
}

# Can a public certificate authority validate this kind of name?
domain::is_acme_capable() {
  case "${1:-}" in
    fqdn|wildcard|ip4|ip6) return 0 ;;
    *) return 1 ;;
  esac
}

# Does this kind of name force a DNS-01 challenge?
domain::requires_dns01() { [[ ${1:-} == wildcard ]]; }

# Aggregate kind of a multi-SAN certificate: the strongest constraint wins.
# invalid > internal|localhost > wildcard > ip > fqdn
domain::aggregate_kind() {
  local has_wildcard=0 has_ip=0 has_fqdn=0 has_local=0 k d
  for d in "$@"; do
    k=$(domain::kind "$d")
    case $k in
      invalid)  printf 'invalid'; return ;;
      wildcard) has_wildcard=1 ;;
      ip4|ip6)  has_ip=1 ;;
      fqdn)     has_fqdn=1 ;;
      localhost|internal) has_local=1 ;;
    esac
  done
  ((has_local)) && { printf 'internal'; return; }
  ((has_wildcard)) && { printf 'wildcard'; return; }
  # No CA issues a certificate mixing IP addresses and domain names.
  ((has_ip && has_fqdn)) && { printf 'invalid'; return; }
  ((has_ip)) && { printf 'ip'; return; }
  printf 'fqdn'
}

# Build the subjectAltName value of a self-signed certificate.
domain::san_string() {
  local out='' d
  for d in "$@"; do
    # Test the shape, not the classification: a private IP is classified as
    # "internal" but is still an IP address in a SAN. Emitting
    # "DNS:192.168.1.50" produces a certificate no client will accept.
    if domain::is_ipv4 "$d" || domain::is_ipv6 "$d"; then
      out+="${out:+,}IP:${d}"
    else
      out+="${out:+,}DNS:${d}"
    fi
    # A certificate for "localhost" must also cover the loopback addresses,
    # otherwise clients that resolve it to 127.0.0.1 reject the certificate.
    if [[ $d == localhost ]]; then
      out+=",IP:127.0.0.1,IP:::1"
    fi
  done
  printf '%s' "$out"
}
