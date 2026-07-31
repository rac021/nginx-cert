#!/usr/bin/env bash
# tests/integration/container.test.sh -- End-to-end behaviour of the image.
#
# These tests exercise what unit tests cannot: real nginx, real openssl, real
# process signalling. Every scenario here maps to a version-1 defect that unit
# tests would never have caught -- notably the shutdown that ended in SIGKILL
# and the first boot that tried to issue before nginx was listening.
#
# No public certificate authority is contacted: everything runs against
# internal names, so the suite is deterministic and consumes no quota.
set -uo pipefail

NC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${NGINX_CERT_TEST_IMAGE:-nginx-cert:test}"
CONTAINER='nginx-cert-itest'
VOLUME='nginx-cert-itest-data'
HTTP_PORT=18080
HTTPS_PORT=18443

PASSED=0
FAILED=0

ok()   { printf '\033[32m  [ ok ]\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
ko()   { printf '\033[31m  [FAIL]\033[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '         %s\n' "$2"; FAILED=$((FAILED + 1)); }
info() { printf '\033[2m  ..    %s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then ok "$label"; else ko "$label" "expected '${expected}', got '${actual}'"; fi
}

# -- Build -------------------------------------------------------------------
info "building ${IMAGE}"
if ! docker build -q -t "$IMAGE" "$NC_ROOT" >/dev/null; then
  ko 'image builds'
  exit 1
fi
ok 'image builds'

# -- Scenario 1: invalid configuration is rejected before anything starts -----
out=$(docker run --rm -e CERT_DOMAINS='example.com' -e CERT_EMAIL='a@b.co' \
        -e CERT_RENEW_INTERVAL='not-a-duration' "$IMAGE" 2>&1); rc=$?
check 'invalid CERT_RENEW_INTERVAL exits with code 2' '2' "$rc"
if [[ $out == *'CERT_RENEW_INTERVAL'* ]]; then
  ok 'the error message names the offending variable'
else
  ko 'the error message names the offending variable' "$out"
fi

out=$(docker run --rm -e CERT_DOMAINS='example.com | typo=1' -e CERT_EMAIL='a@b.co' "$IMAGE" 2>&1); rc=$?
check 'unknown CERT_DOMAINS option exits with code 2' '2' "$rc"

# -- Scenario 2: nominal start, local names ---------------------------------
cleanup
docker run -d --name "$CONTAINER" -v "${VOLUME}:/data" \
  -p "${HTTP_PORT}:80" -p "${HTTPS_PORT}:443" \
  -e CERT_EMAIL='dev@example.test' \
  -e CERT_DOMAINS=$'localhost | upstream=nonexistent:8080\napp.test' \
  "$IMAGE" >/dev/null

for _ in $(seq 1 30); do
  [[ "$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" == true ]] || break
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done

if docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up'; then
  ok 'the container reaches a running state'
else
  ko 'the container reaches a running state' "$(docker logs "$CONTAINER" 2>&1 | tail -5)"
fi

# Internal names must never trigger a network call to a public authority.
if docker logs "$CONTAINER" 2>&1 | grep -q "Let's Encrypt"; then
  ko 'no public authority is contacted for internal names'
else
  ok 'no public authority is contacted for internal names'
fi

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/healthz")
check 'the /healthz probe answers over plain HTTP' '200' "$code"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/anything")
check 'plain HTTP redirects with 308' '308' "$code"

# The upstream does not exist: 502 is the expected answer, and it proves nginx
# started anyway -- a hard-coded upstream name would have prevented that.
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${HTTPS_PORT}/")
check 'HTTPS is served even with a missing upstream' '502' "$code"

san=$(echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername localhost 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null)
if [[ $san == *'IP Address:127.0.0.1'* ]]; then
  ok 'the localhost certificate carries the loopback SAN'
else
  ko 'the localhost certificate carries the loopback SAN' "$san"
fi

# -- Scenario 3: file permissions and privileges -----------------------------
perms=$(docker exec "$CONTAINER" stat -c '%a' /data/certs/localhost/privkey.pem 2>/dev/null)
check 'the private key is mode 600' '600' "$perms"

perms=$(docker exec "$CONTAINER" stat -c '%a' /data/certs/localhost 2>/dev/null)
check 'the certificate directory is mode 750' '750' "$perms"

uid=$(docker exec "$CONTAINER" id -u)
if [[ $uid != 0 ]]; then ok "the container runs unprivileged (uid ${uid})"; else ko 'the container runs unprivileged' 'running as root'; fi

# -- Scenario 4: the CLI -----------------------------------------------------
# Capture first, then match: piping straight into "grep -q" makes grep exit on
# the first match, certme takes SIGPIPE, and pipefail turns that into a
# spurious failure.
status_out=$(docker exec "$CONTAINER" certme status 2>&1)
if [[ $status_out == *localhost* && $status_out == *app.test* ]]; then
  ok 'certme status lists the certificates'
else
  ko 'certme status lists the certificates' "$status_out"
fi

if docker exec "$CONTAINER" certme status --json | jq -e '.certificates | length == 2' >/dev/null 2>&1; then
  ok 'certme status --json emits valid JSON'
else
  ko 'certme status --json emits valid JSON' "$(docker exec "$CONTAINER" certme status --json 2>&1 | head -3)"
fi

if docker exec "$CONTAINER" certme check >/dev/null 2>&1; then
  ok 'the generated nginx configuration is valid'
else
  ko 'the generated nginx configuration is valid'
fi

if docker exec "$CONTAINER" certme health >/dev/null 2>&1; then
  ok 'certme health reports a healthy container'
else
  ko 'certme health reports a healthy container'
fi

# A secret passed in the environment must never surface in the logs.
docker exec -e CERT_ZEROSSL_API_KEY='SUPERSECRETVALUE123' "$CONTAINER" \
  certme config >/tmp/nc-config.$$ 2>&1
if grep -q 'SUPERSECRETVALUE123' /tmp/nc-config.$$; then
  ko 'certme config masks secrets' "$(grep -m1 SUPERSECRET /tmp/nc-config.$$)"
else
  ok 'certme config masks secrets'
fi
rm -f /tmp/nc-config.$$

# -- Scenario 5: graceful shutdown ------------------------------------------
# Version 1 ignored SIGTERM and was killed after the 10s grace period
# (exit code 137), cutting every in-flight connection.
start=$(date +%s)
docker stop "$CONTAINER" >/dev/null
elapsed=$(( $(date +%s) - start ))
exit_code=$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')

if ((elapsed <= 5)); then ok "shutdown completes quickly (${elapsed}s)"; else ko 'shutdown completes quickly' "${elapsed}s"; fi
check 'shutdown exit code is 0 (not SIGKILL)' '0' "$exit_code"

# -- Scenario 6: persistence across a restart -------------------------------
fingerprint_before=$(docker run --rm -v "${VOLUME}:/data" --entrypoint openssl "$IMAGE" \
  x509 -in /data/certs/localhost/fullchain.pem -noout -fingerprint 2>/dev/null)

docker start "$CONTAINER" >/dev/null
for _ in $(seq 1 30); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
fingerprint_after=$(docker exec "$CONTAINER" openssl x509 \
  -in /data/certs/localhost/fullchain.pem -noout -fingerprint 2>/dev/null)

check 'the certificate survives a restart' "$fingerprint_before" "$fingerprint_after"

if docker logs "$CONTAINER" 2>&1 | tail -40 | grep -q 'nothing to do'; then
  ok 'a valid certificate is not reissued on restart'
else
  ko 'a valid certificate is not reissued on restart' "$(docker logs "$CONTAINER" 2>&1 | tail -5)"
fi

# -- Result ------------------------------------------------------------------
printf '\n  %d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
