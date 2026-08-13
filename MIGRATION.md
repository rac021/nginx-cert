# Migrating from nginx-cert 1.x to 2.0

Version 2 is a full rewrite. The container behaves the same way from the
outside — nginx on 80/443, certificates renewed on their own — but the
configuration surface, the certificate paths and the process model all changed.

`latest` still serves 1.x and will not move, so nothing changes until you say
so. Migrating means changing the tag to `rac021/nginx-cert:v2` -- or `:v2.0.1`
to pin the exact release.

Budget ten minutes. There is no in-place upgrade path for the data directory:
version 2 requests fresh certificates on first start, which is a no-op for your
users.

---

## 1. Variable mapping

| 1.x | 2.0 | Notes |
|---|---|---|
| `CERT_ENABLE` | `CERT_ENABLE` | Default flipped from `false` to `true`. |
| `CERT_DOMAINS` | `CERT_DOMAINS` | Same syntax for one certificate; now also accepts one certificate per line. |
| `CERT_EMAIL` | `CERT_EMAIL` | Unchanged. |
| `CERT_STAGING` | `CERT_STAGING` | Default flipped from `true` to `false`. |
| `CERT_FORCE_RENEW` | `CERT_FORCE_RENEW` | Unchanged. |
| `CERT_RENEWAL_THRESHOLD_DAYS` | `CERT_RENEW_DAYS` | Renamed. |
| `CERT_SELF_SIGNED_CERTIFICATE=true` | `CERT_PROVIDER=selfsigned` | Now one provider among others. |
| `CERT_ZEROSSL_API_KEY` | `CERT_ZEROSSL_API_KEY` | Still works; the EAB is now derived from it automatically. |
| `CERT_CRON_SCHEDULE` | `CERT_RENEW_INTERVAL` | **Removed.** cron syntax replaced by a duration: `12h`, `6h`, `45m`. |
| `CERT_PROXY_PASS_PORT` | — | **Removed.** The challenge is served from a webroot; there is no internal proxy left to configure. |

New and worth knowing: `CERT_PROVIDER`, `CERT_PROVIDER_CHAIN`, `CERT_ATTEMPTS`,
`CERT_UPSTREAM`, `CERT_EAB_KID` / `CERT_EAB_HMAC_KEY`, `CERT_DNS_PROVIDER`,
`CERT_SSL_POLICY`. See the [README](README.md#full-variable-reference).

---

## 2. Certificate paths

| 1.x | 2.0 |
|---|---|
| `/etc/letsencrypt/live/<domain>/` | `/data/certs/<name>/` |

The file names are unchanged (`fullchain.pem`, `privkey.pem`, `chain.pem`,
`cert.pem`). `<name>` is the lineage name: the first domain of the line, or the
`name=` option.

If you mount your own `nginx.conf`, update the `ssl_certificate` paths.

---

## 3. Volumes

| 1.x | 2.0 |
|---|---|
| `./letsencrypt:/etc/letsencrypt` | `nginx-cert-data:/data` |

A single volume now holds certificates, the ACME account key, the local CA and
the failure state. Old Let's Encrypt data is not imported: version 2 requests
its own certificates on first start.

---

## 4. Before and after

**1.x**

```yaml
services:
  nginx:
    image: rac021/nginx-cert
    environment:
      - CERT_ENABLE=true
      - CERT_EMAIL=you@example.com
      - CERT_DOMAINS=example.com
      - CERT_PROXY_PASS_PORT=8080
      - CERT_STAGING=false
      - CERT_RENEWAL_THRESHOLD_DAYS=30
    ports: ["80:80", "443:443"]
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
```

**2.0** — the mounted `nginx.conf` is usually no longer needed, because the
HTTPS server is generated for you:

```yaml
services:
  nginx:
    image: rac021/nginx-cert:v2
    environment:
      CERT_EMAIL: you@example.com
      CERT_DOMAINS: example.com
      CERT_UPSTREAM: app:8080
    ports: ["80:80", "443:443"]
    volumes:
      - nginx-cert-data:/data
volumes:
  nginx-cert-data:
```

To keep your own configuration instead, set `CERT_MANAGE_VHOSTS=false` (keep the
generated base) or `CERT_MANAGE_NGINX=false` (own everything), and make sure
your configuration still serves the challenge:

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
    default_type "text/plain";
    try_files $uri =404;
}
```

Note that this replaces the 1.x block, which proxied to
`http://127.0.0.1:8080` — that internal proxy no longer exists.

---

## 5. Behavioural changes to expect

- **The container runs as `nginx` (uid 101), not root.** If you bind-mount a
  host directory on `/data`, `chown 101:101` it first.
- **`docker stop` is graceful.** nginx receives SIGQUIT, finishes in-flight
  requests and exits 0 (1.x was SIGKILLed after the grace period, exit 137).
- **`docker run <image> renew` no longer applies.** Use
  `docker exec <container> certme renew`.
- **The renewal log file `/opt/certme/renew.info` is gone.** All output goes to
  the container's standard error and is visible with `docker logs`.
- **Multi-domain certificates actually work.** In 1.x,
  `CERT_DOMAINS=a.com,b.com` made the lineage-detection check look for a
  directory certbot never created, so a brand-new certificate was requested on
  every start and every nightly cron run — a fast route to a rate-limit block.
- **A failed renewal is now reported.** In 1.x the success/failure test looked at
  the exit status of `tee` instead of the ACME client's, so every renewal was
  reported as successful, including the ones that were not.
- **ZeroSSL renewal works.** In 1.x the nginx location for the ZeroSSL
  validation file used `alias` where `root` was needed, so the validation URL
  returned 404 on every renewal.
- **Self-signed certificates carry SANs.** 1.x generated CN-only certificates,
  which modern browsers and TLS libraries reject outright.
- **Private keys are `600`.** 1.x applied `chmod -R 666` to the certificate
  tree, making keys world-readable *and* world-writable — and, because the same
  command stripped the execute bit from the directories, that is also why the
  container had to run as root.

---

## 6. `actalis.sh`

The standalone script is superseded. Actalis is now a first-class provider:

```yaml
CERT_PROVIDER: actalis
CERT_EAB_KID: ${ACTALIS_EAB_KID}
CERT_EAB_HMAC_KEY: ${ACTALIS_EAB_HMAC}
```

Renewal, nginx reload, and fallback to another authority on failure are handled
automatically. See [`examples/compose.actalis.yml`](examples/compose.actalis.yml).

The script itself no longer ships: nothing in nginx-cert reads it, and a copy
still sitting in your own tree can go with it.

---

## 7. Rollback

Version 1 images remain available, and `latest` still serves them. Pin the digest or use `rac021/nginx-cert:latest`, and restore
your `./letsencrypt` directory — version 2 never writes to it.
