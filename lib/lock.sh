#!/usr/bin/env bash
# lib/lock.sh — Mutual exclusion between the scheduler, the CLI and the
# entrypoint.
#
# Without this lock, a manual "certme renew" launched while the scheduler is
# running produces two concurrent ACME clients on the same account: challenges
# overwrite each other, quota is burned for nothing, and certificate files end
# up half-written.
# shellcheck shell=bash

[[ -n ${NC_LIB_LOCK_SH:-} ]] && return 0
readonly NC_LIB_LOCK_SH=1

NC_LOCK_FD=''
NC_LOCK_PATH=''

# Acquire the global lock, or fail immediately if it is already held.
# usage: lock::acquire <path> [max_wait_seconds]
lock::acquire() {
  local path=$1 wait_s=${2:-0}
  mkdir -p "$(dirname "$path")" 2>/dev/null || true

  if util::have flock; then
    exec {NC_LOCK_FD}>"$path" || return 1
    NC_LOCK_PATH=$path
    if ((wait_s > 0)); then
      flock -w "$wait_s" "$NC_LOCK_FD" && return 0
    else
      flock -n "$NC_LOCK_FD" && return 0
    fi
    exec {NC_LOCK_FD}>&-
    NC_LOCK_FD=''; NC_LOCK_PATH=''
    return 1
  fi

  # Portable fallback: mkdir is atomic on every filesystem.
  local dir="${path}.d" waited=0
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s' "$$" >"$dir/pid"
      NC_LOCK_PATH=$dir
      return 0
    fi
    # Stale lock: the owning process no longer exists.
    local owner; owner=$(cat "$dir/pid" 2>/dev/null || printf '')
    if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then
      log::warn "Stale lock held by PID ${owner} (gone): releasing it."
      rm -rf "$dir"
      continue
    fi
    ((waited >= wait_s)) && return 1
    sleep 1
    waited=$((waited + 1))
  done
}

lock::release() {
  if [[ -n $NC_LOCK_FD ]]; then
    flock -u "$NC_LOCK_FD" 2>/dev/null || true

    # Never attach a redirection to a bare "exec": with no command to run, the
    # redirection is applied to the shell itself and stays for the rest of the
    # process. Writing "exec {fd}>&- 2>/dev/null" therefore silenced every
    # later message -- all logging goes to stderr -- so the run summary, and
    # any failure reported after the lock was released, simply vanished.
    #
    # Closing a descriptor that is no longer open aborts a non-interactive
    # shell and cannot be caught with "|| true", so check before closing.
    if [[ -e /proc/$$/fd/${NC_LOCK_FD} ]]; then
      exec {NC_LOCK_FD}>&-
    fi
    NC_LOCK_FD=''
  elif [[ -n $NC_LOCK_PATH && -d $NC_LOCK_PATH ]]; then
    rm -rf "$NC_LOCK_PATH"
  fi
  NC_LOCK_PATH=''
  return 0
}

# Run a command under the lock, always releasing it on the way out.
# usage: lock::with <path> <max_wait_seconds> <command...>
lock::with() {
  local path=$1 wait_s=$2; shift 2
  if ! lock::acquire "$path" "$wait_s"; then
    log::error "Another certificate operation is already running (lock: ${path})."
    return "$EX_BUSY"
  fi
  local rc=0
  "$@" || rc=$?
  lock::release
  return "$rc"
}
