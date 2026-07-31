#!/usr/bin/env bash
# tests/run.sh -- Run the whole test suite.
#
#   ./tests/run.sh              everything: lint, unit, integration
#   ./tests/run.sh unit         unit tests only (no dependency)
#   ./tests/run.sh lint         shellcheck + hadolint, when installed
#   ./tests/run.sh integration  Docker tests (builds the image)
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
  # shellcheck disable=SC2064
  trap "rm -rf '$TEST_TMPDIR'" RETURN

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
      # shellcheck disable=SC1090
      source "$f"
      run_tests_in_file "$f"
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
  bash "${NC_ROOT}/tests/integration/container.test.sh"
}

case $TARGET in
  lint)        run_lint || GLOBAL_RC=1 ;;
  unit)        run_unit ;;
  integration) run_integration || GLOBAL_RC=1 ;;
  all)
    run_lint || GLOBAL_RC=1
    run_unit
    run_integration || GLOBAL_RC=1
    ;;
  *) printf 'Usage: %s [all|lint|unit|integration]\n' "$0" >&2; exit 2 ;;
esac

hr 'Result'
if ((GLOBAL_RC == 0)); then
  printf '\033[32mAll tests passed.\033[0m\n'
else
  printf '\033[31mSome tests failed.\033[0m\n'
fi
exit "$GLOBAL_RC"
