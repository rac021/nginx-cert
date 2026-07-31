#!/usr/bin/env bash
# lib/log.sh — Structured logging: levels, timestamps, colour, optional JSON
# output, and systematic redaction of secrets.
#
# No secret must ever reach stdout/stderr: every sensitive value is registered
# through log::secret and replaced at render time.
#
# Two rules govern the presentation:
#
#   1. Colour is never the only carrier of meaning. Every severity also has a
#      distinct ASCII badge, so the output stays readable in a log file, in a
#      pipeline, and for anyone who cannot distinguish red from green.
#   2. Nothing computes a width from a string that may contain non-ASCII.
#      The display width of emoji and CJK equals neither their byte count nor
#      their character count, so any such alignment is wrong by construction.
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

readonly NC_RULE_WIDTH=74

declare -a NC_SECRETS=()

# --- Colour ----------------------------------------------------------------
#
# "auto" colours a terminal and a pipe, but never a regular file.
#
# A container writes its logs to a pipe held by the Docker logging driver, not
# to a terminal. Testing for a terminal alone would therefore drop colour in
# the one place it is read most -- "docker logs" -- while a redirection to a
# file, where escape codes are genuinely unwanted, is a regular file and is
# excluded. JSON output is never coloured: it is meant for machines.
#
# Set CERT_LOG_COLOR=never when shipping logs to an aggregator that does not
# strip escape sequences.
log::_init_color() {
  local enable=0
  case "${NC_LOG_COLOR}" in
    always|1|true|yes) enable=1 ;;
    never|0|false|no|off) enable=0 ;;
    *)
      if [[ -z ${NO_COLOR:-} && $NC_LOG_FORMAT != json ]] && [[ -t 2 || -p /dev/stderr ]]; then
        enable=1
      fi
      ;;
  esac

  if ((enable)); then
    C_RESET=$'\033[0m';  C_DIM=$'\033[2m';    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_CYAN=$'\033[36m';  C_GREY=$'\033[90m'
    # Warnings deserve their own hue rather than sharing yellow with anything
    # else. 256-colour orange where available, plain yellow otherwise.
    case "${TERM:-}" in
      *256color*|xterm*|screen*|tmux*|alacritty|foot*) C_ORANGE=$'\033[38;5;214m' ;;
      *) C_ORANGE=$'\033[33m' ;;
    esac
  else
    C_RESET=''; C_DIM=''; C_BOLD=''; C_GREY=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_ORANGE=''
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

# Severity is carried by three redundant signals: a badge, a colour, and --
# for warnings and errors -- the colour of the message itself. Any one of them
# alone is enough to spot a problem while scrolling.
#
# usage: log::_emit <level> <badge> <badge colour> <message colour> <text...>
log::_emit() {
  local level=$1 badge=$2 badge_color=$3 text_color=$4; shift 4
  log::enabled "$level" || return 0

  local msg; msg=$(log::redact "$*")

  if [[ $NC_LOG_FORMAT == json ]]; then
    local ts; printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    printf '{"ts":"%s","level":"%s","component":"%s","msg":"%s"}\n' \
      "$ts" "${level,,}" "$(log::_json_escape "${NC_LOG_COMPONENT:-nginx-cert}")" \
      "$(log::_json_escape "$msg")" >&2
    return 0
  fi

  # Time only: the date belongs in the container's log metadata, and a full
  # ISO stamp on every line pushes the message off a narrow terminal.
  local ts; printf -v ts '%(%H:%M:%S)T' -1
  printf '%s%s%s %s%s%s %s%s%s\n' \
    "$C_GREY" "$ts" "$C_RESET" \
    "$badge_color" "$badge" "$C_RESET" \
    "$text_color" "$msg" "$C_RESET" >&2
}

log::debug() { log::_emit debug '[dbg ]' "$C_GREY"   "$C_GREY"   "$@"; }
log::info()  { log::_emit info  '[info]' "$C_BLUE"   ''          "$@"; }
log::ok()    { log::_emit info  '[ ok ]' "$C_GREEN"  "$C_GREEN"  "$@"; }
log::warn()  { log::_emit warn  '[warn]' "$C_ORANGE" "$C_ORANGE" "$@"; }
log::error() { log::_emit error '[FAIL]' "$C_RED"    "$C_RED"    "$@"; }

# A subordinate line: explanation, remedy, or a quoted excerpt. Indented under
# its parent and never louder than it, so a wall of provider output cannot be
# mistaken for a wall of failures.
#
# usage: log::detail <level> <text...>
log::detail() {
  local level=$1; shift
  log::enabled "$level" || return 0
  local msg; msg=$(log::redact "$*")

  if [[ $NC_LOG_FORMAT == json ]]; then
    log::_emit "$level" '' '' '' "$msg"
    return 0
  fi

  local color=$C_GREY
  [[ $level == warn || $level == error ]] && color=$C_DIM
  # Multi-line remedies stay aligned with the first line.
  local line first=1
  while IFS= read -r line; do
    if ((first)); then
      printf '%s         %s %s%s\n' "$color" '->' "$line" "$C_RESET" >&2
      first=0
    else
      printf '%s            %s%s\n' "$color" "$line" "$C_RESET" >&2
    fi
  done <<<"$msg"
}

# A quoted excerpt of another program's output: visibly not ours.
log::quote() {
  local level=$1; shift
  log::enabled "$level" || return 0
  [[ $NC_LOG_FORMAT == json ]] && return 0
  local line
  while IFS= read -r line; do
    printf '%s         | %s%s\n' "$C_GREY" "$(log::redact "$line")" "$C_RESET" >&2
  done <<<"$*"
}

# Terminate with an explicit exit code.
# usage: log::die <code> <message...>
log::die() {
  local code=$1; shift
  log::error "$@"
  exit "$code"
}

# --- Presentation ----------------------------------------------------------

log::_rule() {
  local n=${1:-$NC_RULE_WIDTH} ch=${2:-─}
  local out='' i
  for ((i = 0; i < n; i++)); do out+=$ch; done
  printf '%s' "$out"
}

# A section heading: a coloured title followed by a rule that fills the line.
#
# The rule length is derived from the character count, which is exact here
# because every title this program emits is ASCII plus, at most, a domain name
# -- and domain names on the wire are ASCII.
log::section() {
  [[ $NC_LOG_FORMAT == json ]] && return 0
  log::enabled info || return 0
  local title=$*
  local pad=$((NC_RULE_WIDTH - ${#title} - 4))
  ((pad < 2)) && pad=2
  printf '\n%s%s──%s %s%s%s %s%s%s\n' \
    "$C_CYAN" "$C_BOLD" "$C_RESET" \
    "$C_CYAN$C_BOLD" "$title" "$C_RESET" \
    "$C_CYAN$C_DIM" "$(log::_rule "$pad")" "$C_RESET" >&2
}

# A key/value line of a summary block. The key is dimmed so the eye lands on
# the values, which are what differ between two runs.
log::kv() {
  [[ $NC_LOG_FORMAT == json ]] && return 0
  log::enabled info || return 0
  printf '   %s%-26s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$(log::redact "$2")" >&2
}

# Same, with the value highlighted: for the handful of settings that change
# what the program will actually do.
log::kv_hl() {
  [[ $NC_LOG_FORMAT == json ]] && return 0
  log::enabled info || return 0
  local color=${3:-$C_CYAN}
  printf '   %s%-26s%s %s%s%s\n' "$C_DIM" "$1" "$C_RESET" "$color" "$(log::redact "$2")" "$C_RESET" >&2
}
