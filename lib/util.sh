#!/usr/bin/env bash
# lib/util.sh — Side-effect-free primitives, reusable and testable.
# shellcheck shell=bash

[[ -n ${NC_LIB_UTIL_SH:-} ]] && return 0
readonly NC_LIB_UTIL_SH=1

util::have() { command -v "$1" >/dev/null 2>&1; }

util::require_cmds() {
  local missing=() c
  for c in "$@"; do util::have "$c" || missing+=("$c"); done
  ((${#missing[@]} == 0)) && return 0
  log::die "$EX_DEPS" "Required commands missing from the image: ${missing[*]}"
}

util::lower() { printf '%s' "${1,,}"; }

util::trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# True for: true, 1, yes, y, on (case-insensitive). Everything else is false.
util::is_true() {
  case "$(util::lower "${1:-}")" in
    true|1|yes|y|on|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# Assert a boolean value is recognised, otherwise fail with a clear message.
util::assert_bool() {
  local name=$1 value=$2
  case "$(util::lower "$value")" in
    true|1|yes|y|on|enabled|false|0|no|n|off|disabled) return 0 ;;
    *) log::die "$EX_CONFIG" \
         "$name='${value}' is not a boolean. Accepted values: true/false." ;;
  esac
}

util::join() {
  local sep=$1; shift
  local out='' item
  for item in "$@"; do
    [[ -z $item ]] && continue
    out+="${out:+$sep}$item"
  done
  printf '%s' "$out"
}

# Split a string on a separator into the named array.
# usage: util::split_into <array_name> <separator> <string>
util::split_into() {
  local -n _arr=$1
  local sep=$2 str=$3
  _arr=()
  local IFS="$sep" part
  for part in $str; do
    part=$(util::trim "$part")
    [[ -n $part ]] && _arr+=("$part")
  done
}

# Convert a human-readable duration to seconds: 90, 45s, 30m, 12h, 7d, 1h30m.
util::parse_duration() {
  local spec; spec=$(util::lower "$(util::trim "${1:-}")")
  [[ -z $spec ]] && { printf '0'; return 1; }
  [[ $spec =~ ^[0-9]+$ ]] && { printf '%s' "$spec"; return 0; }
  [[ $spec =~ ^([0-9]+[dhms])+$ ]] || { printf '0'; return 1; }

  local total=0 num unit rest=$spec
  while [[ -n $rest ]]; do
    [[ $rest =~ ^([0-9]+)([dhms])(.*)$ ]] || { printf '0'; return 1; }
    num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
    case $unit in
      d) total=$((total + num * 86400)) ;;
      h) total=$((total + num * 3600)) ;;
      m) total=$((total + num * 60)) ;;
      s) total=$((total + num)) ;;
    esac
  done
  printf '%s' "$total"
}

util::human_duration() {
  local s=${1:-0} out=''
  ((s >= 86400)) && { out+="$((s / 86400))d "; s=$((s % 86400)); }
  ((s >= 3600))  && { out+="$((s / 3600))h ";  s=$((s % 3600)); }
  ((s >= 60))    && { out+="$((s / 60))m ";    s=$((s % 60)); }
  ((s > 0)) && out+="${s}s"
  out=$(util::trim "$out")
  printf '%s' "${out:-0s}"
}

# Split a command-line string into arguments the way a shell would.
#
# "read -r -a" splits on whitespace and nothing else, so the documented escape
# hatch could not carry --pre-hook "systemctl stop app" -- precisely the kind
# of option nobody exposes and everybody eventually needs. xargs applies shell
# quoting rules without shell evaluation, which is the point: a $(...) in the
# value reaches acme.sh as text instead of running while the configuration is
# being read.
#
# Returns 1 when the quoting is unbalanced, so the caller can say so rather
# than pass a mangled command line on.
# usage: util::split_args <array_name> <string>
util::split_args() {
  local -n _split_out=$1
  local s=$2 parsed
  _split_out=()
  [[ -z $s ]] && return 0
  parsed=$(printf '%s' "$s" | xargs -n1 printf '%s\n' 2>/dev/null) || return 1
  local line
  while IFS= read -r line; do [[ -n $line ]] && _split_out+=("$line"); done <<<"$parsed"
  return 0
}

# Render arguments for display, quoting the ones that contain whitespace.
#
# "${cmd[*]}" flattens an array into one space-separated string, so a single
# argument carrying spaces reads exactly like several -- which is unhelpful in
# the one log line an operator consults to find out what was actually run.
# usage: util::quote_args <arg>...
util::quote_args() {
  local q=\' bs=\\
  local out='' a esc
  for a in "$@"; do
    if [[ -z $a || $a == *[[:space:]]* || $a == *"$q"* ]]; then
      # Shell-style escaping of an embedded quote: ' -> '\''
      esc=${a//"$q"/${q}${bs}${q}${q}}
      out+="${out:+ }${q}${esc}${q}"
    else
      out+="${out:+ }${a}"
    fi
  done
  printf '%s' "$out"
}

# Filesystem-safe lineage name: *.example.org -> wildcard.example.org
util::sanitize_name() {
  local n=${1:-}
  n=${n//\*\./wildcard.}
  n=${n//\*/wildcard}
  n=${n//[^A-Za-z0-9._-]/_}
  # Every leading dot, not just the first: one pass turned "../../evil" into
  # "._.._evil", a directory "ls" does not show and no operator expects.
  while [[ $n == .* ]]; do n=${n#.}; done
  printf '%s' "$n"
}

# Pseudo-random integer in [0, max). Uses /dev/urandom rather than $RANDOM,
# whose seed is predictable and identical across twin containers.
util::rand() {
  local max=${1:-100}
  ((max <= 0)) && { printf '0'; return; }
  local n; n=$(od -An -N4 -tu4 </dev/urandom | tr -d ' ')
  printf '%s' "$((n % max))"
}

# Atomic write: the destination file is never observable in a partial state.
util::atomic_write() {
  local dest=$1 mode=${2:-0644}
  local tmp; tmp=$(mktemp "${dest}.XXXXXX") || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
}

# Retry a command with capped exponential backoff.
# usage: util::retry <attempts> <initial_delay_s> <command...>
util::retry() {
  local attempts=$1 delay=$2; shift 2
  local n=1 rc=0
  while :; do
    "$@" && return 0
    rc=$?
    ((n >= attempts)) && return "$rc"
    log::warn "Attempt ${n}/${attempts} failed (exit ${rc}), retrying in ${delay}s…"
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
    ((delay > 300)) && delay=300
  done
}

# Compare two semantic versions: returns 0 when $1 >= $2.
util::version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}
