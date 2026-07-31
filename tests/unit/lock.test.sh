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
