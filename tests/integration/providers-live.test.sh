#!/usr/bin/env bash
# tests/integration/providers-live.test.sh -- Are the declared authorities real?
#
# Deliberately kept out of the default suite: it reaches the internet, so a
# transient outage would fail an unrelated pull request. Run it on a schedule,
# and before a release.
#
# It exists because a certificate authority can simply stop. Buypass Go SSL did:
# it ceased issuing in October 2025 and shut its ACME service down in April
# 2026. Until this check existed, the dead entry stayed in the table and cost
# every automatic run a full connection timeout before the chain moved on.
#
# For each row of providers.tsv:
#   - the directory URL must answer 200 with newAccount and newOrder;
#   - the externalAccountRequired it advertises must match the table's flag,
#     because that flag decides whether credentials are sent and whether the
#     authority is kept in a chain at all.
set -uo pipefail

NC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TABLE="${NC_ROOT}/providers/providers.tsv"

PASSED=0
FAILED=0
ok() { printf '\033[32m  [ ok ]\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
ko() { printf '\033[31m  [FAIL]\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '         %s\n' "$2"; FAILED=$((FAILED + 1)); }

printf '\n  -- every declared authority answers, with the advertised EAB policy --\n'

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

# Only four columns matter here; the rest are named for readability and
# deliberately unused.
# shellcheck disable=SC2034
while IFS=$'\t' read -r id label alias directory eab staging caps notes; do
  [[ -z $id || $id == '#'* ]] && continue

  code=$(curl -s -o "$tmp" -w '%{http_code}' --max-time 25 "$directory" 2>/dev/null)
  if [[ $code != 200 ]]; then
    ko "${id}: directory answers" "HTTP ${code} at ${directory} -- retired, moved, or unreachable"
    continue
  fi
  if ! jq -e '.newAccount and .newOrder' "$tmp" >/dev/null 2>&1; then
    ko "${id}: directory is a valid ACME endpoint" "no newAccount/newOrder at ${directory}"
    continue
  fi

  advertised=$(jq -r 'if .meta.externalAccountRequired == true then "required"
                      elif .meta.externalAccountRequired == false then "no"
                      else "unset" end' "$tmp")
  # Let's Encrypt does not publish the field at all; absence means "not
  # required", which is what "no" in the table encodes.
  [[ $advertised == unset ]] && advertised=no

  if [[ $advertised == "$eab" ]]; then
    ok "${id}: reachable, EAB '${eab}' as declared"
  else
    ko "${id}: EAB flag matches the directory" \
       "providers.tsv says '${eab}', ${directory} advertises '${advertised}'"
  fi
done <"$TABLE"

printf '\n  %d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
