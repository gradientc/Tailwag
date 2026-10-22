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
#  never failed, so Docker's restart policy never got a chance. The timeout is
#  recognised by elapsed time, not by exit code (see "Authenticate" below):
#  the tailscale CLI traps the SIGTERM that BusyBox `timeout` sends and exits 1.
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
# Detecting the timeout. Do NOT rely on the exit code. Measured in the shipped
# image: BusyBox `timeout` sends SIGTERM at the deadline, but the tailscale CLI
# catches it, prints "context canceled" and exits 1 after exactly 120.0 s. (GNU
# timeout would give 124 and an unhandled SIGTERM would give 143, so those two
# are still accepted.) Matching only 124/143 meant the helpful message below was
# never printed and users saw just "tailscale up failed (exit 1)" after two
# silent minutes, with no hint that the control plane was unreachable or an
# interactive login was pending. So: a non-zero exit after running for at least
# UP_TIMEOUT seconds is a timeout, whatever the code.
#
# Elapsed time comes from /proc/uptime, not ${SECONDS}. Bash derives SECONDS
# from the wall clock (measured: an LD_PRELOAD shim stepping the clock +1000 s
# moved SECONDS by exactly 1000), so an NTP step during the call skews it. It
# also counts whole wall-clock seconds: a failure 2.1 s in, started at x.95 s,
# read as 3 s and was reported as a timeout with UP_TIMEOUT=3. /proc/uptime is
# the kernel's boot-time clock (monotonic, centiseconds). Readings truncate to
# 0.01 s, so a real timeout can read 1 cs short; hence the "- 1".
uptime_cs() {
    local up
    read -r up _ < /proc/uptime
    echo $(( 10#${up/./} ))
}
UP_RC=0
UP_START_CS=$(uptime_cs)
timeout "${UP_TIMEOUT}" "${TS}" ${UP_ARGS[@]+"${UP_ARGS[@]}"} || UP_RC=$?
if (( UP_RC != 0 )); then
    if (( UP_RC == 124 || UP_RC == 143 || $(uptime_cs) - UP_START_CS >= UP_TIMEOUT * 100 - 1 )); then
        die "tailscale up did not finish within ${UP_TIMEOUT}s (control plane unreachable, or waiting for interactive login?). Check TS_AUTHKEY and outbound HTTPS to the Tailscale control server."
    fi
    die "tailscale up failed (exit ${UP_RC}). See the tailscale error above."
fi

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
