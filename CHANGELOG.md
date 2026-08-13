# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0] - 2026-08-13

### Changed

- **`redirect=` now works in both directions.** The map that decides where a
  plain-HTTP request goes was built by listing the certificates that had opted
  *out*, so with `CERT_HTTP_REDIRECT=false` the default was empty and a
  per-certificate `redirect=true` had nothing to turn back on: a site that
  asked for the redirect silently did not get it. The map now carries an entry
  for every certificate whose setting disagrees with the global default, in
  either direction -- which also keeps it to the lines that say something.

## [2.2.0] - 2026-08-13

Tagged, but no image was built for it: the CI run for this tag did not execute.
Everything below ships in 2.3.0.

Findings of a full audit of the 2.0.1 tree. Every item below was reproduced
against the built image before being fixed, and each one now has a test.

### Fixed

- **A failed renewal no longer replaces a working certificate.** The authority
  chain ends in the local self-signed authority, which cannot fail, so any
  transient outage — a firewall rule, a DNS blip, an appliance filtering the
  challenge — overwrote a valid, publicly trusted certificate with a local one
  and reported the run as `Renewed`. A production site went to a full-page
  browser warning because a certificate authority was unreachable for a minute.
  The local authority is now dropped from the chain whenever a trusted,
  unexpired certificate is in place: the run fails, says the certificate was
  kept, and retries later. First boots and expired certificates are still
  rescued exactly as before.
- **`certme issue <name>` no longer takes the other sites offline.** It
  narrowed the certificate list in place, and that same list is what the nginx
  configuration is rendered from — so renewing one certificate deleted every
  other site's server block and reloaded. Requests for those hosts were then
  answered by the surviving vhost, with the wrong certificate.
- **IP-address certificates reach a certificate authority.** The capability
  test knew `ip4`/`ip6` but was always called with the aggregate kind, `ip`, so
  every IP certificate was judged impossible to certify and never left the
  local authority — with a documented feature and an example built on top of it.
- **`CERT_SELFSIGNED_CA=false` produces a certificate.** It passed `-extfile`
  to `openssl req`, which has no such option, so the last resort of the chain
  could never issue anything.
- **The next tag cannot republish `latest`.** Omitting `latest` from the tag
  list is not enough: `docker/metadata-action` defaults to `latest=auto` and
  appends it for every non-prerelease semver tag. `flavor: latest=false` is
  what actually holds `latest` on the 1.x image.
- A certificate that expired less than a day ago reported `0` days left instead
  of `-1`, so the health probe stayed green while the site served an expired
  certificate.
- The base image's `default.conf` was never removed. nginx prefers an exact
  `server_name` match over `default_server`, so it captured every
  `Host: localhost` request on port 80: the stock welcome page instead of the
  redirect, and 404 on `/healthz` and on the ACME challenge.
- A conf.d that cannot be written no longer passes silently: the ACME server
  block carries `/healthz`, the redirect and the challenge, and its render
  failure was the only one in `nginx::render` that was ignored.
- Per-line options in `CERT_DOMAINS` are validated like their global
  counterparts. `provider=lestencrypt` fell through to the whole auto chain and
  `staging=ture` issued against production, both without a word, while the same
  typo in `CERT_PROVIDER` or `CERT_STAGING` stopped the container.
- `name=` goes through the same sanitiser as a derived name. Taken verbatim, it
  reached file paths: `name=../../evil` wrote outside the certificate directory.
- `CERT_RETRY_DELAY` and `CERT_DNS_SLEEP` accept a duration like every other
  time setting, and are validated. A unit suffix used to reach the arithmetic
  that doubles the delay and abort the run with a raw bash error, so the
  remaining authorities in the chain were never tried.
- Staging directories are cleaned up under the lock, not before taking it,
  where a second run could delete the directory the first was writing into.
- `docker stop` during the very first issuance took the whole grace period and
  ended in SIGKILL: the boot issuance ran in the foreground of PID 1, and bash
  does not run a trap while it waits on a foreground command.
- `CERT_MANAGE_NGINX=false` could not start at all, for two independent
  reasons: the generated servers use `$connection_upgrade`, whose `map` lived
  in the nginx.conf we no longer write, and a stock nginx.conf writes its pid
  to a directory uid 101 cannot write.
- The quota protection was inert in the default configuration. The failure
  counter was cleared by whichever authority finally succeeded — always the
  local one — so every boot fired a fresh request at an authority that had just
  refused.
- Leaving the staging environment never took effect. acme.sh keeps its own
  bookkeeping and skips what it believes is not due; its copy looks fresh, so
  it answered "skip" and the staging certificate stayed. It is now told to
  renew whenever our reason is one it cannot see: a changed name set, a
  self-signed certificate in place, or a staging environment we have left.
- A per-line `staging=true` was compared against the global `CERT_STAGING`, so
  the certificate was judged due for renewal on every scheduler run, forever.
- IPv6 names could not be certified: OpenSSL prints a SAN expanded and
  uppercase, the user writes it compressed, and the two were compared as
  strings. Not even a self-signed certificate passed verification.
- `*.test`, `*.lan` and other wildcards over a reserved TLD were rejected as
  invalid names and stopped the container, instead of being routed to the local
  authority. `*.com` stays invalid.
- A backup nobody checked is not a backup: an unwritable `/data/backups` was
  logged as a successful backup, and rollback then destroyed the live
  certificate to restore nothing. The backup is verified before anything is
  removed.
- An unopenable lock file was reported as "another operation is already
  running", so a read-only or wrongly-owned volume made every renewal fail
  forever with a message pointing at the wrong problem.
- `certme status --json` emitted `"days_left":0` where the value was unknown,
  and built its `domains` array by an unquoted expansion — which is also a
  glob, so a wildcard certificate was matched against the working directory.
- The per-attempt timeout branch never fired: it tested for 124, GNU coreutils'
  status, while BusyBox kills with SIGTERM and the shell reports 143.
- A DNS-01 failure was explained as a port-80 problem, because the generic
  `404` pattern was matched before the DNS-specific ones.
- `--dnssleep` was always passed, which replaces acme.sh's propagation polling
  with a blind fixed wait. It is now sent only when `CERT_DNS_SLEEP` is set.
- The default `CERT_RESOLVER` listed public DNS servers alongside Docker's.
  nginx queries them in turn, so a Compose service name periodically resolved
  to NXDOMAIN and the request failed with 502 for no visible reason.
- A private ACME server could not be used for internal names: they were
  filtered out as non-public before the overridden directory was ever
  consulted, which is exactly what `CERT_ACME_SERVER` is for.
- `CERT_UPSTREAM` was the only user value reaching the nginx configuration
  unchecked. A stray quote closed the generated string and injected directives;
  a typo in the port produced a 502 with nothing in the logs to explain it.
- The same domain declared by two certificates is now refused. nginx served
  only one of them and warned about a conflicting server name, while the other
  was issued and renewed forever without serving anyone.
- `CERT_RENEW_DAYS=030` was read as octal 24, and `08` was a fatal arithmetic
  error.
- JSON log mode emitted raw control characters, which no parser accepts —
  reachable through any acme.sh trace, which is full of colour codes.
- `docker run <image> renew`, the version-1 habit MIGRATION.md warns about, and
  any other unknown command silently started the whole server instead.
- A container whose nginx died cleanly exited 0, so `restart: on-failure` never
  fired.
- An install interrupted between its two renames left the previous certificate
  under `<name>.previous.<pid>` and nothing ever removed it.
- `ZeroSSL REST` had no sanity guard on its timeout, so an unparsable
  `CERT_ZEROSSL_TIMEOUT` became a zero budget: the order was placed and
  abandoned in the same breath.
- Publishing is now gated on the vulnerability scan, which used to run
  alongside the push rather than before it.
- The test runner deleted its shared temporary directory when the *first* test
  file returned, not when the run finished, so the suite silently depended on
  filename order — and a file that failed to source contributed no tests and no
  failure.
- `CERT_ACME_ARGS` split on whitespace and nothing else, so the escape hatch
  could not carry `--pre-hook "systemctl stop app"` — precisely the kind of
  option it exists for. It follows command-line quoting rules now, without
  shell evaluation: a `$(...)` reaches acme.sh as text rather than running
  while the configuration is read. Unbalanced quotes are reported instead of
  silently mangled.
- The lock's wait parameter could never succeed: it was implemented with
  `flock -w`, which BusyBox does not have, so asking to wait failed instantly
  with a usage error even when the lock was free.

Second pass over the same tree, same method:

- **`CERT_PROVIDER=selfsigned` stopped the container.** It speaks no ACME, so
  it has no line in `providers.tsv`, and the global existence check rejected it
  — while the error message listed it as available, the README documented it,
  `certme providers` showed it, and the removal notice for
  `CERT_SELF_SIGNED_CERTIFICATE` told the operator to switch to exactly that.
  Following our own migration advice ended in exit 2. The per-line
  `provider=selfsigned` always worked, which is why it went unnoticed.
- **`redirect=false` did nothing for a wildcard certificate.** An nginx `map`
  key is matched literally unless the block declares `hostnames`, so
  `*.example.com` only ever matched a `Host` header spelled exactly that way.
  Every host the wildcard actually serves kept being redirected.
- **`certme issue` exited 0 when it never ran.** Only `EX_BUSY` was propagated
  out of the lock, so an unopenable lock file — the read-only volume the
  previous pass taught it to *diagnose* — printed a summary of zeros and
  reported success. The scheduler's `certme issue || warn` never warned: a
  container that had stopped renewing altogether looked healthy until the
  certificate expired. `issue::all`'s "2 = nothing to renew" collides exactly
  with `EX_CONFIG`, so the run's own status no longer travels through the lock.
- **`CERT_SSL_POLICY` was inert with `CERT_MANAGE_NGINX=false`.** The TLS
  policy snippet was rendered to disk and included by nothing, so the generated
  servers ran on nginx's compiled-in defaults: `modern` still completed a TLS
  1.2 handshake, and `ssl_session_tickets off` and `ssl_early_data off` were
  never applied. It now travels through the same conf.d bridge as the maps.
- **An unparsable certificate silenced the CLI.** `certs::days_left` returns
  non-zero there, and a bare assignment under `set -e` ended the command on the
  spot: `certme status` truncated its table at that row with no message, and
  `certme health` — what the Docker `HEALTHCHECK` runs — exited 1 with no
  output at all, so the container went unhealthy with an empty reason. Both now
  name the certificate and carry on.
- **The quota backoff parked degraded sites for half a day.** It was guarded on
  "a certificate file exists", but `issue::ensure_placeholders` installs a local
  certificate for every declared name before any of this runs — so the "no
  certificate at all, try immediately" path was unreachable on the boot path. A
  single failed attempt left a site on an untrusted certificate for up to twelve
  hours. The exponential ceiling is now `CERT_FAILURE_COOLDOWN` rather than
  `CERT_FAILURE_COOLDOWN_MAX` whenever nothing trusted is serving: still a
  backoff, still restart-loop proof, but bounded by the base delay.
- **A run rescued by the local authority was reported as a success.** Every
  authority refused, the local one signed, and the summary said `Renewed 1 /
  Failed 0` in green with exit 0 — so anything keyed on that exit code was told
  the renewal had worked. Counted separately as `Untrusted` now, and the command
  exits `3`.
- **`util::split_into` expanded globs.** The unquoted expansion that does the
  splitting is also a pathname expansion, so parsing
  `CERT_DOMAINS='*.example.com'` from a directory holding `www.example.com`
  replaced the wildcard with the file names. Same defect the previous pass fixed
  in `certs::_json_domains`, on the main parsing path.
- **`certme revoke` addressed the wrong authority.** Which one actually issued
  is recorded on disk at install time and already drives the renewal decision;
  revoke read an in-process variable that is empty in every fresh process, then
  resolved `auto` to Let's Encrypt whatever had signed. A certificate from the
  local authority is now refused outright rather than announced, and sent, to a
  public CA with an empty `--server`.
- **`certme config` hid `CERT_ACME_SERVER`.** It replaces the directory URL of
  every authority in the chain, so a summary naming four authorities that would
  never be contacted described a run that was not going to happen.
- **Durations were validated in some places and not others.**
  `CERT_ACME_TIMEOUT`, `CERT_FAILURE_COOLDOWN`, `CERT_FAILURE_COOLDOWN_MAX`,
  `CERT_ZEROSSL_TIMEOUT` and `CERT_ZEROSSL_VALIDITY_DAYS` were read straight
  from the environment where they are consumed — which `lib/config.sh`'s own
  contract forbids — and fell silently back to their default on anything the
  parser rejected. `CERT_RETRY_DELAY=30min` stopped the container with a precise
  message; `CERT_FAILURE_COOLDOWN=30min` was ignored. All five go through
  `config::load` now, and a ceiling shorter than its base delay is refused.
- An expired certificate displayed `D--5`. It shows `-5d` — five days past
  expiry — and a certificate present but unparsable has its own `unreadable`
  state instead of ending the listing.
- `domain::_ipv4_is_private` declared only `IFS` local, so every name
  classification left two stray variables in the global scope.

Third pass, on the three items the second one had seen but not investigated:

- **One authority's EAB credentials were sent to every other.** `CERT_EAB_KID`
  and `CERT_EAB_HMAC_KEY` went to whichever authority was being contacted,
  whatever `providers.tsv` said it needed — so in `auto` mode a KID issued by
  HARICA was offered to Let's Encrypt, first in the default chain. Measured
  against the staging environment, Boulder accepts the account and ignores the
  field, which is exactly why nothing ever surfaced; RFC 8555 does not oblige
  every server to be that tolerant, and an authority that did not ask for a
  credential has no business receiving one. They now go only to authorities
  that declare `eab: required` — and, unchanged, to a directory overridden with
  `CERT_ACME_SERVER`, where the table describes a server we are not talking to.
- **`CERT_PROVIDER_CHAIN` was not checked at startup.** A typo surfaced as a
  warning from the middle of a run, once per certificate, while the same typo
  in `CERT_PROVIDER` stopped the container. It is reported once at load now.
  Deliberately not fatal per entry — retired authorities are removed from
  `providers.tsv` rather than left to time out, so a newer image must not refuse
  to start over a name that has simply gone — but a chain naming nothing that
  exists is refused, because it silently reduces every certificate to the local
  authority. Listing `selfsigned` there is refused too, with the setting that
  actually controls it.
- **A per-certificate option could not carry a space, or a `;`.** Options were
  split on whitespace and nothing else, and `;` separates certificates as well
  as HSTS directives — so `hsts="max-age=63072000; includeSubDomains"`, the
  spelling RFC 6797 uses, was cut in half and its remainder parsed as a second
  certificate. `includeSubDomains` was reachable only through the global
  `CERT_HSTS`. Option values may now be quoted, with command-line quoting rules
  and no evaluation, the same treatment `CERT_ACME_ARGS` already had; unbalanced
  quotes are reported instead of silently mangled.
- An HSTS value is emitted inside a quoted nginx directive and was never
  checked, so a double quote closed the string early and everything after it
  became configuration — the hole `config::valid_upstream` was added to close,
  made easier to reach by quoted option values.
- **`config::load` was not idempotent.** Only `NC_SPEC_NAMES` was cleared, so
  the per-certificate maps kept their previous contents and a second load in the
  same process died on its own leftovers with "two certificates share the same
  name" — a configuration problem the operator does not have. No shipped path
  loads twice, which is what made it a trap rather than a bug.

### Added

- `renew_days=` per certificate. The renewal threshold only means something
  relative to a lifetime: 30 days is right for a 90-day certificate and absurd
  for a 160-hour one, and a single container can legitimately hold both.
- `redirect=` per certificate now works. It was parsed, stored, and read by
  nothing at all.

### Changed

- `CERT_RETRY_DELAY` and `CERT_DNS_SLEEP` accept a duration (`30s`, `2m`) like
  every other time setting. Plain seconds still work.
- `CERT_RESOLVER` defaults to `127.0.0.11` alone.
- Documentation and examples corrected where they described behaviour the code
  did not have: the ZeroSSL REST path for IP addresses, SSL.com's EAB
  requirement, HARICA's certificate lifetime, the `certme status --json`
  wrapper, the wildcard lineage name, the `CERT_POST_HOOK` example (which lost
  its variable to Compose interpolation and called a binary the image does not
  have), the read-only `conf.d` mount in the load-balancer example, and the
  private-CA example's trust-store mount, which was a no-op.

## [2.0.1] - 2026-08-01

### Published as

`rac021/nginx-cert:v2` (latest 2.x) and `rac021/nginx-cert:v2.0.1` (pinned),
for linux/amd64 and linux/arm64. `:2`, `:2.0` and `:2.0.1` point at the same
images.

`latest` continues to serve the 1.x image and will not be moved: deployments
that pull the repository without a tag must not receive a major version with
breaking changes.

### Fixed

- `/healthz` and the HTTP-to-HTTPS redirect disappeared when `CERT_ENABLE=false`,
  because the whole ACME server block was skipped. The Docker `HEALTHCHECK`
  polls `/healthz`, so a container with certificate management disabled could
  never become healthy.
- `CERT_ACME_SERVER` dropped the configured EAB credentials. It decided whether
  to send them from the provider table, so carrying a custom directory on
  `letsencrypt` — the documented way — meant the server answered
  `externalAccountRequired`. Explicit credentials now always win, and the
  authority is named by the host actually contacted.
- SSL.com was declared as requiring EAB, which silently removed it from every
  chain. Its directory advertises `externalAccountRequired: false`; an account
  with a billing profile is what it actually needs, and the notes now say so.
- A provider named explicitly in `CERT_PROVIDER` that gets filtered out of the
  chain -- wrong name kind, missing EAB -- is now reported as a warning rather
  than at debug level. The run otherwise ended on a self-signed certificate
  with no visible reason.
- Failure hints told operators to check their firewall when an authority had in
  fact refused to create the ACME account. The two share the `unauthorized`
  code and share no remedy.
- Buypass Go SSL removed from the provider table: it stopped issuing in October
  2025 and shut its ACME service down on 15 April 2026. Leaving it in the
  default chain cost every `auto` run a ~100 s connection timeout before moving
  on. The default `CERT_PROVIDER_CHAIN` is now
  `letsencrypt,zerossl,actalis,google`.
- A bind-mounted host directory on `/data` now reports the exact `chown`
  command to run, instead of only naming the expected uid.

### Added

- Console output redesigned: a coloured badge per severity (`[ ok ]` green,
  `[info]` blue, `[warn]` orange, `[FAIL]` red), indented `->` lines for
  remedies, `|` for quoted third-party output, coloured section rules, and a
  state column in `certme status` that turns red when a certificate has
  expired. Colour is never the only carrier of meaning, and `auto` now colours
  a pipe as well as a terminal so that `docker logs` is coloured while a
  redirection to a file stays clean.
- **Certum** (European CA, free tier) and **Sectigo** (commercial, and how
  InCommon members are provisioned) added to the provider table.
- **HARICA** as a first-class provider (`CERT_PROVIDER=harica`). It is the
  authority behind GÉANT TCS, so certificates are free for members of the
  European research networks (RENATER, SURF, DFN, Belnet). On a filtered
  corporate network it has a practical advantage: validation comes from
  HARICA's servers rather than a well-known public validator.
- Failure hints distinguish a connection **reset** — a firewall, WAF or IPS on
  the path filtering validation traffic — from a **refused** connection, i.e. a
  closed port. The reset hint includes a one-line command that reproduces the
  filtering from outside, because the two look identical in an ACME trace.
- Unknown and removed `CERT_*` environment variables are reported at startup
  instead of being silently ignored.
- A certificate issued by a staging environment is re-issued as soon as
  `CERT_STAGING` is turned off.

## [2.0.0] - 2026-07-31

Complete rewrite. See [MIGRATION.md](MIGRATION.md) for the upgrade path.

### Added

- **Single ACME driver** covering Let's Encrypt, ZeroSSL, Actalis,
  Google Trust Services and SSL.com. Authorities are declared in
  `providers/providers.tsv`; adding one is adding a table row.
- **Actalis support**, including External Account Binding.
- **Automatic fallback chain.** In `auto` mode each authority is tried
  `CERT_ATTEMPTS` times with exponential backoff before moving to the next, and
  a locally-signed certificate closes the chain so the service always starts.
- **Multiple certificates per container.** `CERT_DOMAINS` accepts one
  certificate per line, each with its own options (`upstream=`, `provider=`,
  `dns=`, `hsts=`, …).
- **Generated HTTPS servers.** One hardened server per certificate, with
  `proxy_pass` to `CERT_UPSTREAM`, HSTS, HTTP/2 and optional HTTP/3.
- **DNS-01 challenge and wildcard certificates**, through acme.sh's ~150 DNS
  modules.
- **ZeroSSL EAB derivation** from an existing API key, cached locally.
- **`certme` CLI**: `status` (text and JSON), `issue`, `renew`, `list`,
  `providers`, `config`, `render`, `check`, `reload`, `revoke`, `health`,
  `version`.
- **Local certificate authority** for development: import
  `/data/ca/rootCA.pem` once and every local certificate is trusted.
- **Docker `HEALTHCHECK`** covering both nginx liveness and certificate expiry.
- **Atomic installation with rollback**: a certificate is verified (key match,
  full chain, SAN coverage, validity window) before replacing the live one, and
  the previous one is restored if `nginx -t` fails.
- **Failure backoff** so a container in a restart loop cannot exhaust an
  authority's rate limit.
- **Structured logging** with levels, timestamps and optional JSON output.
- **Test suite**: 78 dependency-free unit tests plus Docker integration tests,
  `shellcheck` and `hadolint` in CI.
- **CI**: multi-architecture build (amd64, arm64), immutable version tags, build
  cache, SBOM, provenance attestation and Trivy scanning.

### Changed

- Base image `nginx:1.27.2-alpine-slim` → `nginx:1.30-alpine-slim`.
- ACME client: certbot → acme.sh. Image size 97 MB → 26 MB.
- The container runs as `nginx` (uid 101) with `CAP_NET_BIND_SERVICE`, not root.
- Certificates moved from `/etc/letsencrypt/live/<domain>/` to
  `/data/certs/<name>/`; a single volume on `/data` holds all state.
- The renewal scheduler is a supervised loop with jitter instead of a BusyBox
  crontab; `CERT_CRON_SCHEDULE` is replaced by `CERT_RENEW_INTERVAL`.
- The ACME challenge is served from a webroot instead of being proxied to a
  standalone client on a high port; `CERT_PROXY_PASS_PORT` is gone.
- nginx configuration is regenerated from templates and validated with
  `nginx -t` before use, instead of being patched in place with `sed`.
- TLS defaults hardened: TLS 1.2/1.3, Mozilla intermediate cipher suite, session
  cache without tickets, OCSP stapling, HSTS, `server_tokens off`.
- `CERT_ENABLE` now defaults to `true`, `CERT_STAGING` to `false`.
- Self-signed certificates use ECDSA P-256 with proper SANs (including IP and
  loopback entries) instead of RSA-2048 with a CN only.

### Fixed

- **Renewal failures were reported as successes.** The success test read the
  exit status of `tee` rather than the ACME client's, so the retry loop never
  retried and expiry could go unnoticed.
- **Renewal always failed on container restart.** Issuance ran before nginx was
  started, so nothing was listening on port 80 to answer the HTTP-01 challenge.
- **Multi-domain certificates were re-issued on every start and every nightly
  run**, because the lineage-detection check looked for a directory the ACME
  client never creates — a direct path to a Let's Encrypt rate-limit block.
- **ZeroSSL renewal validation always returned 404.** The nginx location used
  `alias` where `root` was required, so the validation file was looked up one
  directory too high.
- **ZeroSSL `fullchain.pem` contained only the leaf certificate**, breaking
  chain validation for any client without a cached intermediate.
- **`docker stop` never shut down gracefully.** SIGTERM was not forwarded to
  nginx, which was SIGKILLed after the grace period (exit 137), cutting every
  in-flight connection.
- **Private keys were world-readable and world-writable.** `chmod -R 666` on the
  certificate tree also stripped the execute bit from directories, which is why
  the container had to run as root.
- **The ZeroSSL API key was printed in clear text** in the startup summary.
- Self-signed certificates had no `subjectAltName` and were therefore rejected
  by modern browsers and TLS libraries.
- The certificate lock file was deleted unconditionally, and there was no
  application-level lock between the scheduler and manual runs.
- `CERT_PROXY_PASS_PORT` was only substituted into one of the two shipped nginx
  configuration files, so changing it silently broke renewal.
- The CI workflow ran on pull requests with secrets it could not access, and
  published a single mutable `latest` tag.

### Removed

- certbot, BusyBox cron, and the standalone Python HTTP server used for ZeroSSL
  validation.
- `CERT_PROXY_PASS_PORT`, `CERT_CRON_SCHEDULE`, `CERT_SELF_SIGNED_CERTIFICATE`
  (replaced by `CERT_PROVIDER=selfsigned`).
- `/opt/certme/renew.info`: all output now goes to the container's logs.

## [1.x]

Initial versions. See the Git history.
