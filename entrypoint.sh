#!/usr/bin/env bash
# entrypoint.sh -- container PID 1: supervisor for nginx and the renewal
# scheduler.
#
# Three responsibilities, in this order:
#
#  1. Break the first-boot circular dependency. The HTTP-01 challenge needs an
#     nginx already listening; nginx needs certificates already present. So we
#     drop in a temporary local certificate, start nginx, then request the real
#     certificate. Version 1 tried to issue before starting nginx, which made
#     renewal fail on every restart.
#
#  2. Forward signals properly. "docker stop" sends SIGTERM to PID 1: we
#     translate it into SIGQUIT for nginx, the only signal that lets in-flight
#     requests finish. Version 1 ended on SIGKILL after the grace period,
#     cutting every connection.
#
#  3. Supervise. If nginx dies, the container must die too -- otherwise the
#     Docker or orchestrator restart policy never kicks in and the service
#     stays down with nothing to show for it.
set -uo pipefail

NC_ROOT="${NC_ROOT:-/opt/nginx-cert}"
# shellcheck source=lib/bootstrap.sh
source "${NC_ROOT}/lib/bootstrap.sh"

NC_LOG_COMPONENT='entrypoint'
NC_SHUTTING_DOWN=0
NC_NGINX_PID=''
NC_SCHED_PID=''
NC_SLEEP_PID=''

# --- Signals ---------------------------------------------------------------
on_signal() {
  ((NC_SHUTTING_DOWN)) && return
  NC_SHUTTING_DOWN=1
  log::info "Shutdown signal received."

  [[ -n $NC_SLEEP_PID ]] && kill "$NC_SLEEP_PID" 2>/dev/null
  if [[ -n $NC_SCHED_PID ]]; then
    kill -TERM "$NC_SCHED_PID" 2>/dev/null || true
  fi
  nginx::quit
}
trap on_signal TERM INT QUIT

# --- Scheduler -------------------------------------------------------------
#
# A plain loop rather than a cron daemon: logs go to the container's standard
# output, the interval is expressed as a readable duration, and there is no
# crontab to write nor timezone to guess.
#
# The jitter prevents every instance of a fleet from contacting the authority
# on the same second -- behaviour Let's Encrypt explicitly recommends.
scheduler_loop() {
  NC_LOG_COMPONENT='scheduler'
  local nap jitter
  while :; do
    jitter=0
    ((CFG_RENEW_JITTER_S > 0)) && jitter=$(util::rand "$CFG_RENEW_JITTER_S")
    nap=$((CFG_RENEW_INTERVAL_S + jitter))
    log::info "Next certificate check in $(util::human_duration "$nap")."
    sleep "$nap"
    log::info "Periodic certificate check…"
    NC_NO_PERSIST_WARN=1 "${NC_ROOT}/bin/certme" issue \
      || log::warn "The periodic check finished with errors (see above)."
  done
}

start_scheduler() {
  util::is_true "$CFG_ENABLE" || return 0
  ((${#NC_SPEC_NAMES[@]})) || return 0
  scheduler_loop &
  NC_SCHED_PID=$!
  log::debug "Scheduler started (PID ${NC_SCHED_PID})."
}

# --- nginx -----------------------------------------------------------------
start_nginx() {
  log::info "Starting nginx…"
  nginx -g 'daemon off;' &
  NC_NGINX_PID=$!

  local waited=0
  while ((waited < 15)); do
    nginx::is_running && { log::ok "nginx is listening (PID $(nginx::pid))."; return 0; }
    kill -0 "$NC_NGINX_PID" 2>/dev/null || break
    sleep 1; waited=$((waited + 1))
  done

  if ! kill -0 "$NC_NGINX_PID" 2>/dev/null; then
    log::die "$EX_NGINX" "nginx exited immediately after starting."
  fi
  log::warn "nginx did not write its PID file after ${waited}s; supervision continues."
  return 0
}

# --- Supervision -----------------------------------------------------------
supervise() {
  local rc=0
  while ((NC_SHUTTING_DOWN == 0)); do
    if ! kill -0 "$NC_NGINX_PID" 2>/dev/null; then
      wait "$NC_NGINX_PID" 2>/dev/null || rc=$?
      ((NC_SHUTTING_DOWN)) && break
      log::error "nginx stopped unexpectedly (exit ${rc}). Terminating the container."
      return "${rc:-1}"
    fi
    if [[ -n $NC_SCHED_PID ]] && ! kill -0 "$NC_SCHED_PID" 2>/dev/null; then
      log::warn "The scheduler stopped: restarting it."
      NC_SCHED_PID=''
      start_scheduler
    fi
    sleep 5 &
    NC_SLEEP_PID=$!
    wait "$NC_SLEEP_PID" 2>/dev/null || true
    NC_SLEEP_PID=''
  done
  return 0
}

# --- Startup ---------------------------------------------------------------
main() {
  # Allows "docker run <image> certme status", or replacing the command
  # entirely, without losing arguments the way "bash -c" did.
  if (($#)); then
    case $1 in
      serve) shift ;;
      certme) shift; exec "${NC_ROOT}/bin/certme" "$@" ;;
      *) if command -v "$1" >/dev/null 2>&1; then exec "$@"; fi ;;
    esac
  fi

  log::section "nginx-cert ${NC_VERSION}"

  config::load
  config::summary
  bootstrap::prepare_dirs
  bootstrap::cleanup_staging

  if util::is_true "$CFG_ENABLE" && ((${#NC_SPEC_NAMES[@]})); then
    issue::ensure_placeholders || log::die "$EX_FAIL" "Could not prepare the certificates."
  fi

  log::section "nginx configuration"
  nginx::render || log::die "$EX_NGINX" "Could not generate the nginx configuration."
  nginx::test   || log::die "$EX_NGINX" "The generated configuration is invalid: refusing to start with a broken configuration."

  start_nginx

  if util::is_true "$CFG_ENABLE" && ((${#NC_SPEC_NAMES[@]})); then
    log::section "Certificates"
    # A failure here must not keep the service down: the temporary
    # certificates are in place and the scheduler will retry.
    NC_NO_PERSIST_WARN=1 "${NC_ROOT}/bin/certme" issue \
      || log::warn "Some certificates could not be obtained; the service starts anyway."
  fi

  start_scheduler

  log::ok "nginx-cert is up."
  supervise
}

main "$@"
