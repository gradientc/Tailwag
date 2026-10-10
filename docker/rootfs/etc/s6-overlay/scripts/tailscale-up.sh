#!/command/with-contenv bash
# shellcheck shell=bash
# =============================================================================
#  svc-tailscale-up  ·  s6-overlay oneshot
#  Authenticates with Tailscale and blocks until the tunnel is up with a
#  routable 100.x.x.x address assigned. This ensures NextDNS can bind to
#  the Tailscale interface without the race condition that plagued the
#  original systemd-based Tailwag.
#
#  The environment is the source of truth for node preferences: `tailscale up`
#  runs with --reset on every start. With persisted state, a plain `tailscale
#  up` refuses to run whenever a previously set non-default preference is
#  omitted ("changing settings via 'tailscale up' requires mentioning all
#  non-default flags"), so turning EXIT_NODE off, dropping SUBNET_ROUTES or
#  editing TS_EXTRA_ARGS between restarts made this oneshot fail and stopped
#  the container. The flip side: prefs changed with `tailscale set` inside the
#  container are reverted on the next restart. Put them in the env instead.
#
#  `tailscale up` itself is bounded (120s). Unbounded, a stuck control plane
#  left this oneshot unfinished forever: NextDNS never started and stage 2
#  never failed, so Docker's restart policy never got a chance.
# =============================================================================

set -euo pipefail

log()  { printf '[tailwag] tailscale-up: %s\n' "$*"; }
die()  { printf '[tailwag] tailscale-up: FATAL: %s\n' "$*" >&2; exit 1; }

SOCKET="/var/run/tailscale/tailscaled.sock"
TS="/usr/local/bin/tailscale"
UP_TIMEOUT=120

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
    --reset
    --accept-dns="${TS_ACCEPT_DNS:-false}"
    --hostname="${TS_HOSTNAME:-tailwag}"
)

# Auth key (works for both regular auth keys and OAuth client secrets).
# An OAuth client secret (tskey-client-...) can only register tag-owned
# nodes: without --advertise-tags, Tailscale rejects the login and the node
# never comes up. Fail here with the fix instead of after a control-plane
# round trip.
if [[ -n "${TS_AUTHKEY:-}" ]]; then
    if [[ "${TS_AUTHKEY}" == tskey-client-* && "${TS_EXTRA_ARGS:-}" != *--advertise-tags* ]]; then
        die "TS_AUTHKEY is an OAuth client secret, which requires tags. Set TS_EXTRA_ARGS=--advertise-tags=tag:<name> (e.g. tag:dns-relay), with that tag in your tailnet policy tagOwners and granted to the OAuth client. See https://tailscale.com/kb/1215/oauth-clients"
    fi
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

log "Running tailscale up (timeout ${UP_TIMEOUT}s)..."
# Quote the binary and expand the arg array safely. The ${arr[@]+"${arr[@]}"}
# form avoids "unbound variable" under `set -u` if the array were ever empty
# (it is not today — we always push --socket/up/--reset/--accept-dns/...).
#
# Exit status on timeout: GNU timeout returns 124, but the BusyBox applet in
# this Alpine image execs the command and lets SIGTERM kill it, so the shell
# sees 143 (128 + SIGTERM). Treat both as a timeout.
UP_RC=0
timeout "${UP_TIMEOUT}" "${TS}" ${UP_ARGS[@]+"${UP_ARGS[@]}"} || UP_RC=$?
case "${UP_RC}" in
    0)       ;;
    124|143) die "tailscale up did not finish within ${UP_TIMEOUT}s (control plane unreachable, or waiting for interactive login?). Check TS_AUTHKEY and outbound HTTPS to the Tailscale control server." ;;
    *)       die "tailscale up failed (exit ${UP_RC}). See the tailscale error above." ;;
esac

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
