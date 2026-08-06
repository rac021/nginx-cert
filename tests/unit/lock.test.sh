#!/usr/bin/env bash
# Mutual exclusion, and the invariant that releasing a lock must not disturb
# anything else.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   CFG_* are set here to drive the code under test.

_lockfile() { printf '%s/lock-%s' "$TEST_TMPDIR" "$1"; }

test_a_lock_is_taken_and_released() {
  local f; f=$(_lockfile taken)
  assert_ok lock::acquire "$f"
  lock::release
  # Releasing must leave it free for the next caller.
  assert_ok lock::acquire "$f"
  lock::release
}

test_a_held_lock_is_refused_immediately() {
  local f; f=$(_lockfile held)
  lock::acquire "$f"
  # A separate process must not get it while we hold it.
  assert_fails bash -c "
    source '${NC_ROOT}/lib/bootstrap.sh'
    lock::acquire '$f'"
  lock::release
}

test_with_runs_the_command_and_releases() {
  local f; f=$(_lockfile with)
  assert_ok lock::with "$f" 0 true
  assert_ok lock::acquire "$f"
  lock::release
}

test_with_propagates_the_command_exit_code() {
  local f; f=$(_lockfile rc)
  assert_exit_code 7 lock::with "$f" 0 bash -c 'exit 7'
}

# Releasing the lock used to attach "2>/dev/null" to a bare "exec", which
# applies the redirection to the shell itself for the rest of the process.
# Every later message -- all logging goes to stderr -- was discarded, so the
# run summary and any post-release failure disappeared without trace.
test_releasing_the_lock_leaves_stderr_intact() {
  local out
  out=$(
    bash -c "
      source '${NC_ROOT}/lib/bootstrap.sh'
      NC_LOG_LEVEL=info
      lock::acquire '$(_lockfile stderr)'
      lock::release
      log::info 'still visible after the lock is released'
    " 2>&1
  )
  assert_contains "$out" 'still visible after the lock is released'
}

test_stderr_survives_lock_with_too() {
  local out
  out=$(
    bash -c "
      source '${NC_ROOT}/lib/bootstrap.sh'
      NC_LOG_LEVEL=info
      lock::with '$(_lockfile stderr2)' 0 true
      log::info 'summary would be printed here'
    " 2>&1
  )
  assert_contains "$out" 'summary would be printed here'
}

# The wait parameter this function has always advertised was implemented with
# "flock -w", which BusyBox does not have -- so on the image we actually ship,
# asking to wait failed instantly with a usage error even when the lock was
# free. It is a poll now, and these three cases are what make that real code
# rather than a latent trap.

test_waiting_for_a_free_lock_succeeds_at_once() {
  local f; f=$(_lockfile wait_free)
  local start; start=$(date +%s)
  assert_ok lock::acquire "$f" 5
  lock::release
  local elapsed=$(( $(date +%s) - start ))
  assert_ok bash -c "[ '$elapsed' -le 1 ]" 'a free lock must not be waited for'
}

test_waiting_gives_up_after_the_deadline() {
  local f; f=$(_lockfile wait_busy)
  lock::acquire "$f"
  local start; start=$(date +%s)
  assert_fails bash -c "
    source '${NC_ROOT}/lib/bootstrap.sh'
    lock::acquire '$f' 2"
  local elapsed=$(( $(date +%s) - start ))
  lock::release
  assert_ok bash -c "[ '$elapsed' -ge 2 ]" 'it must actually have waited'
  assert_ok bash -c "[ '$elapsed' -le 6 ]" 'and then given up'
}

test_waiting_takes_the_lock_as_soon_as_it_is_freed() {
  local f; f=$(_lockfile wait_freed)
  # Held for a second by another process, then released.
  bash -c "
    source '${NC_ROOT}/lib/bootstrap.sh'
    lock::acquire '$f'
    sleep 1
    lock::release" &
  local holder=$!
  sleep 0.3
  assert_ok lock::acquire "$f" 10 'the waiter must get it once the holder lets go'
  lock::release
  wait "$holder" 2>/dev/null || true
}

# An unopenable lock file and a held one share nothing but their exit status.
# Reporting the first as "another operation is already running" made a
# read-only volume look like a concurrency problem, forever.
test_an_unopenable_lock_file_is_not_reported_as_contention() {
  local dir="${TEST_TMPDIR}/ro-lock"
  rm -rf "$dir"; mkdir -p "$dir"; chmod 500 "$dir"
  local rc=0
  lock::acquire "${dir}/nginx-cert.lock" || rc=$?
  chmod 700 "$dir"
  assert_eq '2' "$rc" 'exit 2 means "cannot open", not "busy"'
}
