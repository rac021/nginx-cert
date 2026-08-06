#!/usr/bin/env bash
# tests/run.sh -- Run the whole test suite.
#
#   ./tests/run.sh              everything: lint, unit, integration
#   ./tests/run.sh unit         unit tests only (no dependency)
#   ./tests/run.sh lint         shellcheck + hadolint, when installed
#   ./tests/run.sh integration  Docker tests (builds the image)
#   ./tests/run.sh providers    reach every declared authority (needs internet)
set -uo pipefail

NC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NC_ROOT
cd "$NC_ROOT" || exit 1

TARGET=${1:-all}
GLOBAL_RC=0

hr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# -- Lint --------------------------------------------------------------------
run_lint() {
  hr 'Static analysis'
  local rc=0

  if command -v shellcheck >/dev/null; then
    local -a files=()
    while IFS= read -r f; do files+=("$f"); done < <(
      { printf '%s\n' entrypoint.sh bin/certme
        find lib providers tests -name '*.sh' -type f; } | sort -u)
    if shellcheck --severity=warning --external-sources "${files[@]}"; then
      printf '  shellcheck: no warnings (%d files)\n' "${#files[@]}"
    else
      rc=1
    fi
  else
    printf '  shellcheck not installed -- skipped (apk add shellcheck / apt install shellcheck)\n'
  fi

  if command -v hadolint >/dev/null; then
    hadolint Dockerfile && printf '  hadolint: Dockerfile is clean\n' || rc=1
  else
    printf '  hadolint not installed -- skipped\n'
  fi
  return $rc
}

# -- Unit tests --------------------------------------------------------------
run_unit() {
  hr 'Unit tests'

  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
  # EXIT, not RETURN: a RETURN trap also fires when each sourced test file
  # returns, so the shared temporary directory was deleted before the second
  # file ran -- and the suite silently depended on filename order.
  # shellcheck disable=SC2064
  trap "rm -rf '$TEST_TMPDIR'" EXIT

  # Production code is loaded exactly the way the container loads it.
  # shellcheck source=../lib/bootstrap.sh
  source "${NC_ROOT}/lib/bootstrap.sh"
  # shellcheck source=lib/assert.sh
  source "${NC_ROOT}/tests/lib/assert.sh"

  # Quiet logging: the tests assert on values, not on messages.
  # shellcheck disable=SC2034  # read by lib/log.sh, sourced above
  NC_LOG_LEVEL=error

  local f
  for f in "${NC_ROOT}"/tests/unit/*.test.sh; do
    [[ -e $f ]] || continue
    (
      # A file that fails to source defines none of its tests, and reporting
      # "0 failed" for it made the whole suite pass while nothing ran.
      # shellcheck disable=SC1090
      source "$f" || { printf '\033[31m  [FAIL]\033[0m %s could not be sourced\n' "${f##*/}"; exit 1; }
      run_tests_in_file "$f"
      if ((TESTS_RUN == 0)); then
        printf '\033[31m  [FAIL]\033[0m %s defines no test\n' "${f##*/}"
        exit 1
      fi
      exit $((TESTS_FAILED > 0))
    ) || GLOBAL_RC=1
  done
  return 0
}

# -- Integration tests -------------------------------------------------------
run_integration() {
  hr 'Integration tests (Docker)'
  if ! command -v docker >/dev/null; then
    printf '  docker not available -- skipped\n'
    return 0
  fi
  local rc=0
  bash "${NC_ROOT}/tests/integration/container.test.sh" || rc=1
  bash "${NC_ROOT}/tests/integration/examples.test.sh"  || rc=1
  return $rc
}

# -- Live authority check ----------------------------------------------------
# Kept out of "all": it reaches the internet, and a transient outage must not
# fail an unrelated change. Run it on a schedule and before a release.
run_providers() {
  hr 'Declared authorities (live)'
  bash "${NC_ROOT}/tests/integration/providers-live.test.sh"
}

case $TARGET in
  lint)        run_lint || GLOBAL_RC=1 ;;
  unit)        run_unit ;;
  integration) run_integration || GLOBAL_RC=1 ;;
  providers)   run_providers   || GLOBAL_RC=1 ;;
  all)
    run_lint || GLOBAL_RC=1
    run_unit
    run_integration || GLOBAL_RC=1
    ;;
  *) printf 'Usage: %s [all|lint|unit|integration|providers]\n' "$0" >&2; exit 2 ;;
esac

hr 'Result'
if ((GLOBAL_RC == 0)); then
  printf '\033[32mAll tests passed.\033[0m\n'
else
  printf '\033[31mSome tests failed.\033[0m\n'
fi
exit "$GLOBAL_RC"
