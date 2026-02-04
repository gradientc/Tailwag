#!/usr/bin/env bash
#
# setup_nextdns_relay.sh
#
# Configures NextDNS CLI as a caching DNS relay for a Tailscale network (tailnet).
# Intended to run on multiple servers for redundancy and geographic distribution.
#
# After running this script on each relay server:
#   1. Add the Tailscale IP(s) of your relays to your tailnet's DNS settings
#   2. Enable "Override local DNS" in the Tailscale admin console
#   3. Run `sudo tailscale up --accept-dns=false` on each relay server
#
# Requirements: Ubuntu/Debian, Tailscale installed and authenticated
#
# Usage: sudo ./setup_nextdns_relay.sh <nextdns_profile_id>
#

set -euo pipefail

# --- Configuration -----------------------------------------------------------

# Cache size. 10-20MB is typically sufficient for most home/small-office tailnets.
# NextDNS CLI stores responses in memory; larger caches use more RAM.
CACHE_SIZE="20MB"

# Maximum TTL served to *clients*. This does NOT affect server-side cache.
# Setting 5s forces clients to re-query frequently, ensuring rapid propagation
# of NextDNS config changes (e.g., whitelisting a false positive). The relay's
# own cache still honors upstream TTLs for actual caching benefit.
# See: https://github.com/nextdns/nextdns/wiki/Cache-Configuration
MAX_TTL="5s"

# Whether to also bind to the Tailscale IPv6 address. Recommended for dual-stack
# support and redundancy. Set to "false" if you only want IPv4.
ENABLE_IPV6="true"

# ------------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

# Require root
[[ $(id -u) -eq 0 ]] || error "This script must be run as root"

# Require profile ID argument
NEXTDNS_PROFILE_ID="${1:-}"
if [[ -z "$NEXTDNS_PROFILE_ID" ]]; then
    echo "Usage: $0 <nextdns_profile_id>"
    echo "  Example: $0 abc123"
    echo ""
    echo "Find your profile ID in the NextDNS dashboard under Setup > Endpoints"
    exit 1
fi

# Validate profile ID format (alphanumeric, 6-7 characters)
if [[ ! "$NEXTDNS_PROFILE_ID" =~ ^[a-zA-Z0-9]{6,7}$ ]]; then
    error "Invalid NextDNS profile ID format. Expected 6-7 alphanumeric characters, got: $NEXTDNS_PROFILE_ID"
fi

# Locate tailscale binary
TAILSCALE_BIN=""
for candidate in /usr/bin/tailscale /usr/local/bin/tailscale /opt/tailscale/bin/tailscale tailscale; do
    if command -v "$candidate" &>/dev/null; then
        TAILSCALE_BIN="$candidate"
        break
    fi
done
[[ -n "$TAILSCALE_BIN" ]] || error "Tailscale binary not found. Is Tailscale installed?"

# Verify tailscale is running and authenticated
if ! $TAILSCALE_BIN status &>/dev/null; then
    error "Tailscale is not running or not authenticated. Run 'tailscale up' first."
fi

# Get Tailscale IPv4 address (100.x.y.z)
TS_IPV4=$($TAILSCALE_BIN ip -4 2>/dev/null | head -n1)
if [[ -z "$TS_IPV4" || ! "$TS_IPV4" =~ ^100\. ]]; then
    error "Could not determine Tailscale IPv4 address. Got: '$TS_IPV4'"
fi
log "Tailscale IPv4: $TS_IPV4"

# Get Tailscale IPv6 address (fd7a:115c:a1e0::/48 range)
TS_IPV6=""
if [[ "$ENABLE_IPV6" == "true" ]]; then
    TS_IPV6=$($TAILSCALE_BIN ip -6 2>/dev/null | head -n1)
    if [[ -z "$TS_IPV6" || ! "$TS_IPV6" =~ ^fd7a:115c:a1e0: ]]; then
        log "WARNING: Could not determine Tailscale IPv6 address. Continuing with IPv4 only."
        TS_IPV6=""
    else
        log "Tailscale IPv6: $TS_IPV6"
    fi
fi

# --- Install NextDNS CLI -----------------------------------------------------

log "Installing NextDNS CLI..."

# Install prerequisites
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates

# Add NextDNS repository
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://repo.nextdns.io/nextdns.gpg | gpg --dearmor -o /etc/apt/keyrings/nextdns.gpg
chmod 644 /etc/apt/keyrings/nextdns.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nextdns.gpg] https://repo.nextdns.io/deb stable main" \
    > /etc/apt/sources.list.d/nextdns.list

apt-get update -qq
apt-get install -y nextdns

log "NextDNS CLI installed: $(nextdns version)"

# --- Configure NextDNS CLI ---------------------------------------------------

log "Configuring NextDNS CLI..."

# Stop the service to ensure we can write the config safely
systemctl stop nextdns 2>/dev/null || true

# Write the configuration file directly.
# This avoids issues where 'nextdns config set' appends duplicate lines.
cat > /etc/nextdns.conf <<EOF
profile $NEXTDNS_PROFILE_ID
listen ${TS_IPV4}:53
$( [[ -n "$TS_IPV6" ]] && echo "listen [${TS_IPV6}]:53" )
cache-size $CACHE_SIZE
max-ttl $MAX_TTL
report-client-info true
discovery-dns 100.100.100.100
forwarder ts.net=100.100.100.100
auto-activate false
bogus-priv true
use-hosts true
EOF

log "Configuration written to /etc/nextdns.conf"

# --- Firewall Configuration --------------------------------------------------

# Only configure UFW if it's installed and active
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "Configuring UFW firewall rules..."
    
    # Verify tailscale0 interface exists
    if ip link show tailscale0 &>/dev/null; then
        # Allow DNS (UDP/TCP 53) from Tailscale network only
        ufw allow in on tailscale0 to any port 53 proto udp comment "NextDNS relay (UDP)"
        ufw allow in on tailscale0 to any port 53 proto tcp comment "NextDNS relay (TCP)"
        log "UFW rules added for tailscale0 interface"
    else
        log "WARNING: tailscale0 interface not found. Skipping UFW configuration."
        log "         You may need to manually allow port 53 from your tailnet."
    fi
else
    log "UFW not active. Ensure your firewall allows port 53 from the tailnet."
fi

# --- Start and Verify Service ------------------------------------------------

log "Starting NextDNS service..."
systemctl enable nextdns
systemctl start nextdns

# Wait briefly for service to initialize
sleep 2

# Verify service is running
if ! systemctl is-active --quiet nextdns; then
    log "ERROR: NextDNS service failed to start. Checking logs..."
    journalctl -u nextdns --no-pager -n 20
    error "NextDNS service is not running"
fi

# Verify DNS resolution works
log "Testing DNS resolution..."
TEST_RESULT=$(dig +short +time=5 @"$TS_IPV4" example.com A 2>/dev/null || echo "FAILED")
if [[ "$TEST_RESULT" == "FAILED" || -z "$TEST_RESULT" ]]; then
    log "WARNING: DNS test query failed. The service may still be initializing."
    log "         Try: dig @$TS_IPV4 example.com"
else
    log "DNS test successful: example.com -> $TEST_RESULT"
fi

if [[ -n "$TS_IPV6" ]]; then
    TEST_RESULT6=$(dig +short +time=5 @"$TS_IPV6" example.com A 2>/dev/null || echo "FAILED")
    if [[ "$TEST_RESULT6" == "FAILED" || -z "$TEST_RESULT6" ]]; then
        log "WARNING: IPv6 DNS test failed. IPv4 should still work."
    else
        log "IPv6 DNS test successful"
    fi
fi

# --- Summary -----------------------------------------------------------------

echo ""
echo "=============================================================================="
echo "  NextDNS Relay Setup Complete"
echo "=============================================================================="
echo ""
echo "  Relay addresses for Tailscale DNS settings:"
echo "    IPv4: $TS_IPV4"
[[ -n "$TS_IPV6" ]] && echo "    IPv6: $TS_IPV6"
echo ""
echo "  NextDNS Profile: $NEXTDNS_PROFILE_ID"
echo "  Cache Size: $CACHE_SIZE"
echo "  Client TTL: $MAX_TTL"
echo ""
echo "  Next steps:"
echo "    1. Add the above IP(s) to your tailnet DNS settings:"
echo "       https://login.tailscale.com/admin/dns"
echo ""
echo "    2. Enable 'Override local DNS' in the Tailscale admin console"
echo ""
echo "    3. IMPORTANT: Run this on the relay server to prevent DNS loops:"
echo "       sudo tailscale up --accept-dns=false"
echo ""
echo "    4. For redundancy, run this script on additional servers and add"
echo "       their IPs to your tailnet DNS configuration"
echo ""
echo "  Useful commands:"
echo "    nextdns status          - Check service status"
echo "    nextdns log             - View query logs (Ctrl+C to exit)"
echo "    nextdns config          - View current configuration"
echo "    journalctl -u nextdns   - View service logs"
echo ""
echo "=============================================================================="

# Prompt for immediate accept-dns configuration
echo ""
read -p "Run 'tailscale up --accept-dns=false' now? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Configuring Tailscale to not accept DNS from the tailnet..."
    $TAILSCALE_BIN up --accept-dns=false
    log "Done. This server will no longer use the tailnet's DNS settings."
fi
