# Architecture

This document explains why nginx-cert is built the way it is. It is aimed at
someone about to modify it.

## The problem being solved

Serving HTTPS from a container requires three things to cooperate: a web server,
an ACME client, and a scheduler. The hard part is not any one of them — it is
their interaction:

- **The startup cycle.** The HTTP-01 challenge requires a web server already
  listening on port 80. nginx refuses to start when an `ssl_certificate`
  directive points at a file that does not exist. Neither can go first.
- **The reload contract.** A renewed certificate is worthless until nginx picks
  it up, and a reload with a broken configuration takes the site down.
- **Failure is normal.** Authorities go down, DNS propagates late, quotas run
  out. The service must survive all of it.

Everything below follows from those three constraints.

## Process model

```
PID 1  entrypoint.sh            supervisor: signals, ordering, restart policy
  ├─   nginx (master + workers)
  └─   scheduler loop           sleeps, then execs bin/certme issue
```

`entrypoint.sh` is PID 1 rather than nginx, because PID 1 has to do three things
nginx will not do for us:

1. **Translate SIGTERM into SIGQUIT.** `docker stop` sends SIGTERM; nginx reads
   SIGTERM as *fast shutdown* and drops in-flight requests. SIGQUIT is the
   graceful one.
2. **Sequence the boot** (see below) before nginx exists.
3. **Exit when nginx dies**, so the orchestrator's restart policy applies. A
   supervisor that outlives its payload turns a crash into a silent outage.

The scheduler is a plain `sleep`-and-loop in a subshell, not cron. Cron in a
container means a second log destination, a crontab to write at runtime, and a
timezone to guess. A loop gives durations (`12h`), logs on stderr, and a process
the supervisor can watch and restart.

## Boot sequence

```
1. config::load          parse and validate every CERT_* variable
2. ensure_placeholders   install a local certificate for any name that has none
3. nginx::render         generate nginx.conf + conf.d from templates
4. nginx::test           nginx -t
5. start_nginx           nginx is now serving the ACME webroot
6. certme issue          request the real certificates, verify, install, reload
7. start_scheduler       periodic re-check with jitter
```

Step 2 is the whole trick. Generating a throwaway self-signed certificate takes
milliseconds and no network, so nginx can always start, which means the
challenge can always be served, which means the real certificate can always be
requested. Version 1 attempted step 6 before step 5 and renewal failed on every
restart.

Step 1 happening first is a deliberate cost decision: a typo in
`CERT_RENEW_INTERVAL` must cost two seconds and a clear message, not three
minutes and a rate-limit hit.

## Layering

```
bin/certme, entrypoint.sh      executables — argument handling, orchestration
  lib/issue.sh                 fallback chain, retries, backoff
    providers/*.sh             one function: obtain a bundle in a directory
    lib/certs.sh               verify, install atomically, roll back
    lib/nginx.sh               render, validate, reload
      lib/template.sh          placeholder substitution
lib/config.sh                  the only reader of the environment
lib/{log,util,domains,lock}.sh leaf utilities, no project dependencies
```

Two rules keep this honest:

- **`lib/config.sh` is the only file that reads `CERT_*`.** Everything else
  reads `CFG_*` or receives parameters. That is what makes the startup summary
  trustworthy and the parser unit-testable.
- **`lib/` never calls `providers/`.** Direction of dependency is always
  downward. `issue.sh` is the one place that knows about both.

## The provider abstraction

Let's Encrypt, ZeroSSL, Actalis, Buypass, Google and SSL.com all implement
RFC 8555. They differ in exactly three ways:

| axis | where it lives |
|---|---|
| ACME directory URL | `providers.tsv`, column 4 |
| External Account Binding required | `providers.tsv`, column 5 |
| accepted name kinds (fqdn/wildcard/ip) | `providers.tsv`, column 7 |

So there is one issuance code path (`providers/acme_driver.sh`) parameterised by
a table row. Adding an authority is adding a line; it cannot introduce a new
branch, and it is covered by the existing tests the moment it is added.

Two drivers sit outside ACME because they have to:

- `selfsigned.sh` — no protocol at all; the last link of every chain.
- `zerossl_rest.sh` — ZeroSSL's ACME endpoint does not issue IP-address
  certificates while its REST API does. This is the one genuine exception, and
  it is scoped to that one case.

### The fallback chain

```
for authority in chain:
    for attempt in 1..CERT_ATTEMPTS:
        try; on success -> verify, install, reload, done
        backoff (doubling, capped)
    next authority
finally: selfsigned
```

The chain is filtered before it is walked: an authority that cannot issue the
requested kind of name, or whose EAB credentials are missing, is dropped with a
logged reason rather than attempted and failed.

Ending on a self-signed certificate is a deliberate availability trade-off. A
browser warning is bad; a service that will not start because a certificate
authority had a bad afternoon is worse. `certme status` shows `local` and the
next scheduled run replaces it.

## Certificate safety

A certificate is written to a staging directory first, then:

1. **verified** — the leaf parses, the private key matches it, the validity
   window is open, `fullchain.pem` really contains the chain when an
   intermediate exists, and the SANs cover every requested name (wildcards
   accounted for);
2. **installed atomically** — the live directory is swapped by `rename`, never
   written into;
3. **checked in place** — `nginx -t` runs against the regenerated
   configuration, and the previous certificate is restored if it fails.

Step 1 exists because version 1 shipped a `fullchain.pem` that contained only
the leaf certificate, and nothing checked it.

## Configuration rendering

nginx configuration is regenerated wholesale from templates on every start, not
patched. Runtime `sed` on a shipped configuration file — as version 1 did to
inject a port number — is unauditable, non-idempotent, and silently missed the
second file that needed the same change.

Templates use `%%NAME%%` placeholders. `$` and `${}` belong to nginx and must
survive untouched, which rules out `envsubst` and shell expansion. After
rendering, `template::assert_complete` fails on any leftover placeholder: a
forgotten value would otherwise produce a syntactically valid but semantically
wrong configuration.

Generated files are prefixed `nginx-cert.` in `conf.d/`, and those are the only
files nginx-cert deletes. Everything else the user mounts there is preserved.

## Security posture

- The container runs as uid 101; `nginx` gets `CAP_NET_BIND_SERVICE` via a file
  capability so it can still bind 80/443.
- Private keys are `600` in `750` directories, owned by the runtime user.
- Secrets (EAB HMAC, API keys) are registered with `log::secret` at load time
  and string-replaced out of every message, including command traces at debug
  level.
- acme.sh is pinned by version *and* SHA-256, and `AUTO_UPGRADE=0` prevents it
  from updating itself in production.
- No shell interpolation of user input into commands: everything is passed as
  array arguments.

## Testing strategy

Unit tests cover the pure logic — name classification, spec parsing, chain
construction, template rendering, bundle verification, redaction — with no
Docker and no network, so they run in about a second.

Integration tests exercise what unit tests structurally cannot: real nginx, real
signals, real file permissions. Every scenario there maps to a version-1 defect
that unit tests would never have caught, most notably the shutdown path.

No test contacts a public certificate authority. The suite is deterministic and
consumes no quota; authority-specific behaviour is covered by the declarative
table and its tests.
