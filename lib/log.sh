#!/usr/bin/env bash
# lib/log.sh — Structured logging: levels, timestamps, colour, optional JSON
# output, and systematic redaction of secrets.
#
# No secret must ever reach stdout/stderr: every sensitive value is registered
# through log::secret and replaced at render time.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   EX_* and the C_* colour variables are read by the other modules; shellcheck
#   analyses one file at a time and cannot see those cross-file reads.

[[ -n ${NC_LIB_LOG_SH:-} ]] && return 0
readonly NC_LIB_LOG_SH=1

# --- Normalised exit codes -------------------------------------------------
readonly EX_OK=0            # success
readonly EX_FAIL=1          # generic failure
readonly EX_CONFIG=2        # invalid configuration
readonly EX_ISSUE=3         # no certificate authority could issue
readonly EX_NGINX=4         # invalid nginx configuration
readonly EX_BUSY=5          # lock already held by another run
readonly EX_DEPS=6          # missing dependency

NC_LOG_LEVEL="${CERT_LOG_LEVEL:-info}"
NC_LOG_FORMAT="${CERT_LOG_FORMAT:-text}"
NC_LOG_COLOR="${CERT_LOG_COLOR:-auto}"

declare -a NC_SECRETS=()

# --- Colour ----------------------------------------------------------------
log::_init_color() {
  local enable=0
  case "${NC_LOG_COLOR}" in
    always|1|true|yes) enable=1 ;;
    never|0|false|no|off) enable=0 ;;
    *) [[ -t 2 && -z ${NO_COLOR:-} ]] && enable=1 ;;
  esac
  if ((enable)); then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
  else
    C_RESET=''; C_DIM=''; C_BOLD=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
  fi
}
log::_init_color

log::_level_num() {
  case "${1,,}" in
    trace|debug)     printf '10' ;;
    info)            printf '20' ;;
    warn|warning)    printf '30' ;;
    error)           printf '40' ;;
    none|off|silent) printf '99' ;;
    *)               printf '20' ;;
  esac
}

log::set_level() { NC_LOG_LEVEL="$1"; }
log::enabled()   { (( $(log::_level_num "$1") >= $(log::_level_num "$NC_LOG_LEVEL") )); }

# --- Secret redaction ------------------------------------------------------

# Register a value to be masked in every subsequent output.
# Very short values are ignored: masking a 2-character string would redact
# fragments of ordinary words throughout the logs.
#
# The trailing "return 0" is essential. Without it the function would return
# the status of the last comparison, and a call with only empty variables
# would abort any caller running under "set -e".
log::secret() {
  local v
  for v in "$@"; do
    [[ ${#v} -ge 6 ]] && NC_SECRETS+=("$v")
  done
  return 0
}

# Replace every registered secret with a marker.
log::redact() {
  local s=$1 sec
  for sec in ${NC_SECRETS[@]+"${NC_SECRETS[@]}"}; do
    [[ -n $sec ]] && s=${s//"$sec"/'********'}
  done
  printf '%s' "$s"
}

# Partially mask a value for display: keep 3 leading and 3 trailing characters.
log::mask() {
  local v=$1
  ((${#v} == 0)) && { printf '(unset)'; return; }
  ((${#v} <= 8)) && { printf '********'; return; }
  printf '%s…%s (%d chars)' "${v:0:3}" "${v: -3}" "${#v}"
}

# --- Emission --------------------------------------------------------------
log::_json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

log::_emit() {
  local level=$1 color=$2; shift 2
  log::enabled "$level" || return 0
  local msg; msg=$(log::redact "$*")
  local ts; printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1

  if [[ $NC_LOG_FORMAT == json ]]; then
    printf '{"ts":"%s","level":"%s","component":"%s","msg":"%s"}\n' \
      "$ts" "${level,,}" "$(log::_json_escape "${NC_LOG_COMPONENT:-nginx-cert}")" \
      "$(log::_json_escape "$msg")" >&2
  else
    printf '%s%s%s %s%-5s%s %s\n' \
      "$C_DIM" "$ts" "$C_RESET" "$color" "${level^^}" "$C_RESET" "$msg" >&2
  fi
}

log::debug() { log::_emit debug "$C_DIM"    "$@"; }
log::info()  { log::_emit info  "$C_BLUE"   "$@"; }
log::warn()  { log::_emit warn  "$C_YELLOW" "$@"; }
log::error() { log::_emit error "$C_RED"    "$@"; }
log::ok()    { log::_emit info  "$C_GREEN"  "$@"; }

# Terminate with an explicit exit code.
# usage: log::die <code> <message...>
log::die() {
  local code=$1; shift
  log::error "$@"
  exit "$code"
}

# --- Presentation ----------------------------------------------------------
# Deliberately no drawn boxes: the display width of emoji and CJK characters
# equals neither their byte count nor their character count, so any computed
# border is guaranteed to be misaligned.

log::section() {
  [[ $NC_LOG_FORMAT == json ]] && return 0
  log::enabled info || return 0
  printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET" >&2
  printf '%s%s%s\n' "$C_DIM" "$(printf -- '-%.0s' $(seq 1 62))" "$C_RESET" >&2
}

log::kv() {
  [[ $NC_LOG_FORMAT == json ]] && return 0
  log::enabled info || return 0
  printf '  %s%-26s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$(log::redact "$2")" >&2
}
