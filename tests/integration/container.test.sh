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

# -- Scenario 2b: the health endpoint survives CERT_ENABLE=false -------------
# The HEALTHCHECK polls /healthz. When the ACME server block was only rendered
# with certificate management enabled, a container with CERT_ENABLE=false could
# never become healthy.
docker rm -f "${CONTAINER}-noacme" >/dev/null 2>&1
docker run -d --name "${CONTAINER}-noacme" -p 18081:80 -e CERT_ENABLE=false "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
  docker logs "${CONTAINER}-noacme" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18081/healthz")
check '/healthz answers even with CERT_ENABLE=false' '200' "$code"
if docker exec "${CONTAINER}-noacme" certme health >/dev/null 2>&1; then
  ok 'certme health passes with CERT_ENABLE=false'
else
  ko 'certme health passes with CERT_ENABLE=false'
fi
docker rm -f "${CONTAINER}-noacme" >/dev/null 2>&1

# -- Scenario 2c: a bind mount the container cannot write to -----------------
# Naming the expected uid is not enough; the message must give the fix.
bindpath=$(mktemp -d)
chmod 700 "$bindpath"
out=$(docker run --rm --user 65534:65534 -v "${bindpath}:/data" \
        -e CERT_DOMAINS=example.com -e CERT_EMAIL=a@b.co "$IMAGE" 2>&1); rc=$?
check 'an unwritable /data exits with code 2' '2' "$rc"
if [[ $out == *'chown -R'* && $out == *'named volume'* ]]; then
  ok 'the message gives the chown command and the volume alternative'
else
  ko 'the message gives the chown command and the volume alternative' "$out"
fi
rm -rf "$bindpath"

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

# -- Scenario 4b: shutdown leaves no alert in the logs ----------------------
# nginx could write its pid file but not unlink it, because removing a file
# needs write permission on the directory, not on the file. Every stop ended
# with an [alert].
docker rm -f "${CONTAINER}-pid" >/dev/null 2>&1
docker run -d --name "${CONTAINER}-pid" -p 18082:80 -e CERT_DOMAINS=localhost "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
  docker logs "${CONTAINER}-pid" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
docker stop "${CONTAINER}-pid" >/dev/null
if docker logs "${CONTAINER}-pid" 2>&1 | grep -q 'unlink().*nginx.pid.*failed'; then
  ko 'shutdown leaves no pid-file alert' "$(docker logs "${CONTAINER}-pid" 2>&1 | grep 'unlink()' | head -1)"
else
  ok 'shutdown leaves no pid-file alert'
fi
docker rm -f "${CONTAINER}-pid" >/dev/null 2>&1

# -- Scenario 4c: the run summary actually reaches the operator --------------
# Releasing the lock used to attach a redirection to a bare "exec", which
# applies it to the shell for the rest of the process. Everything logged after
# that point -- the summary, and any failure reported once the lock was gone --
# was written to /dev/null.
renew_out=$(docker exec "$CONTAINER" certme renew --force 2>&1)
if [[ $renew_out == *'Summary'* && $renew_out == *'Renewed'* ]]; then
  ok 'a renewal prints its summary'
else
  ko 'a renewal prints its summary' "$renew_out"
fi

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

# -- Scenario 7: an authority outage must not downgrade a working certificate -
#
# The one that mattered most: the chain ends in the local authority, which
# cannot fail, so a thirty-second outage used to replace a valid publicly
# trusted certificate with a self-signed one -- and report "Renewed".
cleanup
docker volume create "$VOLUME" >/dev/null

# Stand in for a real authority: a separate CA, so issuer != subject and the
# certificate does not look self-signed.
docker run --rm --network none -v "${VOLUME}:/data" --entrypoint /bin/bash "$IMAGE" -c '
  set -e
  d=/data/certs/downgrade.example.com; mkdir -p "$d"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/ca.key -out /tmp/ca.pem \
    -days 60 -subj "/O=Test Public CA/CN=Test Public CA R1" 2>/dev/null
  openssl req -new -newkey rsa:2048 -nodes -keyout "$d/privkey.pem" -out /tmp/csr \
    -subj "/CN=downgrade.example.com" 2>/dev/null
  printf "subjectAltName=DNS:downgrade.example.com\n" > /tmp/ext
  openssl x509 -req -in /tmp/csr -CA /tmp/ca.pem -CAkey /tmp/ca.key -CAcreateserial \
    -out "$d/cert.pem" -days 40 -sha256 -extfile /tmp/ext 2>/dev/null
  cp /tmp/ca.pem "$d/chain.pem"; cat "$d/cert.pem" "$d/chain.pem" > "$d/fullchain.pem"
  chmod 600 "$d/privkey.pem"' >/dev/null

issuer_before=$(docker run --rm -v "${VOLUME}:/data" --entrypoint openssl "$IMAGE" \
  x509 -in /data/certs/downgrade.example.com/fullchain.pem -noout -issuer 2>/dev/null)

# CERT_RENEW_DAYS above the remaining lifetime makes the renewal due; --network
# none makes every authority fail.
out=$(docker run --rm --network none -v "${VOLUME}:/data" \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='downgrade.example.com' \
  -e CERT_RENEW_DAYS=60 -e CERT_ATTEMPTS=1 -e CERT_ACME_TIMEOUT=8s \
  --entrypoint /opt/nginx-cert/bin/certme "$IMAGE" issue 2>&1); rc=$?

issuer_after=$(docker run --rm -v "${VOLUME}:/data" --entrypoint openssl "$IMAGE" \
  x509 -in /data/certs/downgrade.example.com/fullchain.pem -noout -issuer 2>/dev/null)

check 'a failed renewal leaves the trusted certificate in place' "$issuer_before" "$issuer_after"
check 'a failed renewal is reported as a failure, not a renewal' '3' "$rc"
if [[ $out == *'is kept and still trusted'* ]]; then
  ok 'the run says the certificate was kept'
else
  ko 'the run says the certificate was kept' "$out"
fi

# The same outage with no certificate at all must still fall back locally:
# that is what the local authority is for.
docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
docker volume create "$VOLUME" >/dev/null
docker run --rm --network none -v "${VOLUME}:/data" \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='fresh.example.com' \
  -e CERT_ATTEMPTS=1 -e CERT_ACME_TIMEOUT=8s \
  --entrypoint /opt/nginx-cert/bin/certme "$IMAGE" issue >/dev/null 2>&1
if docker run --rm -v "${VOLUME}:/data" --entrypoint test "$IMAGE" \
     -s /data/certs/fresh.example.com/fullchain.pem; then
  ok 'with no certificate at all, the local authority still rescues the boot'
else
  ko 'with no certificate at all, the local authority still rescues the boot'
fi

# -- Scenario 8: issuing one certificate must not disturb the others ---------
cleanup
docker volume create "$VOLUME" >/dev/null
out=$(docker run --rm --network none -v "${VOLUME}:/data" \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS=$'one.test | upstream=x:80\ntwo.test | upstream=y:80' \
  --entrypoint /bin/bash "$IMAGE" -c '
    B=/opt/nginx-cert/bin/certme
    $B issue >/dev/null 2>&1; $B render >/dev/null 2>&1
    $B issue one.test --force >/dev/null 2>&1
    ls /etc/nginx/conf.d/ | grep -c "^nginx-cert\..*two.test"' 2>&1)
check 'issuing one certificate keeps the other sites served' '1' "$(printf '%s' "$out" | tail -1)"

# -- Scenario 9: CERT_SELFSIGNED_CA=false actually produces a certificate ----
if docker run --rm --network none -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='nossca.test' \
     -e CERT_SELFSIGNED_CA=false --entrypoint /bin/bash "$IMAGE" \
     -c '/opt/nginx-cert/bin/certme issue >/dev/null 2>&1
         openssl x509 -in /data/certs/nossca.test/fullchain.pem -noout -ext subjectAltName' \
     2>/dev/null | grep -q 'DNS:nossca.test'; then
  ok 'CERT_SELFSIGNED_CA=false issues a certificate carrying its SAN'
else
  ko 'CERT_SELFSIGNED_CA=false issues a certificate carrying its SAN'
fi

# -- Scenario 10: the base image's default server must not shadow ours -------
#
# nginx prefers an exact server_name match over default_server, so the stock
# "server_name localhost" block captured every Host: localhost request on port
# 80 -- the welcome page instead of the redirect, 404 on /healthz and on the
# ACME challenge.
cleanup
docker run -d --name "$CONTAINER" --network none \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='localhost | upstream=app:8080' \
  "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: localhost' http://127.0.0.1/healthz 2>/dev/null)
check 'Host: localhost reaches /healthz, not the stock welcome page' '200' "$code"
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: localhost' http://127.0.0.1/ 2>/dev/null)
check 'Host: localhost is redirected to HTTPS' '308' "$code"

# -- Scenario 11: docker stop during the very first issuance ----------------
#
# The boot issuance ran in the foreground of PID 1, and bash does not run a
# trap while it waits on a foreground command: "docker stop" sat out the whole
# grace period and ended in SIGKILL, cutting every in-flight request.
cleanup
docker run -d --name "$CONTAINER" --network none \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='slow-boot.example.com' \
  -e CERT_ATTEMPTS=3 -e CERT_ACME_TIMEOUT=60s "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'Attempt 1/3' && break
  sleep 1
done
start=$(date +%s)
docker stop -t 45 "$CONTAINER" >/dev/null
elapsed=$(( $(date +%s) - start ))
exit_code=$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')
if ((elapsed <= 10)); then
  ok "shutdown during issuance is prompt (${elapsed}s)"
else
  ko 'shutdown during issuance is prompt' "${elapsed}s"
fi
check 'shutdown during issuance exits 0, not SIGKILL' '0' "$exit_code"

# -- Scenario 12: CERT_MANAGE_NGINX=false is a working mode ------------------
#
# Two independent reasons it could not start: the generated server blocks use
# $connection_upgrade, whose map lived in the nginx.conf we no longer write;
# and a stock nginx.conf writes its pid to /var/run/nginx.pid, in a directory
# uid 101 cannot write.
cleanup
userconf=$(mktemp)
cat >"$userconf" <<'CONF'
worker_processes auto;
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
CONF
# mktemp creates it 0600, and the container reads it as uid 101.
chmod 644 "$userconf"
docker run -d --name "$CONTAINER" --network none \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='unmanaged.test | upstream=app:8080' \
  -e CERT_MANAGE_NGINX=false -v "${userconf}:/etc/nginx/nginx.conf:ro" "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
rm -f "$userconf"
check 'the container starts with CERT_MANAGE_NGINX=false' 'running' \
  "$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
if docker logs "$CONTAINER" 2>&1 | grep -qi 'emerg'; then
  ko 'no emergency in the log with an unmanaged nginx.conf' \
     "$(docker logs "$CONTAINER" 2>&1 | grep -i emerg | head -2)"
else
  ok 'no emergency in the log with an unmanaged nginx.conf'
fi

# The TLS policy travels through the same conf.d bridge as the maps. It used to
# be rendered to disk and included by nothing, so the generated servers ran on
# nginx's compiled-in defaults: CERT_SSL_POLICY=modern still completed a TLS 1.2
# handshake, and ssl_session_tickets / ssl_early_data were never turned off.
if docker exec "$CONTAINER" openssl s_client -connect 127.0.0.1:443 -tls1_2 \
     -servername unmanaged.test </dev/null 2>&1 | grep -q 'Protocol *: *TLSv1.2'; then
  ok 'the default policy accepts TLS 1.2 with an unmanaged nginx.conf'
else
  ko 'the default policy accepts TLS 1.2 with an unmanaged nginx.conf'
fi
docker rm -f "${CONTAINER}-modern" >/dev/null 2>&1
userconf=$(mktemp)
cat >"$userconf" <<'CONF'
worker_processes auto;
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
CONF
chmod 644 "$userconf"
docker run -d --name "${CONTAINER}-modern" --network none \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='modern.test' \
  -e CERT_MANAGE_NGINX=false -e CERT_SSL_POLICY=modern \
  -v "${userconf}:/etc/nginx/nginx.conf:ro" "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "${CONTAINER}-modern" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
rm -f "$userconf"
if docker exec "${CONTAINER}-modern" openssl s_client -connect 127.0.0.1:443 -tls1_2 \
     -servername modern.test </dev/null 2>&1 | grep -q 'Protocol *: *TLSv1.2'; then
  ko 'CERT_SSL_POLICY=modern refuses TLS 1.2 with an unmanaged nginx.conf' \
     'the handshake succeeded, so the TLS policy snippet is not in effect'
else
  ok 'CERT_SSL_POLICY=modern refuses TLS 1.2 with an unmanaged nginx.conf'
fi
if docker exec "${CONTAINER}-modern" openssl s_client -connect 127.0.0.1:443 -tls1_3 \
     -servername modern.test </dev/null 2>&1 | grep -q 'Protocol *: *TLSv1.3'; then
  ok 'and still serves TLS 1.3'
else
  ko 'and still serves TLS 1.3'
fi
docker rm -f "${CONTAINER}-modern" >/dev/null 2>&1

# -- Scenario 13: the per-certificate redirect= option is honoured -----------
cleanup
docker run -d --name "$CONTAINER" --network none -e CERT_EMAIL='a@b.co' \
  -e CERT_DOMAINS=$'keep.test | upstream=app:8080\nplain.test | upstream=app:8080 redirect=false\n*.wild.test | upstream=app:8080 redirect=false' \
  "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: keep.test' http://127.0.0.1/ 2>/dev/null)
check 'a certificate without the option still redirects to HTTPS' '308' "$code"
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: plain.test' http://127.0.0.1/ 2>/dev/null)
check 'redirect=false stops the redirect for that certificate only' '200' "$code"

# A map key is matched literally unless the block declares "hostnames", so
# "*.wild.test" only ever matched a Host header spelled exactly that way:
# redirect=false silently did nothing for every wildcard certificate.
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: app.wild.test' http://127.0.0.1/ 2>/dev/null)
check 'redirect=false covers the hosts a wildcard certificate matches' '200' "$code"
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: deep.sub.wild.test' http://127.0.0.1/ 2>/dev/null)
check 'and does so at any depth under the wildcard' '200' "$code"
# The opt-out must stay an opt-out: an unrelated host still gets the redirect.
code=$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: elsewhere.example.com' http://127.0.0.1/ 2>/dev/null)
check 'a host outside the opt-out list still redirects' '308' "$code"

# -- Scenario 14: an invalid upstream is refused before nginx sees it --------
out=$(docker run --rm -e CERT_DOMAINS='example.com' -e CERT_EMAIL='a@b.co' \
        -e CERT_UPSTREAM='app:8080"; return 444; #' "$IMAGE" 2>&1); rc=$?
check 'an upstream that would inject nginx directives exits with code 2' '2' "$rc"
if [[ $out == *'CERT_UPSTREAM'* ]]; then
  ok 'the error names CERT_UPSTREAM'
else
  ko 'the error names CERT_UPSTREAM' "$out"
fi

# -- Scenario 15: an unknown command is an error, not a silent server start --
out=$(docker run --rm -e CERT_ENABLE=false "$IMAGE" renew 2>&1); rc=$?
check 'docker run <image> renew exits with code 2' '2' "$rc"
if [[ $out == *'certme'* ]]; then
  ok 'the error points at "certme renew"'
else
  ko 'the error points at "certme renew"' "$out"
fi

# -- Scenario 16: CERT_PROVIDER=selfsigned is a supported configuration -------
#
# It has no line in providers.tsv because it speaks no ACME, so the existence
# check rejected it -- while "certme providers" listed it, the README
# documented it, and the removal notice for CERT_SELF_SIGNED_CERTIFICATE told
# the operator to switch to exactly this. Following that advice stopped the
# container with exit 2.
cleanup
docker run -d --name "$CONTAINER" --network none \
  -e CERT_PROVIDER=selfsigned -e CERT_DOMAINS='pinned.example.com' "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
check 'CERT_PROVIDER=selfsigned starts the container' 'running' \
  "$(docker inspect "$CONTAINER" --format '{{.State.Status}}')"
# A public name pinned to the local authority must not reach out either.
if docker logs "$CONTAINER" 2>&1 | grep -q "Let's Encrypt"; then
  ko 'CERT_PROVIDER=selfsigned contacts no authority' \
     "$(docker logs "$CONTAINER" 2>&1 | grep -m1 "Let's Encrypt")"
else
  ok 'CERT_PROVIDER=selfsigned contacts no authority'
fi
out=$(docker run --rm --network none -e CERT_PROVIDER=selfsignd \
        -e CERT_DOMAINS='typo.example.com' "$IMAGE" 2>&1); rc=$?
check 'a misspelt provider is still refused' '2' "$rc"

# -- Scenario 17: a lock that cannot be taken is not a successful run ---------
#
# Only EX_BUSY was propagated, so an unopenable lock file -- a read-only
# volume, a directory owned by someone else -- printed a summary of zeros and
# exited 0. The scheduler's "certme issue || warn" never warned, and a
# container that had stopped renewing altogether reported success.
docker exec -u root "$CONTAINER" sh -c \
  'rm -f /data/state/nginx-cert.lock && install -o root -g root -m 0600 /dev/null /data/state/nginx-cert.lock'
out=$(docker exec "$CONTAINER" certme issue 2>&1); rc=$?
check 'an unopenable lock file exits with code 2, not 0' '2' "$rc"
if [[ $out == *'lock file'* ]]; then
  ok 'the message names the lock file'
else
  ko 'the message names the lock file' "$out"
fi
docker exec -u root "$CONTAINER" rm -f /data/state/nginx-cert.lock

# -- Scenario 18: a certificate on disk that cannot be parsed ----------------
#
# certs::days_left returns non-zero there, and a bare assignment under "set -e"
# ended the command on the spot: the status table stopped at that row with no
# message, and the health probe -- which the Docker HEALTHCHECK runs -- exited 1
# with no output at all.
cleanup
docker run -d --name "$CONTAINER" --network none -e CERT_EMAIL='a@b.co' \
  -e CERT_DOMAINS=$'first.test\nbroken.test\nlast.test' "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
docker exec "$CONTAINER" sh -c 'printf "garbage\n" > /data/certs/broken.test/fullchain.pem'
status_out=$(docker exec "$CONTAINER" certme status 2>&1)
if [[ $status_out == *'last.test'* ]]; then
  ok 'certme status keeps listing the certificates after a broken one'
else
  ko 'certme status keeps listing the certificates after a broken one' "$status_out"
fi
if [[ $status_out == *'unreadable'* ]]; then
  ok 'certme status names the broken certificate as unreadable'
else
  ko 'certme status names the broken certificate as unreadable' "$status_out"
fi
health_out=$(docker exec "$CONTAINER" certme health 2>&1); rc=$?
check 'certme health fails on an unreadable certificate' '1' "$rc"
if [[ $health_out == *'broken.test'* ]]; then
  ok 'certme health says which certificate is unreadable'
else
  ko 'certme health says which certificate is unreadable' "(no output: '${health_out}')"
fi

# -- Scenario 19: a run rescued by the local authority is not a success -------
#
# Every authority refused and the local one signed instead: the summary said
# "Renewed 1 / Failed 0" in green and the command exited 0, so anything keyed
# on that exit code was told the renewal had worked.
cleanup
docker volume create "$VOLUME" >/dev/null
out=$(docker run --rm --network none -v "${VOLUME}:/data" \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='rescued.example.com' \
  -e CERT_ATTEMPTS=1 -e CERT_ACME_TIMEOUT=8s \
  --entrypoint /opt/nginx-cert/bin/certme "$IMAGE" issue 2>&1); rc=$?
check 'falling back to the local authority exits 3, not 0' '3' "$rc"
if [[ $out == *'Untrusted'*'rescued.example.com'* ]]; then
  ok 'the summary counts it as untrusted, not as renewed'
else
  ko 'the summary counts it as untrusted, not as renewed' "$out"
fi
# The certificate is still installed: the point is to keep the service up.
if docker run --rm -v "${VOLUME}:/data" --entrypoint test "$IMAGE" \
     -s /data/certs/rescued.example.com/fullchain.pem; then
  ok 'the rescue certificate is still installed'
else
  ko 'the rescue certificate is still installed'
fi

# A local certificate has no issuing authority to revoke it with, and "auto"
# used to be resolved to Let's Encrypt whatever had actually signed.
out=$(docker run --rm --network none -v "${VOLUME}:/data" \
  -e CERT_EMAIL='a@b.co' -e CERT_DOMAINS='rescued.example.com' \
  --entrypoint /opt/nginx-cert/bin/certme "$IMAGE" revoke rescued.example.com 2>&1); rc=$?
check 'revoking a local certificate is refused, not sent to a public CA' '2' "$rc"
if [[ $out != *"Let's Encrypt"* ]]; then
  ok 'and no authority is named that did not issue it'
else
  ko 'and no authority is named that did not issue it' "$out"
fi

# -- Scenario 20: a quoted option value reaches the response header ----------
#
# ";" separates certificates and also separates HSTS directives, so
# "max-age=63072000; includeSubDomains" -- the spelling RFC 6797 uses -- was cut
# in half and its remainder parsed as a second certificate. includeSubDomains
# was unreachable per certificate.
cleanup
docker run -d --name "$CONTAINER" --network none -e CERT_EMAIL='a@b.co' \
  -e CERT_DOMAINS='hsts.test | hsts="max-age=63072000; includeSubDomains"' \
  "$IMAGE" >/dev/null
for _ in $(seq 1 40); do
  docker logs "$CONTAINER" 2>&1 | grep -q 'nginx-cert is up' && break
  sleep 1
done
count=$(docker exec "$CONTAINER" certme list 2>/dev/null | grep -c .)
check 'a quoted semicolon does not start a second certificate' '1' "$count"
hdr=$(docker exec "$CONTAINER" curl -sk -o /dev/null -D - -H 'Host: hsts.test' \
        https://127.0.0.1/ 2>/dev/null | grep -i 'strict-transport-security')
if [[ $hdr == *'max-age=63072000'* && $hdr == *'includeSubDomains'* ]]; then
  ok 'the whole HSTS value reaches the response header'
else
  ko 'the whole HSTS value reaches the response header' "${hdr:-no Strict-Transport-Security header}"
fi

out=$(docker run --rm --network none -e CERT_EMAIL='a@b.co' \
        -e CERT_DOMAINS='q.test | hsts="never closed' "$IMAGE" 2>&1); rc=$?
check 'unbalanced quotes in an option exit with code 2' '2' "$rc"

# -- Scenario 21: a typo in CERT_PROVIDER_CHAIN is reported at startup -------
#
# It used to surface only from provider::chain_for, once per certificate, in
# the middle of a run -- while the same typo in CERT_PROVIDER stopped the
# container. Not fatal per entry: retired authorities are removed from
# providers.tsv, so a newer image must not refuse to start over a name that has
# simply gone.
out=$(docker run --rm --network none -e CERT_EMAIL='a@b.co' \
        -e CERT_DOMAINS='chain.test' -e CERT_PROVIDER_CHAIN='letsencrypt,buypass' \
        --entrypoint /opt/nginx-cert/bin/certme "$IMAGE" config 2>&1); rc=$?
check 'an unknown authority in the chain does not stop the container' '0' "$rc"
if [[ $out == *'buypass'* && $out == *'CERT_PROVIDER_CHAIN'* ]]; then
  ok 'and is named once, at startup'
else
  ko 'and is named once, at startup' "$out"
fi
out=$(docker run --rm --network none -e CERT_EMAIL='a@b.co' \
        -e CERT_DOMAINS='chain.test' -e CERT_PROVIDER_CHAIN='nope,nada' "$IMAGE" 2>&1); rc=$?
check 'a chain naming no known authority exits with code 2' '2' "$rc"

# -- Result ------------------------------------------------------------------
printf '\n  %d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
