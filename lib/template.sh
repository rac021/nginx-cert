#!/usr/bin/env bash
# lib/template.sh — Minimal template engine, no external dependency.
#
# nginx templates contain nginx variables ($host, $remote_addr, ...). An engine
# that interpreted "$" or "${...}" would therefore collide with the target
# syntax. Placeholders use %%NAME%%: unambiguous, and a plain grep is enough to
# list every substitution in a file.
#
# Supported directives (not nestable, one per line):
#   %%IF NAME%% ... %%ELSE%% ... %%ENDIF%%
# shellcheck shell=bash

[[ -n ${NC_LIB_TEMPLATE_SH:-} ]] && return 0
readonly NC_LIB_TEMPLATE_SH=1

# Render a template to stdout.
# usage: template::render <file> KEY=VALUE...
template::render() {
  local file=$1; shift
  [[ -r $file ]] || { log::error "Template not readable: ${file}"; return 1; }

  local -A vars=()
  local kv
  for kv in "$@"; do
    [[ $kv == *=* ]] || continue
    vars["${kv%%=*}"]="${kv#*=}"
  done

  # 0 = emit, 1 = skip, 2 = skip until ENDIF (branch already taken)
  local state=0
  local line key val out=''

  while IFS= read -r line || [[ -n $line ]]; do
    local stripped; stripped=$(util::trim "$line")

    if [[ $stripped == '%%IF '*'%%' ]]; then
      key=${stripped#'%%IF '}; key=${key%'%%'}; key=$(util::trim "$key")
      if util::is_true "${vars[$key]:-}"; then state=0; else state=1; fi
      continue
    fi
    if [[ $stripped == '%%ELSE%%' ]]; then
      case $state in
        0) state=2 ;;
        1) state=0 ;;
      esac
      continue
    fi
    if [[ $stripped == '%%ENDIF%%' ]]; then
      state=0
      continue
    fi
    ((state != 0)) && continue

    for key in "${!vars[@]}"; do
      val=${vars[$key]}
      line=${line//"%%${key}%%"/$val}
    done
    out+="${line}"$'\n'
  done <"$file"

  printf '%s' "$out"
}

# Render a template to a file, atomically.
# usage: template::render_to <template> <destination> KEY=VALUE...
template::render_to() {
  local src=$1 dest=$2; shift 2
  local rendered
  rendered=$(template::render "$src" "$@") || return 1
  printf '%s' "$rendered" | util::atomic_write "$dest" 0644
}

# Report any %%...%% placeholder left unsubstituted. A forgotten value would
# otherwise produce a syntactically valid but functionally wrong nginx
# configuration, which is very hard to diagnose.
template::assert_complete() {
  local file=$1
  local leftovers
  leftovers=$(grep -oE '%%[A-Za-z0-9_]+%%' "$file" 2>/dev/null | sort -u | tr '\n' ' ') || true
  [[ -z $leftovers ]] && return 0
  log::error "Unsubstituted placeholders in ${file}: ${leftovers}"
  return 1
}
