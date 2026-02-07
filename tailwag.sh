#!/usr/bin/env bash
# ==============================================================================
#  TAILWAG  ·  Model 02
#  A caching DNS relay for Tailscale networks. One script. Full stack.
# ==============================================================================
#
#  What it does:
#    - Installs NextDNS CLI via the official apt repository
#    - Configures it as a DNS53 relay bound to your Tailscale addresses
#    - Enables dual-stack (IPv4 + IPv6) by default
#    - Installs a systemd drop-in so the service survives reboots
#    - Sets up UFW rules if your firewall is active
#    - Prevents DNS loops on the relay server itself
#
#  Designed to be run multiple times. Each run produces a clean, identical
#  configuration state regardless of what was there before.
#
#  Usage:
#    sudo ./tailwag.sh <nextdns_profile_id>
#
#  After running on each relay:
#    1. Add the Tailscale IP(s) as Custom Nameservers in your tailnet DNS
#       https://login.tailscale.com/admin/dns
#    2. Enable "Override local DNS"
#    3. The script handles --accept-dns=false for you (see final prompt)
#
#  Requirements: Debian/Ubuntu, Tailscale installed and authenticated
#
# ==============================================================================

set -euo pipefail

readonly VERSION="0.2.0"

# --- Tuning ------------------------------------------------------------------
#
# These defaults are good for home/small-office tailnets. Adjust if you know
# what you're doing; the comments explain the trade-offs.

# In-memory cache. 10-20 MB covers most tailnets without meaningful RAM cost.
CACHE_SIZE="20MB"

# Max TTL served to clients. Does NOT affect the relay's own upstream cache.
# 5s forces frequent re-queries so NextDNS config changes (e.g., whitelisting
# a false positive) propagate to clients almost immediately.
# Reference: https://github.com/nextdns/nextdns/wiki/Cache-Configuration
MAX_TTL="5s"

# Bind to the Tailscale IPv6 address in addition to IPv4.
# Both are always assigned by Tailscale; dual-stack is free redundancy.
ENABLE_IPV6=true

# --- Internals (no user-serviceable parts below) -----------------------------

log()   { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn()  { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()   { printf '[%s] FATAL: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# -- Pre-flight ---------------------------------------------------------------

[[ $(id -u) -eq 0 ]] || die "Must run as root.  sudo $0 <profile_id>"

NEXTDNS_PROFILE="${1:-}"
if [[ -z "$NEXTDNS_PROFILE" ]]; then
    printf 'Usage: %s <nextdns_profile_id>\n' "$0"
    printf '  Find yours at: https://my.nextdns.io → Setup → Endpoints\n'
    exit 1
fi

[[ "$NEXTDNS_PROFILE" =~ ^[a-zA-Z0-9]{6,7}$ ]] \
    || die "Invalid profile ID '$NEXTDNS_PROFILE'. Expected 6-7 alphanumeric characters."

# -- Locate Tailscale ---------------------------------------------------------

TS_BIN=""
for candidate in tailscale /usr/bin/tailscale /usr/local/bin/tailscale; do
    if command -v "$candidate" &>/dev/null; then
        TS_BIN="$candidate"
        break
    fi
done
[[ -n "$TS_BIN" ]] || die "Tailscale binary not found. Is it installed?"

$TS_BIN status &>/dev/null \
    || die "Tailscale is not running or not authenticated. Run 'tailscale up' first."

# -- Discover Tailscale addresses ---------------------------------------------

TS_IPV4=$($TS_BIN ip -4 2>/dev/null | head -n1)
[[ "$TS_IPV4" =~ ^100\. ]] \
    || die "Could not get a valid Tailscale IPv4 address (got: '${TS_IPV4:-<empty>}')"
log "Tailscale IPv4: $TS_IPV4"

TS_IPV6=""
if [[ "$ENABLE_IPV6" == true ]]; then
    TS_IPV6=$($TS_BIN ip -6 2>/dev/null | head -n1)
    if [[ "$TS_IPV6" =~ ^fd7a:115c:a1e0: ]]; then
        log "Tailscale IPv6: $TS_IPV6"
    else
        warn "Could not get Tailscale IPv6 address. Continuing IPv4-only."
        TS_IPV6=""
    fi
fi

# -- Install NextDNS CLI (idempotent) -----------------------------------------

if command -v nextdns &>/dev/null; then
    log "NextDNS CLI already present: $(nextdns version)"
else
    log "Installing NextDNS CLI..."

    apt-get update -qq
    apt-get install -y -qq curl gnupg ca-certificates

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://repo.nextdns.io/nextdns.gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/nextdns.gpg
    chmod 644 /etc/apt/keyrings/nextdns.gpg

    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/nextdns.gpg] https://repo.nextdns.io/deb stable main\n' \
        "$(dpkg --print-architecture)" \
        > /etc/apt/sources.list.d/nextdns.list

    apt-get update -qq
    apt-get install -y nextdns

    log "Installed: $(nextdns version)"
fi

# -- Write configuration ------------------------------------------------------
# Written atomically via cat. Wipes any previous state, which is the point:
# run the script again and you get a known-good config every time.

log "Writing /etc/nextdns.conf ..."

systemctl stop nextdns 2>/dev/null || true

{
    printf 'profile %s\n' "$NEXTDNS_PROFILE"
    printf 'listen %s:53\n' "$TS_IPV4"
    [[ -n "$TS_IPV6" ]] && printf 'listen [%s]:53\n' "$TS_IPV6"
    printf 'cache-size %s\n' "$CACHE_SIZE"
    printf 'max-ttl %s\n' "$MAX_TTL"
    cat <<'STATIC'
report-client-info true
discovery-dns 100.100.100.100
forwarder ts.net=100.100.100.100
auto-activate false
bogus-priv true
use-hosts true
STATIC
} > /etc/nextdns.conf

# -- Fix boot ordering (the actual reason it breaks on reboot) ----------------
#
# NextDNS ships a systemd unit with "After=network.target" — but that fires
# long before tailscaled has established its tunnel and assigned the fd7a::
# address. Result: bind() fails, service crashes, no DNS.
#
# The fix is a drop-in override that:
#   1. Waits for tailscaled.service to be up
#   2. Runs a pre-start check that blocks until the Tailscale IPv4 address
#      is actually present on an interface (up to 90 seconds)
#   3. Adds restart-on-failure so transient timing issues self-heal

DROPIN_DIR="/etc/systemd/system/nextdns.service.d"
DROPIN_FILE="${DROPIN_DIR}/tailwag.conf"

log "Installing systemd drop-in: $DROPIN_FILE"
mkdir -p "$DROPIN_DIR"

cat > "$DROPIN_FILE" <<EOF
# Installed by Tailwag ${VERSION}
# Ensures NextDNS waits for Tailscale before binding.

[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
# Block until the Tailscale IPv4 is actually routable.
# Checks once per second, gives up after 90s.
ExecStartPre=/bin/bash -c ' \\
    for i in \$(seq 1 90); do \\
        ip addr show | grep -q "${TS_IPV4}" && exit 0; \\
        sleep 1; \\
    done; \\
    echo "Tailwag: timed out waiting for ${TS_IPV4}" >&2; \\
    exit 1'

Restart=on-failure
RestartSec=5
EOF

systemctl daemon-reload

# -- Firewall (UFW) -----------------------------------------------------------

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    if ip link show tailscale0 &>/dev/null; then
        log "Configuring UFW rules on tailscale0..."

        # ufw is idempotent for identical rules; safe to re-run.
        ufw allow in on tailscale0 to any port 53 proto udp \
            comment "Tailwag DNS relay" >/dev/null
        ufw allow in on tailscale0 to any port 53 proto tcp \
            comment "Tailwag DNS relay" >/dev/null
    else
        warn "tailscale0 interface not found. Skipping UFW rules."
    fi
else
    log "UFW inactive or absent. Ensure port 53 is reachable from your tailnet."
fi

# -- Start & verify -----------------------------------------------------------

log "Starting NextDNS service..."
systemctl enable nextdns >/dev/null 2>&1
systemctl restart nextdns
sleep 2

if ! systemctl is-active --quiet nextdns; then
    warn "Service did not start cleanly. Recent logs:"
    journalctl -u nextdns --no-pager -n 15
    die "nextdns.service is not running."
fi

# Quick smoke test: can we actually resolve through the relay?
if command -v dig &>/dev/null; then
    PROBE=$(dig +short +time=5 +tries=1 @"$TS_IPV4" example.com A 2>/dev/null || true)
    if [[ -n "$PROBE" ]]; then
        log "DNS probe OK: example.com -> $PROBE"
    else
        warn "DNS probe via $TS_IPV4 returned nothing. May still be warming up."
    fi

    if [[ -n "$TS_IPV6" ]]; then
        PROBE6=$(dig +short +time=5 +tries=1 @"$TS_IPV6" example.com A 2>/dev/null || true)
        if [[ -n "$PROBE6" ]]; then
            log "DNS probe OK (IPv6): example.com -> $PROBE6"
        else
            warn "IPv6 DNS probe returned nothing. IPv4 path is still functional."
        fi
    fi
else
    log "dig not found; skipping DNS probe. Install dnsutils to enable it."
fi

# -- Summary -------------------------------------------------------------------

cat <<SUMMARY

==============================================================================
  TAILWAG  ·  Relay Active
==============================================================================

  Addresses:
    IPv4  ${TS_IPV4}
$( [[ -n "$TS_IPV6" ]] && printf '    IPv6  %s\n' "$TS_IPV6" )
  Profile:  ${NEXTDNS_PROFILE}
  Cache:    ${CACHE_SIZE}  ·  Client TTL: ${MAX_TTL}

  Next steps
  ----------
  1. Add the address(es) above as Custom Nameservers:
     https://login.tailscale.com/admin/dns

  2. Enable "Override local DNS" in the same panel.

  3. For redundancy, repeat on additional servers.

  Useful commands
  ---------------
  nextdns status                Check relay health
  nextdns log                   Live query log (Ctrl-C to stop)
  cat /etc/nextdns.conf         View configuration
  journalctl -u nextdns -f      Follow service logs

==============================================================================
SUMMARY

# -- Loop prevention -----------------------------------------------------------

printf 'Run "tailscale up --accept-dns=false" on this server now? [y/N] '
read -r REPLY
if [[ "${REPLY,,}" == "y" ]]; then
    log "Applying --accept-dns=false ..."
    $TS_BIN up --accept-dns=false --reset
    log "Done. This relay will not consume its own DNS."
fi
