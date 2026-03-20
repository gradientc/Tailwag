# =============================================================================
#  TAILWAG DOCKER  ·  v0.1.0
#  A portable, caching NextDNS relay for Tailscale networks.
#
#  Architecture:
#    Alpine base  →  s6-overlay v3 (PID 1, process supervision)
#                 →  tailscaled    (WireGuard tunnel, managed by s6)
#                 →  nextdns       (DNS53-to-DoH proxy with LRU cache)
#
#  Multi-arch: builds for linux/amd64 and linux/arm64 (Pi, Apple Silicon)
#
#  Build:
#    docker build -t tailwag .
#    docker buildx build --platform linux/amd64,linux/arm64 -t tailwag .
#
# =============================================================================

# --- Build args --------------------------------------------------------------

ARG ALPINE_VERSION=3.23.3
ARG S6_OVERLAY_VERSION=3.2.2.0
ARG TAILSCALE_VERSION=1.96.2
ARG NEXTDNS_VERSION=1.47.1

# =============================================================================
#  Stage 1: Download s6-overlay for the target architecture
# =============================================================================

FROM alpine:${ALPINE_VERSION} AS s6-downloader
ARG S6_OVERLAY_VERSION
ARG TARGETARCH

RUN apk add --no-cache curl tar xz \
    && mkdir -p /s6 /tmp/s6 \
    && S6_BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
    # s6-overlay noarch (scripts, configs)
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz"        -o /tmp/s6/noarch.tar.xz \
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz.sha256" -o /tmp/s6/noarch.tar.xz.sha256 \
    && (cd /tmp/s6 && sed -i 's|s6-overlay-noarch.tar.xz|noarch.tar.xz|' noarch.tar.xz.sha256 && sha256sum -c noarch.tar.xz.sha256) \
    && tar -C /s6 -Jxp < /tmp/s6/noarch.tar.xz \
    # s6-overlay arch-specific binaries
    && S6_ARCH=$(case "${TARGETARCH}" in amd64) echo x86_64;; arm64) echo aarch64;; *) echo "${TARGETARCH}";; esac) \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz"        -o /tmp/s6/arch.tar.xz \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz.sha256" -o /tmp/s6/arch.tar.xz.sha256 \
    && (cd /tmp/s6 && sed -i "s|s6-overlay-${S6_ARCH}.tar.xz|arch.tar.xz|" arch.tar.xz.sha256 && sha256sum -c arch.tar.xz.sha256) \
    && tar -C /s6 -Jxp < /tmp/s6/arch.tar.xz \
    && rm -rf /tmp/s6

# =============================================================================
#  Stage 2: Download Tailscale binaries
# =============================================================================

FROM alpine:${ALPINE_VERSION} AS tailscale-downloader
ARG TAILSCALE_VERSION
ARG TARGETARCH

RUN apk add --no-cache curl tar \
    && TS_ARCH=$(case "${TARGETARCH}" in amd64) echo amd64;; arm64) echo arm64;; *) echo "${TARGETARCH}";; esac) \
    # Note: pkgs.tailscale.com does not publish .sha256 sidecar files for Linux
    # tarballs (only for Windows installers), so we rely on HTTPS transport
    # integrity from Tailscale's official package server.
    && curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${TS_ARCH}.tgz" \
       | tar -xz --strip-components=1 -C /usr/local/bin \
            tailscale_${TAILSCALE_VERSION}_${TS_ARCH}/tailscale \
            tailscale_${TAILSCALE_VERSION}_${TS_ARCH}/tailscaled

# =============================================================================
#  Stage 3: Download NextDNS CLI
# =============================================================================

FROM alpine:${ALPINE_VERSION} AS nextdns-downloader
ARG NEXTDNS_VERSION
ARG TARGETARCH

RUN apk add --no-cache curl tar \
    && NDNS_ARCH=$(case "${TARGETARCH}" in amd64) echo linux_amd64;; arm64) echo linux_arm64;; *) echo "linux_${TARGETARCH}";; esac) \
    && NDNS_BASE="https://github.com/nextdns/nextdns/releases/download/v${NEXTDNS_VERSION}" \
    && curl -fsSL "${NDNS_BASE}/nextdns_${NEXTDNS_VERSION}_${NDNS_ARCH}.tar.gz"  -o /tmp/nextdns.tar.gz \
    && curl -fsSL "${NDNS_BASE}/nextdns_${NEXTDNS_VERSION}_checksums.txt"         -o /tmp/nextdns_checksums.txt \
    && grep "${NDNS_ARCH}.tar.gz" /tmp/nextdns_checksums.txt \
       | sed "s|nextdns_${NEXTDNS_VERSION}_${NDNS_ARCH}.tar.gz|/tmp/nextdns.tar.gz|" \
       | sha256sum -c \
    && tar -xz -C /usr/local/bin nextdns < /tmp/nextdns.tar.gz \
    && rm -f /tmp/nextdns.tar.gz /tmp/nextdns_checksums.txt

# =============================================================================
#  Stage 4: Final image
# =============================================================================

FROM alpine:${ALPINE_VERSION}

LABEL maintainer="Tailwag" \
      description="Portable caching NextDNS relay for Tailscale networks" \
      org.opencontainers.image.source="https://github.com/gradientc/Tailwag"

# Runtime dependencies:
#   iptables  — required for Tailscale exit node / subnet router NAT rules
#   iproute2  — ip command for address/route management
#   ip6tables — IPv6 firewall rules (pulled in by iptables)
#   ca-certificates — TLS verification for DoH upstream and Tailscale coordination
#   bash      — s6-overlay scripts (minimal Alpine bash, ~1MB)
#   bind-tools — dig for health checks (optional but worth the ~2MB)
RUN apk add --no-cache \
        iptables \
        ip6tables \
        iproute2 \
        ca-certificates \
        bash \
        bind-tools \
    # Tailscale's critical iptables-legacy workaround:
    # Alpine 3.19+ defaults to nf_tables backend, but Tailscale's firewall
    # management expects iptables-legacy. Without these symlinks, exit node
    # routing silently fails. This matches Tailscale's own Dockerfile.
    && ln -sf /sbin/iptables-legacy  /sbin/iptables \
    && ln -sf /sbin/ip6tables-legacy /sbin/ip6tables

# Copy s6-overlay from builder
COPY --from=s6-downloader /s6/ /

# Copy binaries from builders
COPY --from=tailscale-downloader /usr/local/bin/tailscale  /usr/local/bin/tailscale
COPY --from=tailscale-downloader /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=nextdns-downloader   /usr/local/bin/nextdns    /usr/local/bin/nextdns

# Copy s6 service definitions and init scripts
COPY rootfs/ /

# State directories
RUN mkdir -p /var/lib/tailscale /var/run/tailscale /run/nextdns

# --- Environment variables (user-configurable) -------------------------------
#
# Required:
#   NEXTDNS_PROFILE     Your NextDNS profile ID (e.g., abc123)
#   TS_AUTHKEY          Tailscale auth key or OAuth client secret
#
# Optional — Tailscale:
#   TS_HOSTNAME         Node hostname on tailnet (default: tailwag)
#   TS_EXTRA_ARGS       Extra args for 'tailscale up' (e.g., --advertise-exit-node)
#   TS_ACCEPT_DNS       Accept DNS from tailnet (default: false — prevents loops)
#   TS_USERSPACE        Use userspace networking (default: false — kernel mode)
#   TS_STATE_DIR        Tailscale state directory (default: /var/lib/tailscale)
#   TS_DEBUG_FIREWALL_MODE  Firewall mode override (auto/nftables/iptables)
#
# Optional — NextDNS:
#   NEXTDNS_CACHE_SIZE  In-memory cache size (default: 10MB)
#   NEXTDNS_MAX_TTL     Max TTL served to clients (default: 5s)
#   NEXTDNS_LISTEN      Listen address (default: :53)
#   NEXTDNS_EXTRA_ARGS  Extra args for nextdns run
#
# Optional — Features:
#   EXIT_NODE           Set to "true" to advertise as exit node
#   SUBNET_ROUTES       Comma-separated CIDR routes to advertise

ENV TS_HOSTNAME="tailwag" \
    TS_ACCEPT_DNS="false" \
    TS_USERSPACE="false" \
    TS_STATE_DIR="/var/lib/tailscale" \
    NEXTDNS_CACHE_SIZE="10MB" \
    NEXTDNS_MAX_TTL="5s" \
    NEXTDNS_LISTEN=":53"

# s6-overlay behaviour: stop the container if any service fails permanently
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Expose DNS port (only reachable via tailnet in practice)
EXPOSE 53/udp 53/tcp

# Health check: can we resolve through the local relay?
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD dig +short +time=3 +tries=1 @127.0.0.1 example.com A || exit 1

# s6-overlay is PID 1
ENTRYPOINT ["/init"]
