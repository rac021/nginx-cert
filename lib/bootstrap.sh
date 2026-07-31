#!/usr/bin/env bash
# lib/bootstrap.sh — Common entry point: locates the project and loads every
# module in dependency order.
#
# Every executable (entrypoint.sh, bin/certme, tests) sources only this file.
# shellcheck shell=bash
#
# shellcheck disable=SC2034
#   NC_VERSION is consumed by bin/certme and entrypoint.sh.

[[ -n ${NC_LIB_BOOTSTRAP_SH:-} ]] && return 0
readonly NC_LIB_BOOTSTRAP_SH=1

# Project root, derived from this file's location: works both inside the image
# (/opt/nginx-cert) and from a clone of the repository.
NC_ROOT="${NC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export NC_ROOT

NC_VERSION="$(cat "${NC_ROOT}/VERSION" 2>/dev/null || printf 'dev')"

# shellcheck source=lib/log.sh
source "${NC_ROOT}/lib/log.sh"
# shellcheck source=lib/util.sh
source "${NC_ROOT}/lib/util.sh"
# shellcheck source=lib/domains.sh
source "${NC_ROOT}/lib/domains.sh"
# shellcheck source=lib/template.sh
source "${NC_ROOT}/lib/template.sh"
# shellcheck source=lib/lock.sh
source "${NC_ROOT}/lib/lock.sh"
# shellcheck source=providers/registry.sh
source "${NC_ROOT}/providers/registry.sh"
# shellcheck source=lib/config.sh
source "${NC_ROOT}/lib/config.sh"
# shellcheck source=lib/certs.sh
source "${NC_ROOT}/lib/certs.sh"
# shellcheck source=lib/nginx.sh
source "${NC_ROOT}/lib/nginx.sh"
# shellcheck source=providers/selfsigned.sh
source "${NC_ROOT}/providers/selfsigned.sh"
# shellcheck source=providers/acme_driver.sh
source "${NC_ROOT}/providers/acme_driver.sh"
# shellcheck source=providers/zerossl_rest.sh
source "${NC_ROOT}/providers/zerossl_rest.sh"
# shellcheck source=lib/issue.sh
source "${NC_ROOT}/lib/issue.sh"

# Prepare the data tree and check it is usable.
# A read-only volume, or one owned by another user, is the most common cause of
# silent failure: we detect it immediately.
bootstrap::prepare_dirs() {
  # A bind-mounted host directory is the usual cause: Docker leaves it owned by
  # the host user, while this container runs unprivileged. Naming the uid is not
  # enough -- give the command that fixes it. (A named volume needs none of
  # this: Docker seeds its ownership from the image.)
  local uid gid fix
  uid=$(id -u); gid=$(id -g)
  fix="  -> Run: sudo chown -R ${uid}:${gid} <the host directory mounted on ${CFG_DATA_DIR}>
     Or use a named volume instead of a bind mount: -v nginx-cert-data:${CFG_DATA_DIR}"

  local d
  for d in "$CFG_DATA_DIR" "$CFG_CERT_DIR" "$CFG_ACME_HOME" "$CFG_STATE_DIR" \
           "$CFG_BACKUP_DIR" "$CFG_WEBROOT"; do
    if ! mkdir -p "$d" 2>/dev/null; then
      log::error "Cannot create ${d}: this container runs as uid ${uid}, which cannot write there."
      log::die "$EX_CONFIG" "$fix"
    fi
  done
  if [[ ! -w $CFG_DATA_DIR ]]; then
    log::error "${CFG_DATA_DIR} is not writable by $(id -un) (uid ${uid})."
    log::die "$EX_CONFIG" "$fix"
  fi
  chmod 700 "$CFG_ACME_HOME" 2>/dev/null || true
  chmod 700 "$CFG_STATE_DIR" 2>/dev/null || true

  bootstrap::_warn_if_not_persistent
}

# Without a volume on /data, certificates and the ACME account key live in the
# container's ephemeral layer: they vanish on the first
# "docker compose up --force-recreate" and everything is re-requested from the
# authority -- the fastest way to burn a Let's Encrypt quota.
bootstrap::_warn_if_not_persistent() {
  # The entrypoint already warned: the certme processes it spawns must not
  # repeat the message on every scheduler run.
  [[ -n ${NC_NO_PERSIST_WARN:-} ]] && return 0
  util::is_true "${CFG_ENABLE:-true}" || return 0
  ((${#NC_SPEC_NAMES[@]})) || return 0
  [[ -e "${CFG_DATA_DIR}/.persistent" ]] && return 0

  local dev_data dev_root
  dev_data=$(stat -c '%d' "$CFG_DATA_DIR" 2>/dev/null || printf 'x')
  dev_root=$(stat -c '%d' / 2>/dev/null || printf 'y')
  if [[ $dev_data == "$dev_root" ]]; then
    log::warn "${CFG_DATA_DIR} is not a volume: certificates and the account key will be lost when the container is recreated."
    log::detail warn "Add 'volumes: [ nginx-cert-data:/data ]' to your docker-compose.yml."
  else
    : >"${CFG_DATA_DIR}/.persistent" 2>/dev/null || true
  fi
  return 0
}

# Remove staging directories abandoned by an interrupted run (container
# stopped mid-issuance).
bootstrap::cleanup_staging() {
  local d
  for d in "${CFG_DATA_DIR}"/.staging.*; do
    [[ -d $d ]] || continue
    log::debug "Removing abandoned staging directory: ${d}"
    rm -rf "$d"
  done
  return 0
}
