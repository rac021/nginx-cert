# nginx-cert

nginx with automatic TLS certificates. One container, one variable, HTTPS.

Certificates are issued and renewed automatically from **Let's Encrypt, ZeroSSL,
Actalis, Buypass, Google Trust Services or SSL.com** — all through one ACME
driver. If an authority is unavailable, the next one in the chain is tried, and
a locally-signed certificate takes over as a last resort so your service is
never down because of a certificate.

```yaml
services:
  web:
    image: rac021/nginx-cert:2
    ports: ["80:80", "443:443"]
    environment:
      CERT_DOMAINS: example.com,www.example.com
      CERT_EMAIL: you@example.com
      CERT_UPSTREAM: app:8080
    volumes:
      - nginx-cert-data:/data
volumes:
  nginx-cert-data:
```

`docker compose up -d`. That is the whole setup: the certificate is requested,
the hardened HTTPS server is generated, HTTP redirects to HTTPS, and renewal
happens on its own.

---

## Contents

- [Why](#why)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Configuration](#configuration)
  - [Declaring certificates](#declaring-certificates)
  - [Full variable reference](#full-variable-reference)
- [Certificate authorities](#certificate-authorities)
  - [Let's Encrypt](#lets-encrypt-default)
  - [Actalis](#actalis)
  - [ZeroSSL](#zerossl)
  - [Buypass, Google, SSL.com](#buypass-google-sslcom)
  - [Private ACME server](#private-acme-server)
- [Common setups](#common-setups)
- [The `certme` command](#the-certme-command)
- [Customising nginx](#customising-nginx)
- [Operations](#operations)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

---

## Why

Running HTTPS in a container usually means gluing together three moving parts:
nginx, an ACME client, and a scheduler — plus the glue that reloads nginx when a
certificate changes, and the ordering problem that the ACME HTTP-01 challenge
needs nginx to be *already* listening while nginx needs the certificate to be
*already* there.

nginx-cert is that assembly, done once and tested:

- **One image**, no sidecar, no init container, no cron to configure.
- **Never blocks on startup.** A temporary local certificate is installed
  instantly so nginx always comes up; the real certificate replaces it seconds
  later, and nginx is reloaded gracefully.
- **Never silently expires.** Every failure is reported with an actionable
  message, and the health check fails if a certificate has expired.
- **Never leaves you with a broken nginx.** A renewed certificate is verified
  (key match, full chain, SAN coverage, validity) before it is installed
  atomically, and the previous one is restored if `nginx -t` fails.
- **Sensible security defaults**: unprivileged container, private keys at `600`,
  TLS 1.2/1.3 with Mozilla's intermediate cipher suite, HSTS, OCSP stapling, no
  secret ever printed to the logs.

---

## Quick start

### Public domain

```bash
docker run -d --name web \
  -p 80:80 -p 443:443 \
  -v nginx-cert-data:/data \
  -e CERT_DOMAINS=example.com \
  -e CERT_EMAIL=you@example.com \
  -e CERT_UPSTREAM=10.0.0.5:8080 \
  rac021/nginx-cert:2
```

Requirements: the domain's A/AAAA record points at this host, and port 80 is
reachable from the internet (the authority connects to it to validate the
challenge).

Test with `CERT_STAGING=true` first if you like — quotas are effectively
unlimited there, but the certificates are not browser-trusted.

### Local development

```bash
docker compose -f examples/compose.localdev.yml up -d
docker compose -f examples/compose.localdev.yml cp nginx-cert:/data/ca/rootCA.pem .
```

`localhost`, `*.test`, `*.localhost` and private IP addresses are detected: no
public authority is contacted, and certificates are signed by a stable local CA.
Import `rootCA.pem` once and every development certificate is trusted, forever.

---

## How it works

```
                      ┌──────────────────────────── container ────┐
   :80  ──────────────▶ nginx ── /.well-known/acme-challenge/ ────▶ /var/www/acme
   :443 ──────────────▶  │                                          ▲
                        │  ssl_certificate /data/certs/<name>/…     │ writes the
                        │                                           │ challenge token
                        ▼                                           │
                     upstream                            acme.sh ───┘
                                                            │
   scheduler (every 12 h ± jitter) ─────────────────────────┘
```

Startup sequence — the ordering is what makes it reliable:

1. **Configuration is validated** before anything else. A typo exits with code 2
   and a message naming the offending variable, rather than failing three
   minutes later against a certificate authority.
2. **A temporary local certificate** is installed for every declared name that
   has none. This breaks the circular dependency between nginx and HTTP-01.
3. **nginx configuration is generated** from templates and checked with
   `nginx -t`. A broken configuration never reaches a running nginx.
4. **nginx starts**, and is now able to serve the ACME challenge.
5. **Real certificates are requested**, then verified and installed atomically.
   nginx is reloaded gracefully only if something actually changed.
6. **The scheduler** re-checks every `CERT_RENEW_INTERVAL`, with random jitter so
   a fleet of containers does not hit the authority in the same second.

On `docker stop`, SIGTERM is translated into SIGQUIT for nginx: in-flight
requests finish, the container exits 0, typically in under a second.

---

## Configuration

Everything is driven by `CERT_*` environment variables. Run
`docker exec <container> certme config` to see the effective configuration with
secrets masked.

### Declaring certificates

`CERT_DOMAINS` accepts one **certificate per line** (or per `;`-separated
segment). Domains on the same line share one certificate.

```yaml
CERT_DOMAINS: |
  example.com, www.example.com   | upstream=site:8080
  api.example.com                | upstream=api:3000
  *.internal.example.com         | dns=dns_cf
  203.0.113.10
```

Options after `|` apply to that certificate only and override the global value:

| Option      | Meaning                                                     |
|-------------|-------------------------------------------------------------|
| `upstream`  | Backend to proxy to (`host:port` or `scheme://host:port`)    |
| `provider`  | Pin a certificate authority for this certificate            |
| `name`      | Lineage name (defaults to the first domain)                 |
| `challenge` | `http-01` or `dns-01`                                       |
| `dns`       | acme.sh DNS module (`dns_cf`, `dns_ovh`, …)                  |
| `key_type`  | `ec-256`, `ec-384`, `ec-521`, `2048`, `3072`, `4096`         |
| `profile`   | Certificate profile (e.g. Let's Encrypt `shortlived`)        |
| `staging`   | `true` to use this authority's staging environment          |
| `hsts`      | HSTS header value, or `off`                                 |
| `redirect`  | `false` to disable the HTTP → HTTPS redirect                |

Each line becomes one lineage under `/data/certs/<name>/` and one generated
HTTPS server. An unknown option is a fatal configuration error — a silently
ignored typo is worse than a refusal to start.

### Full variable reference

#### Core

| Variable | Default | Description |
|---|---|---|
| `CERT_ENABLE` | `true` | Set to `false` to run plain nginx with no certificate management. |
| `CERT_DOMAINS` | — | Certificates to manage (see above). Empty means nginx only. |
| `CERT_EMAIL` | — | Account e-mail. Required for any public authority. |
| `CERT_UPSTREAM` | — | Default backend for generated HTTPS servers. |

#### Authority selection

| Variable | Default | Description |
|---|---|---|
| `CERT_PROVIDER` | `auto` | `auto`, or one of `letsencrypt`, `zerossl`, `actalis`, `buypass`, `google`, `sslcom`, `selfsigned`. |
| `CERT_PROVIDER_CHAIN` | `letsencrypt,zerossl,actalis,buypass` | Order tried in `auto` mode. |
| `CERT_ATTEMPTS` | `2` | Attempts per authority before moving to the next one. |
| `CERT_RETRY_DELAY` | `15` | Initial delay in seconds between attempts (doubles, capped at 300). |
| `CERT_FALLBACK_SELFSIGNED` | `true` | Install a local certificate when every authority fails. |
| `CERT_STAGING` | `false` | Use the authority's staging environment. |
| `CERT_ACME_SERVER` | — | Raw ACME directory URL, overriding the table (private CA). |
| `CERT_ACME_ARGS` | — | Extra raw acme.sh arguments (escape hatch). |
| `CERT_ACME_TIMEOUT` | `5m` | Time budget per attempt, so one dead authority cannot stall the chain. |

#### Credentials

| Variable | Default | Description |
|---|---|---|
| `CERT_EAB_KID` | — | External Account Binding key identifier. |
| `CERT_EAB_HMAC_KEY` | — | External Account Binding HMAC key. |
| `CERT_ZEROSSL_API_KEY` | — | ZeroSSL API key; the EAB is derived from it automatically. |

#### Issuance and renewal

| Variable | Default | Description |
|---|---|---|
| `CERT_KEY_TYPE` | `ec-256` | `ec-256`, `ec-384`, `ec-521`, `2048`, `3072`, `4096`. |
| `CERT_CHALLENGE` | `auto` | `auto`, `http-01`, `dns-01`. `auto` picks DNS-01 for wildcards. |
| `CERT_DNS_PROVIDER` | — | acme.sh DNS module for DNS-01 (`dns_cf`, `dns_ovh`, …). |
| `CERT_DNS_SLEEP` | `20` | Seconds to wait for DNS propagation. |
| `CERT_PROFILE` | — | Certificate profile requested from the authority. |
| `CERT_RENEW_DAYS` | `30` | Renew when fewer than this many days remain. |
| `CERT_RENEW_INTERVAL` | `12h` | How often the scheduler checks. |
| `CERT_RENEW_JITTER` | `30m` | Random extra delay added to each check. |
| `CERT_FORCE_RENEW` | `false` | Renew even when the certificate is still valid. |
| `CERT_FAILURE_COOLDOWN` | `30m` | Backoff after a failure; doubles on each consecutive failure. |
| `CERT_FAILURE_COOLDOWN_MAX` | `12h` | Cap for that backoff. |
| `CERT_POST_HOOK` | — | Shell command run after a successful renewal. `CERTME_CHANGED` lists the affected certificates. |

#### Self-signed

| Variable | Default | Description |
|---|---|---|
| `CERT_SELFSIGNED_CA` | `true` | Sign local certificates with a stable local CA (`/data/ca/rootCA.pem`). |
| `CERT_SELFSIGNED_DAYS` | `365` | Validity of local certificates. |

#### nginx

| Variable | Default | Description |
|---|---|---|
| `CERT_MANAGE_NGINX` | `true` | Generate `/etc/nginx/nginx.conf`. Set to `false` to mount your own. |
| `CERT_MANAGE_VHOSTS` | `true` | Generate one HTTPS server per certificate. |
| `CERT_HTTP_REDIRECT` | `true` | Redirect plain HTTP to HTTPS (308). |
| `CERT_HSTS` | `max-age=31536000` | `Strict-Transport-Security` value, or `off`. |
| `CERT_SSL_POLICY` | `intermediate` | `intermediate` (TLS 1.2+1.3) or `modern` (TLS 1.3 only). |
| `CERT_HTTP2` | `true` | Enable HTTP/2. |
| `CERT_HTTP3` | `false` | Enable HTTP/3 (also publish the port over UDP). |
| `CERT_HTTP_PORT` | `80` | Port nginx listens on for HTTP. |
| `CERT_HTTPS_PORT` | `443` | Port nginx listens on for HTTPS. |
| `CERT_CLIENT_MAX_BODY_SIZE` | `16m` | Maximum request body size. |
| `CERT_PROXY_TIMEOUT` | `60s` | Upstream read/send timeout. |
| `CERT_PROXY_CONNECT_TIMEOUT` | `10s` | Upstream connect timeout. |
| `CERT_WORKER_CONNECTIONS` | `2048` | `worker_connections`. |
| `CERT_RESOLVER` | `127.0.0.11 1.1.1.1 8.8.8.8` | DNS resolvers used by nginx. |
| `CERT_ACCESS_LOG` | `true` | Write an access log. |
| `CERT_REAL_IP_FROM` | — | Comma-separated trusted proxy CIDRs (`set_real_ip_from`). |

#### Paths and logging

| Variable | Default | Description |
|---|---|---|
| `CERT_DATA_DIR` | `/data` | Persistent data (certificates, ACME account, local CA, state). |
| `CERT_WEBROOT` | `/var/www/acme` | Directory serving the ACME challenge. |
| `CERT_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. |
| `CERT_LOG_FORMAT` | `text` | `text` or `json`. |
| `CERT_LOG_COLOR` | `auto` | `auto`, `always`, `never`. |

---

## Certificate authorities

`certme providers` lists them along with whether each is usable with your
current credentials.

### Let's Encrypt (default)

Nothing to configure beyond `CERT_EMAIL`. Supports wildcards (via DNS-01) and
IP-address certificates (automatically requested with the `shortlived` profile,
valid ~160 hours — set `CERT_RENEW_DAYS=2` for those).

### Actalis

European authority, free tier: one domain per certificate, 90 days. Requires
External Account Binding, obtained by enabling ACME in the Actalis customer
portal.

```yaml
CERT_PROVIDER: actalis
CERT_EMAIL: you@example.com
CERT_DOMAINS: data.example.eu
CERT_EAB_KID: ${ACTALIS_EAB_KID}
CERT_EAB_HMAC_KEY: ${ACTALIS_EAB_HMAC}
```

To keep Actalis as the primary authority while still surviving an outage on
renewal day, use the chain instead of pinning:

```yaml
CERT_PROVIDER: auto
CERT_PROVIDER_CHAIN: actalis,letsencrypt
```

See [`examples/compose.actalis.yml`](examples/compose.actalis.yml).

### ZeroSSL

Requires EAB — but if you already have an API key, nginx-cert derives the EAB
for you and caches it:

```yaml
CERT_PROVIDER: zerossl
CERT_ZEROSSL_API_KEY: ${ZEROSSL_API_KEY}
```

ZeroSSL's ACME endpoint does not issue certificates for IP addresses. When
`CERT_ZEROSSL_API_KEY` is set and an IP-address certificate is requested,
nginx-cert falls back to ZeroSSL's REST API for that one case (paid plan
required). Let's Encrypt's `shortlived` profile is the free alternative.

### Buypass, Google, SSL.com

| Authority | `CERT_PROVIDER` | EAB | Notes |
|---|---|---|---|
| Buypass Go SSL | `buypass` | no | 180-day certificates, no wildcards |
| Google Trust Services | `google` | required | EAB from the Google Cloud console |
| SSL.com | `sslcom` | required | EAB from the SSL.com portal |

### Private ACME server

Any RFC 8555 server (step-ca, Smallstep, EJBCA, Vault) works:

```yaml
CERT_ACME_SERVER: https://ca.internal.example.com/acme/acme/directory
CERT_EAB_KID: ...          # if your server requires it
CERT_EAB_HMAC_KEY: ...
```

### Adding an authority

`providers/providers.tsv` is a plain tab-separated table. Adding an authority is
adding one line — there is no code to change:

```
myca	My CA	-	https://acme.myca.example/directory	required	-	fqdn,wildcard	EAB from the customer portal.
```

---

## Common setups

| Goal | Example |
|---|---|
| Single site in production | [`docker-compose.yml`](docker-compose.yml) |
| Several sites, several backends | [`examples/compose.multisite.yml`](examples/compose.multisite.yml) |
| Actalis | [`examples/compose.actalis.yml`](examples/compose.actalis.yml) |
| Wildcard via DNS-01 | [`examples/compose.wildcard-dns.yml`](examples/compose.wildcard-dns.yml) |
| Local HTTPS development | [`examples/compose.localdev.yml`](examples/compose.localdev.yml) |

---

## The `certme` command

```bash
docker exec <container> certme <command>
```

| Command | What it does |
|---|---|
| `status` | Table of every certificate: authority, expiry, whether renewal is due |
| `status --json` | Same, machine-readable (monitoring, scripts) |
| `issue [name…]` | Issue or renew what needs it; `--force` to renew regardless |
| `renew` | Alias for `issue` |
| `list` | Declared certificates and their domains |
| `providers` | Authorities and whether they are usable with current credentials |
| `config` | Effective configuration, secrets masked |
| `render` | Regenerate the nginx configuration from templates |
| `check` | `nginx -t` on the generated configuration |
| `reload` | Validate then reload nginx |
| `revoke <name>` | Revoke a certificate with its issuing authority |
| `health` | Health probe (used by the Docker `HEALTHCHECK`) |
| `version` | Versions of nginx-cert, nginx, acme.sh, openssl |

Exit codes: `0` success · `1` failure · `2` configuration · `3` no authority
could issue · `4` invalid nginx configuration · `5` another operation running.

---

## Customising nginx

Three levels, from lightest to heaviest:

**1. Add your own servers.** Anything you drop into `/etc/nginx/conf.d/` is
included. Generated files are prefixed `nginx-cert.` and are the only ones
nginx-cert ever deletes.

```yaml
volumes:
  - ./conf.d:/etc/nginx/conf.d:ro
```

**2. Keep the certificates, write your own servers.** Set
`CERT_MANAGE_VHOSTS=false`; certificates stay managed and available at:

```
/data/certs/<name>/fullchain.pem
/data/certs/<name>/privkey.pem
/data/certs/<name>/chain.pem
/data/certs/<name>/cert.pem
```

**3. Take over `nginx.conf` entirely.** Set `CERT_MANAGE_NGINX=false` and mount
your own. You must then keep this location yourself, or renewal will fail:

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
    default_type "text/plain";
    try_files $uri =404;
}
```

---

## Operations

**Persistence.** Mount a volume on `/data`. It holds the certificates, the ACME
account key, the local CA and the failure state. Without it, everything is
re-requested each time the container is recreated and you will hit the
authority's rate limit. nginx-cert warns at startup if `/data` is not a volume.

**Monitoring.** `certme status --json` returns `days_left`, `renewal_needed` and
`self_signed` per certificate. The `HEALTHCHECK` turns the container unhealthy
if nginx stops answering or if a certificate has expired.

**Logs.** Everything goes to the container's standard error, timestamped and
levelled. `CERT_LOG_FORMAT=json` for log aggregators. Secrets are never printed:
EAB keys and API keys are registered and masked in every message.

**Rate limits.** Let's Encrypt allows 5 duplicate certificates per week. After a
failure nginx-cert waits `CERT_FAILURE_COOLDOWN` (doubling, capped at
`CERT_FAILURE_COOLDOWN_MAX`) before trying again, so a container in a restart
loop cannot burn your quota.

**Renewal hook.** `CERT_POST_HOOK` runs after a successful renewal, with
`CERTME_CHANGED` set to the list of renewed certificates — useful to reload
another service that shares the certificate.

---

## Troubleshooting

**`unauthorized` / `Invalid response from …` during validation.**
The authority could not fetch the challenge. Check, in this order: the domain's
DNS record points here, port 80 is published *and* reachable from the internet
(not only from your LAN), and no firewall or upstream proxy intercepts
`/.well-known/acme-challenge/`. Verify with
`curl http://your-domain/healthz` from outside.

**`rateLimited` / `too many certificates`.**
You have hit the authority's quota. Use `CERT_STAGING=true` while testing, and
make sure `/data` is a persistent volume.

**`invalidContact` / `forbidden domain`.**
`CERT_EMAIL` uses a reserved example domain. Authorities refuse `example.com`,
`example.org`, `*.test` and friends. Use a real address.

**`externalAccountRequired`.**
The authority needs EAB credentials: set `CERT_EAB_KID` and
`CERT_EAB_HMAC_KEY` (or `CERT_ZEROSSL_API_KEY` for ZeroSSL).
`certme providers` shows which authorities are currently usable.

**The browser warns about the certificate.**
Either `CERT_STAGING=true` is still set, or every authority failed and the local
fallback is in use. `certme status` shows `local` in that case; the logs explain
why each authority was skipped or failed.

**502 on HTTPS.**
nginx is running but the upstream is not reachable. This is deliberate: the
proxy starts even when the backend does not exist yet, instead of refusing to
start. Check `CERT_UPSTREAM` and that both containers share a network.

**Wildcard certificate not issued.**
Wildcards require DNS-01. Set `CERT_DNS_PROVIDER` and your DNS provider's API
credentials (see [`examples/compose.wildcard-dns.yml`](examples/compose.wildcard-dns.yml)).

More detail: `CERT_LOG_LEVEL=debug`, and the full ACME trace is at
`/data/acme/acme.log`.

---

## Development

```bash
./tests/run.sh unit          # unit tests, no dependency beyond bash and openssl
./tests/run.sh lint          # shellcheck + hadolint
./tests/run.sh integration   # builds the image and exercises a real container
./tests/run.sh               # all of the above
```

Layout:

```
entrypoint.sh          PID 1: supervisor, signals, scheduler
bin/certme             command line interface
lib/                   log, util, domains, config, certs, issue, nginx, template, lock
providers/             providers.tsv (declarative table) + acme, zerossl_rest, selfsigned drivers
templates/             nginx configuration templates (%%PLACEHOLDER%% syntax)
tests/                 unit + integration
```

Migrating from version 1: see [MIGRATION.md](MIGRATION.md).
Changes: [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
