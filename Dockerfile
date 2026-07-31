# syntax=docker/dockerfile:1.7
#
# nginx-cert -- nginx with automatic TLS certificate management.
#
# Two stages: the first fetches and verifies acme.sh, the second produces the
# final image. No archive and no build tool survive into the shipped image.

ARG NGINX_VERSION=1.30-alpine-slim

# ---------------------------------------------------------------------------
# Stage 1 -- verified retrieval of acme.sh
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS acme

# Pinned version: an image must be reproducible, and an ACME client that
# updates itself in production is a risk, not a feature.
ARG ACME_SH_VERSION=3.1.4
ARG ACME_SH_SHA256=e5f8e187bbf5251e0cd8891f2622daab9850366bd17bea9f92c2fe2ee091fd32

RUN apk add --no-cache curl tar

RUN set -eux; \
    curl -fsSL -o /tmp/acme.tar.gz \
      "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_SH_VERSION}.tar.gz"; \
    if [ -n "${ACME_SH_SHA256}" ]; then \
      echo "${ACME_SH_SHA256}  /tmp/acme.tar.gz" | sha256sum -c -; \
    else \
      echo "WARNING: ACME_SH_SHA256 is empty, the archive is not verified." >&2; \
    fi; \
    mkdir -p /opt/acme.sh; \
    tar -xzf /tmp/acme.tar.gz -C /opt/acme.sh --strip-components=1; \
    rm -f /tmp/acme.tar.gz; \
    # Only the script and its plugins are needed at runtime.
    cd /opt/acme.sh; \
    find . -maxdepth 1 -mindepth 1 \
         ! -name acme.sh ! -name dnsapi ! -name deploy ! -name notify \
         ! -name LICENSE.md -exec rm -rf {} +; \
    chmod +x /opt/acme.sh/acme.sh

# ---------------------------------------------------------------------------
# Stage 2 -- final image
# ---------------------------------------------------------------------------
FROM nginx:${NGINX_VERSION}

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="nginx-cert" \
      org.opencontainers.image.description="nginx with automatic TLS certificate issuance and renewal (Let's Encrypt, ZeroSSL, Actalis, Google)" \
      org.opencontainers.image.source="https://github.com/rac021/nginx-cert" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# bash    : the scripts use associative arrays and "local -n"
# openssl : key generation, certificate inspection and verification
# curl    : HTTP client for acme.sh and the REST APIs
# jq      : JSON response parsing
# libcap  : needed only for setcap, dropped in the same layer
RUN set -eux; \
    apk add --no-cache bash openssl curl jq ca-certificates tzdata; \
    apk add --no-cache --virtual .build-deps libcap; \
    # Lets nginx bind ports 80/443 without being root.
    setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx; \
    apk del .build-deps; \
    rm -rf /var/cache/apk/*

COPY --from=acme /opt/acme.sh /usr/local/share/acme.sh
RUN ln -sf /usr/local/share/acme.sh/acme.sh /usr/local/bin/acme.sh

ENV NC_ROOT=/opt/nginx-cert \
    LE_WORKING_DIR=/data/acme \
    AUTO_UPGRADE=0

COPY --chmod=0755 entrypoint.sh   ${NC_ROOT}/entrypoint.sh
COPY --chmod=0755 bin/certme      ${NC_ROOT}/bin/certme
COPY --chmod=0644 VERSION         ${NC_ROOT}/VERSION
COPY lib/                         ${NC_ROOT}/lib/
COPY providers/                   ${NC_ROOT}/providers/
COPY templates/                   ${NC_ROOT}/templates/

# One copy of the script, two access paths: the repository layout is mirrored
# inside the image, and "certme" stays on the PATH.
RUN ln -sf ${NC_ROOT}/bin/certme /usr/local/bin/certme

# The image runs unprivileged: every directory nginx-cert writes to at runtime
# belongs to the nginx user.
RUN set -eux; \
    mkdir -p /data /var/www/acme/.well-known /var/www/html /etc/nginx/snippets /var/run/nginx; \
    printf '<!doctype html><meta charset=utf-8><title>nginx-cert</title><h1>nginx-cert</h1><p>No upstream configured (CERT_UPSTREAM).</p>\n' \
      > /var/www/html/index.html; \
    chown -R nginx:nginx /data /var/www /etc/nginx /var/cache/nginx /var/log/nginx /var/run/nginx; \
    chmod 755 /data

USER nginx

EXPOSE 80 443

# The entrypoint translates SIGTERM into SIGQUIT for nginx: graceful shutdown,
# no in-flight request is cut.
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD certme health || exit 1

ENTRYPOINT ["/opt/nginx-cert/entrypoint.sh"]
CMD ["serve"]
