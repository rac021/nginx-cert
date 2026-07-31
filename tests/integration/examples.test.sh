#!/usr/bin/env bash
# tests/integration/examples.test.sh -- Every shipped example must actually work.
#
# Documentation rots silently: a renamed variable, a retired authority or a
# changed default leaves the examples syntactically perfect and semantically
# wrong. Someone copies one, it does not do what it says, and the fault looks
# like the product's.
#
# So each Compose file is resolved by docker compose, its environment is handed
# to a real container, and the resulting configuration is compared with what the
# file claims to set up. No certificate authority is contacted: "certme list"
# and "certme config" only parse and report.
set -uo pipefail

NC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${NGINX_CERT_TEST_IMAGE:-nginx-cert:test}"

PASSED=0
FAILED=0
ok() { printf '\033[32m  [ ok ]\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
ko() { printf '\033[31m  [FAIL]\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '         %s\n' "$2"; FAILED=$((FAILED + 1)); }

# Placeholder credentials, so that ${VAR:?} interpolation resolves. They never
# reach an authority: these tests only parse.
export ACTALIS_EAB_KID=dummy-kid   ACTALIS_EAB_HMAC=dummy-hmac
export ZEROSSL_API_KEY=dummy-zerossl
export HARICA_EAB_KID=dummy-kid    HARICA_EAB_HMAC=dummy-hmac
export GTS_EAB_KID=dummy-kid       GTS_EAB_HMAC=dummy-hmac
export SSLCOM_EAB_KID=dummy-kid    SSLCOM_EAB_HMAC=dummy-hmac
export CORP_EAB_KID=dummy-kid      CORP_EAB_HMAC=dummy-hmac
export CF_TOKEN=dummy-token        CF_ACCOUNT_ID=dummy-account

# Run certme inside the image with the environment of a Compose file's
# nginx-cert service.
#
# Each KEY=VALUE pair travels base64-encoded, one per line. CERT_DOMAINS is
# routinely multi-line, and any separator that can occur inside a value --
# whitespace, newline -- would tear it into fragments on the way in.
run_with_env_of() {
  local file=$1; shift
  local -a args=()
  local encoded
  while IFS= read -r encoded; do
    [[ -z $encoded ]] && continue
    args+=(--env "$(printf '%s' "$encoded" | base64 -d)")
  done < <(
    docker compose -f "$file" config --format json 2>/dev/null |
      jq -r '.services | to_entries[]
             | select(.key | test("nginx-cert|^web$"))
             | .value.environment // {}
             | to_entries[]
             | "\(.key)=\(.value)" | @base64'
  )
  ((${#args[@]})) || return 2
  docker run --rm "${args[@]}" "$IMAGE" "$@" 2>&1
}

# expect_certs <file> <description> <expected count> <substring...>
expect_certs() {
  local file=$1 desc=$2 want=$3; shift 3
  local out rc=0
  out=$(run_with_env_of "$file" certme list) || rc=$?

  if ((rc == 2)); then ko "$desc" 'no nginx-cert service found'; return; fi
  if ((rc != 0)); then ko "$desc" "certme list exited ${rc}: ${out}"; return; fi

  local got; got=$(printf '%s\n' "$out" | grep -c .)
  if [[ $got != "$want" ]]; then
    ko "$desc" "expected ${want} certificate(s), got ${got}:"$'\n'"${out}"; return
  fi
  local needle
  for needle in "$@"; do
    if [[ $out != *"$needle"* ]]; then
      ko "$desc" "'${needle}' missing from:"$'\n'"${out}"; return
    fi
  done
  ok "$desc"
}

printf '\n  -- every Compose file is schema-valid --\n'
for f in "${NC_ROOT}/docker-compose.yml" "${NC_ROOT}"/examples/*.yml; do
  name=${f#"${NC_ROOT}/"}
  if docker compose -f "$f" config -q 2>/dev/null; then ok "$name"; else
    ko "$name" "$(docker compose -f "$f" config -q 2>&1 | head -2)"
  fi
done

printf '\n  -- the environment produces the advertised certificates --\n'
cd "$NC_ROOT" || exit 1

expect_certs docker-compose.yml \
  'docker-compose.yml: one multi-SAN certificate' 1 \
  'example.com' 'www.example.com'

expect_certs examples/compose.actalis.yml \
  'actalis: single domain, Actalis first in the chain' 1 \
  'data.example.eu'

expect_certs examples/compose.zerossl.yml \
  'zerossl: provider pinned to ZeroSSL' 1 \
  'zerossl'

expect_certs examples/compose.harica.yml \
  'harica: provider pinned to HARICA' 1 \
  'harica'

expect_certs examples/compose.multisite.yml \
  'multisite: four independent certificates' 4 \
  'api.example.com' 'grafana.example.com' 'actalis'

expect_certs examples/compose.multi-ca.yml \
  'multi-ca: one authority per line, including a local-only name' 4 \
  'actalis' 'zerossl' 'wildcard.apps.example.com' 'internal.lan'

expect_certs examples/compose.wildcard-dns.yml \
  'wildcard-dns: wildcard and apex in one certificate' 1 \
  'wildcard.example.com' 'wildcard'

expect_certs examples/compose.ip-address.yml \
  'ip-address: classified as an IP, not a domain' 1 \
  '203.0.113.10'

expect_certs examples/compose.localdev.yml \
  'localdev: three names, all internal, no public authority' 3 \
  'localhost' 'app.test' 'api.localhost'

expect_certs examples/compose.private-acme.yml \
  'private-acme: carrier provider with an overridden directory' 1 \
  'service.corp.example.com'

expect_certs examples/compose.behind-lb.yml \
  'behind-lb: certificate declared even with vhosts disabled' 1 \
  'example.com'

printf '\n  -- name classification matches the intent of each example --\n'
out=$(run_with_env_of examples/compose.multi-ca.yml certme list)
if [[ $out == *'wildcard.apps.example.com'*wildcard* && $out == *'internal.lan'*internal* ]]; then
  ok 'multi-ca: wildcard and internal names are classified correctly'
else
  ko 'multi-ca: wildcard and internal names are classified correctly' "$out"
fi

out=$(run_with_env_of examples/compose.ip-address.yml certme list)
if [[ $out == *'203.0.113.10'*'ip'* ]]; then
  ok 'ip-address: the IP kind is detected'
else
  ko 'ip-address: the IP kind is detected' "$out"
fi

printf '\n  -- per-line options reach the configuration --\n'
out=$(run_with_env_of examples/compose.multisite.yml certme config)
if [[ $out == *'grafana:3000'* && $out == *'api:3000'* ]]; then
  ok 'multisite: upstream= is applied per certificate'
else
  ko 'multisite: upstream= is applied per certificate' "$out"
fi

out=$(run_with_env_of examples/compose.wildcard-dns.yml certme config)
if [[ $out == *'dns_cf'* ]]; then
  ok 'wildcard-dns: the DNS module is picked up'
else
  ko 'wildcard-dns: the DNS module is picked up' "$out"
fi

out=$(run_with_env_of examples/compose.multi-ca.yml certme config)
if [[ $out == *'provider=actalis'* && $out == *'provider=zerossl'* ]]; then
  ok 'multi-ca: provider= overrides the global choice per line'
else
  ko 'multi-ca: provider= overrides the global choice per line' "$out"
fi

printf '\n  -- no example leaks a credential into the summary --\n'
leaked=0
checked=0
for f in docker-compose.yml examples/*.yml; do
  out=$(run_with_env_of "$f" certme config) || continue
  checked=$((checked + 1))
  for secret in dummy-hmac dummy-zerossl dummy-token; do
    if [[ $out == *"$secret"* ]]; then
      ko "${f}: ${secret} appears in certme config"; leaked=1
    fi
  done
done
if ((checked == 0)); then
  ko 'credential masking was verified' 'no example produced any output'
elif ((leaked == 0)); then
  ok "certme config masks every credential (${checked} files)"
fi

printf '\n  %d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
