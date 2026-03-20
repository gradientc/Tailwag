#!/command/with-contenv bash
# shellcheck shell=bash
# =============================================================================
#  svc-tailscale-up  ·  s6-overlay oneshot
#  Authenticates with Tailscale and blocks until the tunnel is up with a
#  routable 100.x.x.x address assigned. This ensures NextDNS can bind to
#  the Tailscale interface without the race condition that plagued the
#  original systemd-based Tailwag.
# =============================================================================

set -euo pipefail

log()  { printf '[tailwag] tailscale-up: %s\n' "$*"; }
die()  { printf '[tailwag] tailscale-up: FATAL: %s\n' "$*" >&2; exit 1; }

SOCKET="/var/run/tailscale/tailscaled.sock"
TS="/usr/local/bin/tailscale"

# --- Wait for tailscaled socket ----------------------------------------------

log "Waiting for tailscaled socket..."
for _ in $(seq 1 30); do
    if [[ -S "${SOCKET}" ]]; then
        break
    fi
    sleep 1
done
[[ -S "${SOCKET}" ]] || die "tailscaled socket not found after 30s"

# --- Build tailscale up arguments --------------------------------------------

UP_ARGS=(
    --socket="${SOCKET}"
    up
    --accept-dns="${TS_ACCEPT_DNS:-false}"
    --hostname="${TS_HOSTNAME:-tailwag}"
)

# Auth key (works for both regular auth keys and OAuth client secrets)
if [[ -n "${TS_AUTHKEY:-}" ]]; then
    UP_ARGS+=(--authkey="${TS_AUTHKEY}")
fi

# Exit node
if [[ "${EXIT_NODE:-false}" == "true" ]]; then
    log "Advertising as exit node"
    UP_ARGS+=(--advertise-exit-node)
fi

# Subnet routes
if [[ -n "${SUBNET_ROUTES:-}" ]]; then
    log "Advertising routes: ${SUBNET_ROUTES}"
    UP_ARGS+=(--advertise-routes="${SUBNET_ROUTES}")
fi

# Extra args (escape hatch for anything we haven't parameterized)
if [[ -n "${TS_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    UP_ARGS+=(${TS_EXTRA_ARGS})
fi

# --- Authenticate ------------------------------------------------------------

log "Running tailscale up..."
$TS ${UP_ARGS[@]+"${UP_ARGS[@]}"}

# --- Wait for a routable Tailscale IP ----------------------------------------
# This is the critical fix from the original Tailwag: the tunnel needs time
# to establish after 'tailscale up' returns. We poll until we get a 100.x IP.

log "Waiting for Tailscale IP assignment..."
for _ in $(seq 1 90); do
    TS_IP=$($TS ip -4 2>/dev/null || true)
    if [[ "${TS_IP}" =~ ^100\. ]]; then
        log "Tailscale IPv4: ${TS_IP}"

        TS_IP6=$($TS ip -6 2>/dev/null | head -n1 || true)
        if [[ -n "${TS_IP6}" ]]; then
            log "Tailscale IPv6: ${TS_IP6}"
        fi

        log "Tunnel established. NextDNS can start."
        exit 0
    fi
    sleep 1
done

die "Timed out waiting for Tailscale IP after 90s"
