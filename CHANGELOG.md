# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
