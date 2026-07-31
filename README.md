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
- [What it looks like](#what-it-looks-like)
- [How it works](#how-it-works)
- [Configuration](#configuration)
  - [Declaring certificates](#declaring-certificates)
  - [What nginx-cert serves](#what-nginx-cert-serves)
  - [Full variable reference](#full-variable-reference)
- [Certificate authorities](#certificate-authorities)
  - [Let's Encrypt](#lets-encrypt)
  - [Actalis](#actalis)
  - [ZeroSSL](#zerossl)
  - [Buypass Go SSL](#buypass-go-ssl)
  - [Google Trust Services](#google-trust-services)
  - [SSL.com](#sslcom)
  - [Private ACME server](#private-acme-server)
  - [Mixing authorities in one container](#mixing-authorities-in-one-container)
  - [Tuning the fallback chain](#tuning-the-fallback-chain)
  - [Adding an authority](#adding-an-authority)
- [More complete examples](#more-complete-examples)
  - [Wildcard certificate (DNS-01)](#wildcard-certificate-dns-01)
  - [IP-address certificates](#ip-address-certificates)
  - [Local development](#local-development)
  - [Behind a load balancer, with your own nginx configuration](#behind-a-load-balancer-with-your-own-nginx-configuration)
  - [All example files](#all-example-files)
- [Without Compose: plain `docker run`](#without-compose-plain-docker-run)
  - [Let's Encrypt](#lets-encrypt-1)
  - [Staging first, then production](#staging-first-then-production)
  - [Actalis](#actalis-1)
  - [ZeroSSL](#zerossl-1)
  - [Buypass, Google, SSL.com](#buypass-go-ssl-1)
  - [Private ACME server](#private-acme-server-1)
  - [Several certificates and several authorities](#several-certificates-and-several-authorities-in-one-container)
  - [Wildcard, IP address, local development](#wildcard-certificate-dns-01-1)
  - [Behind a load balancer](#behind-a-load-balancer-with-your-own-nginx-configuration-1)
  - [Day-to-day operations](#day-to-day-operations)
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
docker run -d --name web                  \
           -p 80:80 -p 443:443            \
           -v nginx-cert-data:/data       \
           -e CERT_DOMAINS=example.com    \
           -e CERT_EMAIL=you@example.com  \
           -e CERT_UPSTREAM=10.0.0.5:8080 \
           rac021/nginx-cert:2
```

Requirements: the domain's A/AAAA record points at this host, and port 80 is
reachable from the internet (the authority connects to it to validate the
challenge).

Test with `CERT_STAGING=true` first — quotas are effectively unlimited there, so
a wrong DNS record or a closed port 80 costs nothing. The certificates are not
browser-trusted.

**Going live** is then a single change: drop `CERT_STAGING` and restart.
nginx-cert records which authority issued each certificate, notices the live one
came from a staging environment, and requests a trusted replacement immediately —
a staging certificate is valid for 90 days and correctly signed, so nothing in
the certificate itself would have triggered a renewal.

### Locally, with no domain

```bash
docker compose -f examples/compose.localdev.yml up -d
```

`localhost`, `*.test`, `*.localhost` and private IP addresses are detected: no
public authority is contacted, and certificates are signed by a stable local CA.
See [Local development](#local-development) for trusting it in your browser.

---

## What it looks like

Startup, with three certificates declared (output abridged):

```
nginx-cert 2.0.0
--------------------------------------------------------------

Effective configuration
--------------------------------------------------------------
  Certificate management     enabled
  Provider                   auto -> letsencrypt,zerossl,actalis,buypass -> selfsigned
  Attempts per authority     2 (initial delay 15s, doubled each retry)
  Self-signed fallback       true
  Staging environment        false
  Account e-mail             ops@example.com
  Key type                   ec-256
  Renewal                    at D-30 before expiry, checked every 12h (+/-30m)
  TLS policy                 intermediate
  Data directory             /data

Declared certificates (3)
--------------------------------------------------------------
  example.com                example.com www.example.com  [fqdn] -> site:8080
  api.example.com            api.example.com  [fqdn] -> api:3000
  internal.lan               internal.lan  [internal]

INFO  'example.com': installing a temporary local certificate until the real one arrives.
INFO  'internal.lan': installing a temporary local certificate until the real one arrives.
INFO  Creating the local certificate authority (valid for 10 years).
INFO  Local authority ready: /data/ca/rootCA.pem

nginx configuration
--------------------------------------------------------------
INFO  Starting nginx...
INFO  nginx is listening (PID 949).

Certificates
--------------------------------------------------------------

Certificate 'example.com' -- local certificate in place, a public authority is possible
--------------------------------------------------------------
INFO  -> Let's Encrypt: requesting a certificate for example.com www.example.com (http-01 challenge).
INFO  Let's Encrypt issued certificate 'example.com'.
INFO  'example.com' issued by Let's Encrypt -- expires 2026-10-29 01:18:36Z
INFO  nginx configuration reloaded.
INFO  nginx-cert is up.
INFO  Next certificate check in 12h 25m 26s.
```

`certme status`:

```
CERTIFICATE                  STATE         AUTHORITY                  EXPIRES   DOMAINS
--------------------------------------------------------------------------------------
example.com                  valid         R11                        D-89      example.com www.example.com
api.example.com              valid         R11                        D-89      api.example.com
internal.lan                 local         nginx-cert local developme D-364     internal.lan
```

`certme providers` — which authorities your credentials actually unlock:

```
ID                     AUTHORITY                  EAB       ACCEPTED KINDS    USABLE HERE
-----------------------------------------------------------------------------------------
letsencrypt            Let's Encrypt              no        fqdn,wildcard,ip  yes
zerossl                ZeroSSL                    required  fqdn,wildcard     no -- EAB credentials missing
actalis                Actalis                    required  fqdn              no -- EAB credentials missing
buypass                Buypass Go SSL             no        fqdn              yes
google                 Google Trust Services      required  fqdn,wildcard     no -- EAB credentials missing
sslcom                 SSL.com                    required  fqdn,wildcard     no -- EAB credentials missing
selfsigned             Local authority            no        all               yes (last resort)
zerossl-rest           ZeroSSL (REST API)         no        ip                no -- CERT_ZEROSSL_API_KEY unset
```

`certme status --json`, for monitoring:

```json
{
  "name": "example.com",
  "domains": ["example.com", "www.example.com"],
  "kind": "fqdn",
  "provider": "auto",
  "exists": true,
  "days_left": 89,
  "not_after": "2026-10-29 01:18:36Z",
  "issuer": "C=US, O=Let's Encrypt, CN=R11",
  "self_signed": false,
  "renewal_needed": false,
  "renewal_reason": ""
}
```

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
| `upstream`  | Backend to proxy to (`host:port` or `scheme://host:port`)   |
| `provider`  | Pin a certificate authority for this certificate            |
| `name`      | Lineage name (defaults to the first domain)                 |
| `challenge` | `http-01` or `dns-01`                                       |
| `dns`       | acme.sh DNS module (`dns_cf`, `dns_ovh`, …)                 |
| `key_type`  | `ec-256`, `ec-384`, `ec-521`, `2048`, `3072`, `4096`        |
| `profile`   | Certificate profile (e.g. Let's Encrypt `shortlived`)       |
| `staging`   | `true` to use this authority's staging environment          |
| `hsts`      | HSTS header value, or `off`                                 |
| `redirect`  | `false` to disable the HTTP → HTTPS redirect                |

Each line becomes one lineage under `/data/certs/<name>/` and one generated
HTTPS server. An unknown option is a fatal configuration error — a silently
ignored typo is worse than a refusal to start.

### What nginx-cert serves

nginx-cert manages certificates and the nginx in front of them. **It does not
run your application** — `CERT_UPSTREAM` is just the address written into the
generated `proxy_pass`, and you are responsible for having something listening
there. There are three ways to use it:

**1. Reverse proxy in front of your application** — `CERT_UPSTREAM=host:port`.
The generated HTTPS server forwards everything to that address, with the usual
`X-Forwarded-*` headers and WebSocket support:

```bash
docker network create web
docker run -d --name app --network web traefik/whoami --port=8080
docker run -d --name nginx-cert --network web  \
           -p 80:80 -p 443:443                 \
           -v nginx-cert-data:/data            \
           -e CERT_EMAIL=you@example.com       \
           -e CERT_DOMAINS=example.com         \
           -e CERT_UPSTREAM=app:8080           \
           rac021/nginx-cert:2
```

Resolution happens per request, so the order does not matter and a restart of
your application never requires touching nginx. While the backend is down the
site answers 502 or 504; it recovers on its own.

Note that `app:8080` only resolves if both containers share a **user-defined
network** — Docker's default bridge has no name resolution. An IP address such
as `10.0.0.5:8080` works from anywhere routable.

**2. Static site** — omit `CERT_UPSTREAM` and mount your files on
`/var/www/html`. Without it you get a placeholder page, which is enough to check
that TLS works:

```bash
docker run -d --name nginx-cert                \
           -p 80:80 -p 443:443                 \
           -v nginx-cert-data:/data            \
           -v ./public:/var/www/html:ro        \
           -e CERT_EMAIL=you@example.com       \
           -e CERT_DOMAINS=example.com         \
           rac021/nginx-cert:2
```

**3. Certificates only** — set `CERT_MANAGE_VHOSTS=false` and write your own
server blocks in `/etc/nginx/conf.d/`, or `CERT_MANAGE_NGINX=false` to own
`nginx.conf` entirely. Certificates remain available at
`/data/certs/<name>/{fullchain,privkey,chain}.pem`. See
[Customising nginx](#customising-nginx).

### Full variable reference

#### Core

| Variable | Default | Description |
|---|---|---|
| `CERT_ENABLE`   | `true` | Set to `false` to run plain nginx with no certificate management. |
| `CERT_DOMAINS`  | — | Certificates to manage (see above). Empty means nginx only. |
| `CERT_EMAIL`    | — | Account e-mail. Required for any public authority. |
| `CERT_UPSTREAM` | — | Address of **your** application, proxied by the generated HTTPS servers (`host:port`). Omit it to serve `/var/www/html` instead. nginx-cert does not run the backend. |

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
| `CERT_ZEROSSL_VALIDITY_DAYS` | `90` | Requested validity, ZeroSSL REST path only (IP-address certificates). |
| `CERT_ZEROSSL_TIMEOUT` | `5m` | How long to wait for ZeroSSL to issue, REST path only. |

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

Every authority below speaks the same protocol, so the configuration differs
only in which credentials you need. `certme providers` prints the table with a
"usable here" column based on the credentials you actually provided.

| Authority | `CERT_PROVIDER` | EAB | Wildcard | IP | Validity | Cost |
|---|---|---|---|---|---|---|
| Let's Encrypt | `letsencrypt` | no | yes (DNS-01) | yes (~160 h) | 90 days | free |
| ZeroSSL | `zerossl` | required | yes (DNS-01) | REST path only | 90 days | free tier |
| Actalis | `actalis` | required | no | no | 90 days | free tier |
| Buypass Go SSL | `buypass` | no | no | no | 180 days | free |
| Google Trust Services | `google` | required | yes (DNS-01) | no | 90 days | free tier |
| SSL.com | `sslcom` | required | yes (DNS-01) | no | 90 days | account |
| Local CA | `selfsigned` | — | yes | yes | 365 days | — |

### Let's Encrypt

The default. Nothing to configure beyond an e-mail address.

```yaml
# examples: docker-compose.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_EMAIL: you@example.com
      CERT_DOMAINS: example.com, www.example.com
      CERT_UPSTREAM: app:8080
      CERT_STAGING: "false"      # "true" while testing: huge quotas, untrusted certs
    volumes:
      - nginx-cert-data:/data

  app:
    image: traefik/whoami
    command: --port=8080
    expose: ["8080"]

volumes:
  nginx-cert-data:
```

### Actalis

European authority. Free tier: **one domain per certificate**, 90 days.
Requires External Account Binding — enable ACME in the Actalis customer portal
to obtain the KID and HMAC key.

```yaml
# examples/compose.actalis.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_EMAIL: you@example.com
      CERT_DOMAINS: data.example.eu
      CERT_UPSTREAM: app:8080

      CERT_EAB_KID: ${ACTALIS_EAB_KID:?ACTALIS_EAB_KID is required}
      CERT_EAB_HMAC_KEY: ${ACTALIS_EAB_HMAC:?ACTALIS_EAB_HMAC is required}

      # Actalis first, Let's Encrypt as a safety net if Actalis is down on
      # renewal day. Use CERT_PROVIDER=actalis instead to pin it strictly.
      CERT_PROVIDER: auto
      CERT_PROVIDER_CHAIN: actalis,letsencrypt
    volumes:
      - nginx-cert-data:/data

  app:
    image: traefik/whoami
    command: --port=8080
    expose: ["8080"]

volumes:
  nginx-cert-data:
```

Actalis issues one domain per certificate on the free tier, so declare each
host on its own line rather than as a multi-SAN certificate:

```yaml
CERT_DOMAINS: |
  example.eu       | upstream=app:8080 provider=actalis
  www.example.eu   | upstream=app:8080 provider=actalis
```

### ZeroSSL

Requires EAB. If you already have an API key, nginx-cert derives the EAB from
it on first use and caches it in `/data/state/zerossl-eab.env` — one variable
instead of two.

```yaml
# examples/compose.zerossl.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_PROVIDER: zerossl
      CERT_EMAIL: you@example.com
      CERT_DOMAINS: example.com, www.example.com
      CERT_UPSTREAM: app:8080

      # Option A -- API key, EAB derived automatically
      CERT_ZEROSSL_API_KEY: ${ZEROSSL_API_KEY}

      # Option B -- explicit EAB from the ZeroSSL dashboard
      # CERT_EAB_KID: ${ZEROSSL_EAB_KID}
      # CERT_EAB_HMAC_KEY: ${ZEROSSL_EAB_HMAC}
    volumes:
      - nginx-cert-data:/data

  app:
    image: traefik/whoami
    command: --port=8080
    expose: ["8080"]

volumes:
  nginx-cert-data:
```

ZeroSSL's ACME endpoint does not issue certificates for IP addresses. When
`CERT_ZEROSSL_API_KEY` is set and an IP-address certificate is requested,
nginx-cert falls back to ZeroSSL's REST API for that one case (paid plan
required), tunable with `CERT_ZEROSSL_VALIDITY_DAYS` and `CERT_ZEROSSL_TIMEOUT`.
Let's Encrypt's `shortlived` profile is the free alternative — see
[IP-address certificates](#ip-address-certificates).

### Buypass Go SSL

Free, no EAB, **180-day** certificates — half as many renewals. No wildcards.

```yaml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_PROVIDER: buypass
      CERT_EMAIL: you@example.com
      CERT_DOMAINS: example.com
      CERT_UPSTREAM: app:8080
      # 180-day certificates: renewing at D-30 is unnecessarily eager.
      CERT_RENEW_DAYS: "45"
    volumes:
      - nginx-cert-data:/data

  app:
    image: traefik/whoami
    command: --port=8080
    expose: ["8080"]

volumes:
  nginx-cert-data:
```

### Google Trust Services

Requires EAB, generated from the Google Cloud console (Public Certificate
Authority API):

```bash
gcloud publicca external-account-keys create
```

```yaml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_PROVIDER: google
      CERT_EMAIL: you@example.com
      CERT_DOMAINS: example.com, www.example.com
      CERT_UPSTREAM: app:8080
      CERT_EAB_KID: ${GTS_EAB_KID:?GTS_EAB_KID is required}
      CERT_EAB_HMAC_KEY: ${GTS_EAB_HMAC:?GTS_EAB_HMAC is required}
    volumes:
      - nginx-cert-data:/data

  app:
    image: traefik/whoami
    command: --port=8080
    expose: ["8080"]

volumes:
  nginx-cert-data:
```

### SSL.com

Requires EAB, obtained from the SSL.com customer portal. Same shape as Google:

```yaml
environment:
  CERT_PROVIDER: sslcom
  CERT_EMAIL: you@example.com
  CERT_DOMAINS: example.com
  CERT_UPSTREAM: app:8080
  CERT_EAB_KID: ${SSLCOM_EAB_KID}
  CERT_EAB_HMAC_KEY: ${SSLCOM_EAB_HMAC}
```

### Private ACME server

Any RFC 8555 server — step-ca, Smallstep, EJBCA, HashiCorp Vault.

```yaml
# examples/compose.private-acme.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_EMAIL: ops@example.com
      CERT_DOMAINS: service.corp.example.com | upstream=app:8080

      # Any authority id acts as the carrier; the URL below overrides its
      # directory. letsencrypt is convenient because it needs no EAB.
      CERT_PROVIDER: letsencrypt
      CERT_ACME_SERVER: https://ca.corp.example.com/acme/acme/directory
      # CERT_EAB_KID / CERT_EAB_HMAC_KEY if your server requires them.

      CERT_RENEW_DAYS: "10"
      CERT_RENEW_INTERVAL: 6h
      # Do not silently downgrade to self-signed if the internal CA is down.
      CERT_FALLBACK_SELFSIGNED: "false"
    volumes:
      - nginx-cert-data:/data
      # So the container trusts the ACME server's own HTTPS certificate.
      - ./corp-root-ca.pem:/etc/ssl/certs/corp-root-ca.pem:ro

volumes:
  nginx-cert-data:
```

### Mixing authorities in one container

`provider=` on a `CERT_DOMAINS` line overrides the global choice. Credentials
are declared once; each authority reads only what it needs.

```yaml
# examples/compose.multi-ca.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_EMAIL: ops@example.com
      CERT_DOMAINS: |
        # Default chain (Let's Encrypt first)
        www.example.com, example.com | upstream=site:8080

        # European CA required by this customer
        customer.example.eu          | upstream=customer:8080 provider=actalis

        # Wildcard: ZeroSSL over DNS-01
        *.apps.example.com           | upstream=apps:8080 provider=zerossl challenge=dns-01 dns=dns_cf

        # 180-day certificates, no EAB
        status.example.com           | upstream=status:8080 provider=buypass

        # Not publicly resolvable: signed by the local CA
        internal.lan                 | upstream=internal:8080

      CERT_EAB_KID: ${ACTALIS_EAB_KID}
      CERT_EAB_HMAC_KEY: ${ACTALIS_EAB_HMAC}
      CERT_ZEROSSL_API_KEY: ${ZEROSSL_API_KEY}
      CF_Token: ${CF_TOKEN}
    volumes:
      - nginx-cert-data:/data

volumes:
  nginx-cert-data:
```

`certme status` then shows which authority actually signed each certificate.

### Tuning the fallback chain

In `auto` mode, `CERT_PROVIDER_CHAIN` is walked in order. Each authority gets
`CERT_ATTEMPTS` tries with exponential backoff before the next one is used, and
`selfsigned` always closes the chain unless you disable it.

```yaml
CERT_PROVIDER: auto
CERT_PROVIDER_CHAIN: actalis,zerossl,letsencrypt,buypass
CERT_ATTEMPTS: "3"                 # tries per authority
CERT_RETRY_DELAY: "20"             # seconds, doubled each retry
CERT_ACME_TIMEOUT: 3m              # per-attempt budget
CERT_FALLBACK_SELFSIGNED: "true"   # "false" to fail loudly instead
```

Authorities that cannot issue the requested kind of name, or whose EAB
credentials are missing, are dropped from the chain before it is walked, with
the reason logged at debug level. That is why the order above is safe even when
you have credentials for only some of them.

### Adding an authority

`providers/providers.tsv` is a tab-separated table. Adding an authority is
adding one line — there is no code to change, and the existing tests cover it
immediately:

```
myca	My CA	-	https://acme.myca.example/directory	required	-	fqdn,wildcard	EAB from the customer portal.
```

Columns: id, label, acme.sh alias (or `-` for a raw URL), directory URL, EAB
(`required`/`no`), staging id (or `-`), accepted kinds, help text.

---

## More complete examples

### Wildcard certificate (DNS-01)

A wildcard cannot be validated over HTTP-01: the authority needs a TXT record,
so nginx-cert needs API access to your DNS provider. The DNS modules come from
acme.sh (~150 providers); their credentials are passed straight through as
environment variables.

```yaml
# examples/compose.wildcard-dns.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      CERT_EMAIL: ops@example.com
      CERT_DOMAINS: |
        *.example.com, example.com | upstream=app:8080
      CERT_DNS_PROVIDER: dns_cf
      CERT_DNS_SLEEP: "30"          # propagation delay before validation
      CF_Token: ${CF_TOKEN}
      CF_Account_ID: ${CF_ACCOUNT_ID}
    volumes:
      - nginx-cert-data:/data

  app:
    image: traefik/whoami
    command: --port=8080
    expose: ["8080"]

volumes:
  nginx-cert-data:
```

| Provider | `CERT_DNS_PROVIDER` | Credentials |
|---|---|---|
| Cloudflare | `dns_cf` | `CF_Token`, `CF_Account_ID` |
| OVH | `dns_ovh` | `OVH_AK`, `OVH_AS`, `OVH_CK`, `OVH_END_POINT` |
| Gandi | `dns_gandi_livedns` | `GANDI_LIVEDNS_KEY` |
| Route 53 | `dns_aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Scaleway | `dns_scaleway` | `SCALEWAY_API_TOKEN` |

[Full list](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).

### IP-address certificates

```yaml
# examples/compose.ip-address.yml
environment:
  CERT_EMAIL: ops@example.com
  CERT_DOMAINS: 203.0.113.10
  CERT_UPSTREAM: app:8080
  # Let's Encrypt issues IP certificates under the "shortlived" profile
  # (~160 h), selected automatically. Renew far more often.
  CERT_RENEW_DAYS: "2"
  CERT_RENEW_INTERVAL: 6h

  # Or, for 90-day IP certificates via ZeroSSL's REST API (paid plan):
  # CERT_ZEROSSL_API_KEY: ${ZEROSSL_API_KEY}
  # CERT_RENEW_DAYS: "30"
```

Private addresses (`10/8`, `192.168/16`, `169.254/16`, CGNAT…) are detected and
signed by the local CA: no authority will certify them, and no pointless
network round-trip is made.

### Local development

```yaml
# examples/compose.localdev.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    ports: ["80:80", "443:443"]
    environment:
      CERT_DOMAINS: |
        localhost      | upstream=app:8080
        app.test       | upstream=app:8080
        api.localhost  | upstream=api:3000
      CERT_HSTS: "off"          # avoid a sticky HSTS entry during experiments
      CERT_LOG_LEVEL: debug
    volumes:
      - nginx-cert-data:/data

  app: { image: traefik/whoami, command: --port=8080, expose: ["8080"] }
  api: { image: traefik/whoami, command: --port=3000, expose: ["3000"] }

volumes:
  nginx-cert-data:
```

```bash
docker compose -f examples/compose.localdev.yml up -d
docker compose -f examples/compose.localdev.yml cp nginx-cert:/data/ca/rootCA.pem .
sudo cp rootCA.pem /usr/local/share/ca-certificates/nginx-cert.crt && sudo update-ca-certificates
```

Import the root once and every development certificate is trusted, including
the ones generated later.

### Behind a load balancer, with your own nginx configuration

```yaml
# examples/compose.behind-lb.yml
services:
  nginx-cert:
    image: rac021/nginx-cert:2
    restart: unless-stopped
    # Unprivileged ports: useful under a balancer, or on a platform that
    # forbids file capabilities.
    ports: ["8080:8080", "8443:8443"]
    environment:
      CERT_EMAIL: ops@example.com
      CERT_DOMAINS: example.com, www.example.com
      CERT_HTTP_PORT: "8080"
      CERT_HTTPS_PORT: "8443"
      CERT_REAL_IP_FROM: 10.0.0.0/8,172.16.0.0/12
      CERT_HTTP_REDIRECT: "false"   # the balancer already redirects
      CERT_MANAGE_VHOSTS: "false"   # keep the base, write the servers yourself
    volumes:
      - nginx-cert-data:/data
      - ./conf.d:/etc/nginx/conf.d:ro

volumes:
  nginx-cert-data:
```

```nginx
# ./conf.d/my-site.conf
server {
    listen      8443 ssl;
    http2       on;
    server_name example.com www.example.com;

    ssl_certificate           /data/certs/example.com/fullchain.pem;
    ssl_certificate_key       /data/certs/example.com/privkey.pem;
    ssl_trusted_certificate   /data/certs/example.com/chain.pem;
    # Protocols, ciphers and stapling are already applied at the http level.

    location / {
        proxy_pass http://app:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### All example files

| Goal | File |
|---|---|
| Single site, Let's Encrypt | [`docker-compose.yml`](docker-compose.yml) |
| Actalis | [`examples/compose.actalis.yml`](examples/compose.actalis.yml) |
| ZeroSSL | [`examples/compose.zerossl.yml`](examples/compose.zerossl.yml) |
| Several authorities at once | [`examples/compose.multi-ca.yml`](examples/compose.multi-ca.yml) |
| Several sites, several backends | [`examples/compose.multisite.yml`](examples/compose.multisite.yml) |
| Wildcard via DNS-01 | [`examples/compose.wildcard-dns.yml`](examples/compose.wildcard-dns.yml) |
| IP address | [`examples/compose.ip-address.yml`](examples/compose.ip-address.yml) |
| Private ACME server | [`examples/compose.private-acme.yml`](examples/compose.private-acme.yml) |
| Behind a load balancer | [`examples/compose.behind-lb.yml`](examples/compose.behind-lb.yml) |
| Local HTTPS development | [`examples/compose.localdev.yml`](examples/compose.localdev.yml) |

---

## Without Compose: plain `docker run`

Every example above has a one-command equivalent. Three things are not optional:

- **`-v nginx-cert-data:/data`** — without it, certificates and the ACME account
  key live in the container layer and are re-requested on every recreate, which
  exhausts the authority's rate limit within days.
- **`-p 80:80`** — the authority connects to port 80 to validate the challenge,
  even for a site that only serves HTTPS.
- **`-e CERT_EMAIL`** — a real address; authorities reject `example.com`.

Do not add `-e CERT_FORCE_RENEW=true` to a long-lived container: it re-issues on
every scheduler run.

For anything secret, prefer `--env-file secrets.env` over `-e`: values passed
with `-e` end up in your shell history and in `docker inspect`.

### Let's Encrypt

```bash
docker run -d --name nginx-cert               \
           --restart unless-stopped           \
           -p 80:80 -p 443:443                \
           -v nginx-cert-data:/data           \
           -e CERT_EMAIL=you@example.com      \
           -e CERT_DOMAINS=example.com,www.example.com \
           -e CERT_UPSTREAM=10.0.0.5:8080              \
           rac021/nginx-cert:2
```

To reach a backend by container name rather than by IP, put both containers on
the same user-defined network and use that name:

```bash
docker network create web
docker run -d --name app --network web traefik/whoami --port=8080
docker run -d --name nginx-cert               \
           --network web                      \
           --restart unless-stopped           \
           -p 80:80 -p 443:443                \
           -v nginx-cert-data:/data           \
           -e CERT_EMAIL=you@example.com      \
           -e CERT_DOMAINS=example.com        \
           -e CERT_UPSTREAM=app:8080          \
           rac021/nginx-cert:2
```

### Staging first, then production

Validate DNS and firewall against the staging environment, where quotas are
effectively unlimited:

```bash
docker run -d --name nginx-cert               \
           -p 80:80 -p 443:443                \
           -v nginx-cert-data:/data           \
           -e CERT_EMAIL=you@example.com      \
           -e CERT_DOMAINS=example.com        \
           -e CERT_STAGING=true               \
           rac021/nginx-cert:2

docker logs -f nginx-cert
docker exec nginx-cert certme status
```

Once `certme status` shows `valid`, go live by recreating the container without
`CERT_STAGING`:

```bash
docker rm -f nginx-cert
docker run -d --name nginx-cert               \
           --restart unless-stopped           \
           -p 80:80 -p 443:443                \
           -v nginx-cert-data:/data           \
           -e CERT_EMAIL=you@example.com      \
           -e CERT_DOMAINS=example.com        \
           rac021/nginx-cert:2
```

No `--force` is needed: nginx-cert records which authority issued the live
certificate, sees it came from a staging environment, and requests a trusted
replacement by itself.

### Actalis

```bash
docker run -d --name nginx-cert                     \
           --restart unless-stopped                 \
           -p 80:80 -p 443:443                      \
           -v nginx-cert-data:/data                 \
           -e CERT_EMAIL=you@example.com            \
           -e CERT_DOMAINS=data.example.eu          \
           -e CERT_UPSTREAM=10.0.0.5:8080           \
           -e CERT_PROVIDER=actalis                 \
           -e CERT_EAB_KID="$ACTALIS_EAB_KID"       \
           -e CERT_EAB_HMAC_KEY="$ACTALIS_EAB_HMAC" \
           rac021/nginx-cert:2
```

Free tier: one domain per certificate. Declare each host on its own line rather
than as a multi-SAN certificate — see [several certificates](#several-certificates-and-several-authorities-in-one-container).

To keep Actalis as the primary authority while surviving an outage on renewal
day, replace `CERT_PROVIDER=actalis` with:

```bash
           -e CERT_PROVIDER=auto                      \
           -e CERT_PROVIDER_CHAIN=actalis,letsencrypt \
```

### ZeroSSL

An API key is enough — the EAB is derived from it once and cached:

```bash
docker run -d --name nginx-cert                       \
           --restart unless-stopped                   \
           -p 80:80 -p 443:443                        \
           -v nginx-cert-data:/data                   \
           -e CERT_EMAIL=you@example.com              \
           -e CERT_DOMAINS=example.com                \
           -e CERT_UPSTREAM=10.0.0.5:8080             \
           -e CERT_PROVIDER=zerossl                   \
           -e CERT_ZEROSSL_API_KEY="$ZEROSSL_API_KEY" \
           rac021/nginx-cert:2
```

With EAB credentials generated by hand in the dashboard, swap the last line for
`-e CERT_EAB_KID=... -e CERT_EAB_HMAC_KEY=...`.

### Buypass Go SSL

Free, no EAB, 180-day certificates:

```bash
docker run -d --name nginx-cert               \
           --restart unless-stopped           \
           -p 80:80 -p 443:443                \
           -v nginx-cert-data:/data           \
           -e CERT_EMAIL=you@example.com      \
           -e CERT_DOMAINS=example.com        \
           -e CERT_UPSTREAM=10.0.0.5:8080     \
           -e CERT_PROVIDER=buypass           \
           -e CERT_RENEW_DAYS=45              \
           rac021/nginx-cert:2
```

### Google Trust Services

```bash
gcloud publicca external-account-keys create   # gives the KID and HMAC

docker run -d --name nginx-cert                 \
           --restart unless-stopped             \
           -p 80:80 -p 443:443                  \
           -v nginx-cert-data:/data             \
           -e CERT_EMAIL=you@example.com        \
           -e CERT_DOMAINS=example.com          \
           -e CERT_UPSTREAM=10.0.0.5:8080       \
           -e CERT_PROVIDER=google              \
           -e CERT_EAB_KID="$GTS_EAB_KID"       \
           -e CERT_EAB_HMAC_KEY="$GTS_EAB_HMAC" \
           rac021/nginx-cert:2
```

### SSL.com

Same shape, with `CERT_PROVIDER=sslcom` and the EAB credentials from the SSL.com
customer portal:

```bash
docker run -d --name nginx-cert                    \
           --restart unless-stopped                \
           -p 80:80 -p 443:443                     \
           -v nginx-cert-data:/data                \
           -e CERT_EMAIL=you@example.com           \
           -e CERT_DOMAINS=example.com             \
           -e CERT_PROVIDER=sslcom                 \
           -e CERT_EAB_KID="$SSLCOM_EAB_KID"       \
           -e CERT_EAB_HMAC_KEY="$SSLCOM_EAB_HMAC" \
           rac021/nginx-cert:2
```

### Private ACME server

```bash
docker run -d --name nginx-cert                       \
           --restart unless-stopped                   \
           -p 80:80 -p 443:443                        \
           -v nginx-cert-data:/data                   \
           -v ./corp-root-ca.pem:/etc/ssl/certs/corp-root-ca.pem:ro \
           -e CERT_EMAIL=ops@example.com              \
           -e CERT_DOMAINS=service.corp.example.com   \
           -e CERT_UPSTREAM=10.0.0.5:8080             \
           -e CERT_PROVIDER=letsencrypt               \
           -e CERT_ACME_SERVER=https://ca.corp.example.com/acme/acme/directory \
           -e CERT_RENEW_DAYS=10                      \
           -e CERT_RENEW_INTERVAL=6h                  \
           -e CERT_FALLBACK_SELFSIGNED=false          \
           rac021/nginx-cert:2
```

`CERT_PROVIDER` only acts as a carrier here; `CERT_ACME_SERVER` overrides its
directory URL. `letsencrypt` is convenient because it requires no EAB. Mounting
the internal root certificate is what lets the container trust the ACME server's
own HTTPS endpoint.

### Several certificates and several authorities in one container

`CERT_DOMAINS` takes one certificate per line, but a shell one-liner is easier
to write with `;` as the separator — both are accepted:

```bash
docker run -d --name nginx-cert                          \
           --restart unless-stopped                      \
           -p 80:80 -p 443:443                           \
           -v nginx-cert-data:/data                      \
           -e CERT_EMAIL=ops@example.com                 \
           -e CERT_DOMAINS='example.com, www.example.com | upstream=site:8080
                            ; customer.example.eu        | upstream=cust:8080 provider=actalis
                            ; status.example.com         | upstream=stat:8080 provider=buypass
                            ; internal.lan               | upstream=int:8080' \
           -e CERT_EAB_KID="$ACTALIS_EAB_KID"            \
           -e CERT_EAB_HMAC_KEY="$ACTALIS_EAB_HMAC"      \
           rac021/nginx-cert:2
```

Credentials are declared once; each authority reads only what it needs.
`internal.lan` is not publicly resolvable, so it is signed by the local CA
without any network round-trip. Check what happened with:

```bash
docker exec nginx-cert certme status
```

### Wildcard certificate (DNS-01)

A wildcard needs a TXT record, so the DNS provider's API credentials are passed
straight through to the acme.sh module:

```bash
docker run -d --name nginx-cert                  \
           --restart unless-stopped              \
           -p 80:80 -p 443:443                   \
           -v nginx-cert-data:/data              \
           -e CERT_EMAIL=ops@example.com         \
           -e CERT_DOMAINS='*.example.com,example.com' \
           -e CERT_UPSTREAM=10.0.0.5:8080        \
           -e CERT_DNS_PROVIDER=dns_cf           \
           -e CERT_DNS_SLEEP=30                  \
           -e CF_Token="$CF_TOKEN"               \
           -e CF_Account_ID="$CF_ACCOUNT_ID"     \
           rac021/nginx-cert:2
```

Quote `*.example.com`, otherwise the shell expands it against the current
directory. See the [DNS provider table](#wildcard-certificate-dns-01) for other
modules.

### IP address, no domain name

```bash
docker run -d --name nginx-cert               \
           --restart unless-stopped           \
           -p 80:80 -p 443:443                \
           -v nginx-cert-data:/data           \
           -e CERT_EMAIL=ops@example.com      \
           -e CERT_DOMAINS=203.0.113.10       \
           -e CERT_UPSTREAM=10.0.0.5:8080     \
           -e CERT_RENEW_DAYS=2               \
           -e CERT_RENEW_INTERVAL=6h          \
           rac021/nginx-cert:2
```

Let's Encrypt issues IP certificates under the `shortlived` profile (~160 h),
selected automatically — hence the much shorter renewal cycle. For 90-day IP
certificates through ZeroSSL's REST API (paid plan), add
`-e CERT_ZEROSSL_API_KEY=... -e CERT_RENEW_DAYS=30`.

### Local development

```bash
docker run -d --name nginx-cert                      \
           -p 80:80 -p 443:443                       \
           -v nginx-cert-data:/data                  \
           -e CERT_DOMAINS='localhost | upstream=app:8080 ; app.test | upstream=app:8080' \
           -e CERT_HSTS=off                          \
           rac021/nginx-cert:2

docker cp nginx-cert:/data/ca/rootCA.pem .
sudo cp rootCA.pem /usr/local/share/ca-certificates/nginx-cert.crt
sudo update-ca-certificates
```

No `CERT_EMAIL` is needed: these names cannot be validated by any public
authority, so nothing is contacted.

### Behind a load balancer, with your own nginx configuration

```bash
docker run -d --name nginx-cert                          \
           --restart unless-stopped                      \
           -p 8080:8080 -p 8443:8443                     \
           -v nginx-cert-data:/data                      \
           -v ./conf.d:/etc/nginx/conf.d:ro              \
           -e CERT_EMAIL=ops@example.com                 \
           -e CERT_DOMAINS=example.com,www.example.com   \
           -e CERT_HTTP_PORT=8080                        \
           -e CERT_HTTPS_PORT=8443                       \
           -e CERT_REAL_IP_FROM=10.0.0.0/8,172.16.0.0/12 \
           -e CERT_HTTP_REDIRECT=false                   \
           -e CERT_MANAGE_VHOSTS=false                   \
           rac021/nginx-cert:2
```

Certificates stay available to your own servers at
`/data/certs/<name>/{fullchain,privkey,chain}.pem`.

### Day-to-day operations

```bash
docker exec nginx-cert certme status          # authority, expiry, renewal due
docker exec nginx-cert certme status --json   # for monitoring
docker exec nginx-cert certme providers       # what your credentials unlock
docker exec nginx-cert certme config          # effective config, secrets masked
docker exec nginx-cert certme renew           # renew what needs it, now
docker exec nginx-cert certme renew --force   # renew regardless (uses quota)
docker exec nginx-cert certme check           # nginx -t on the generated config
docker logs -f nginx-cert                     # everything, timestamped
```

---

## The `certme` command

```
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
why each authority was skipped or failed. Switching `CERT_STAGING` to `false`
triggers a trusted re-issue on the next run by itself — no `--force` needed.

**A setting seems to have no effect.**
Unknown `CERT_*` variables are reported at startup and ignored, including the
ones removed since version 1 (`CERT_PROXY_PASS_PORT`, `CERT_CRON_SCHEDULE`,
`CERT_RENEWAL_THRESHOLD_DAYS`, `CERT_SELF_SIGNED_CERTIFICATE`). Check the logs
for a warning, and `certme config` for what is actually in effect.

**502 or 504 on HTTPS.**
nginx is running but your application is not reachable at `CERT_UPSTREAM`.
This is deliberate: the proxy starts even when the backend does not exist yet,
instead of refusing to start, and recovers on its own once it is back. Check
that the backend is listening, and that both containers share a **user-defined**
network — the default bridge provides no name resolution, so `app:8080` will
never resolve there.

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

[docs/architecture.md](docs/architecture.md) explains the design decisions —
process model, boot sequence, the provider abstraction, and why certificates are
verified before installation. Read it before changing anything structural.

Migrating from version 1: see [MIGRATION.md](MIGRATION.md).
Changes: [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
