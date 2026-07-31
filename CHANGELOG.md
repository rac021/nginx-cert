# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.1] - 2026-07-31

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
- Buypass Go SSL removed from the provider table: it stopped issuing in October
  2025 and shut its ACME service down on 15 April 2026. Leaving it in the
  default chain cost every `auto` run a ~100 s connection timeout before moving
  on. The default `CERT_PROVIDER_CHAIN` is now
  `letsencrypt,zerossl,actalis,google`.
- A bind-mounted host directory on `/data` now reports the exact `chown`
  command to run, instead of only naming the expected uid.

### Added

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
