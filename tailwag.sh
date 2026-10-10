#!/usr/bin/env bash
# shellcheck shell=bash
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
#    - Prevents DNS loops on the relay server itself: applies
#      `tailscale set --accept-dns=false` on every run, interactive or not
#      (opt out with TAILWAG_KEEP_ACCEPT_DNS=1; other node settings are
#      left untouched, there is no --reset)
#
#  Designed to be run multiple times. Each run produces a clean, identical
#  configuration state regardless of what was there before.
#
#  Usage:
#    sudo ./tailwag.sh <nextdns_profile_id>
#    sudo TAILWAG_KEEP_ACCEPT_DNS=1 ./tailwag.sh <id>   # skip the loop guard
#
#  Exit codes:
#    0  Installed and healthy
#    1  Not installed (fatal error before or during setup)
#    2  Usage error (no profile and no prompt possible, invalid profile)
#    3  Installed but needs attention (loop guard not applied, DNS probe
#       failed). NextDNS is running; read the WARN lines.
#
#  After running on each relay:
#    1. Add the Tailscale IP(s) as Custom Nameservers in your tailnet DNS
#       https://login.tailscale.com/admin/dns
#    2. Enable "Override local DNS"
#
#  Requirements: Debian/Ubuntu, Tailscale installed and authenticated
#
# ==============================================================================

set -euo pipefail

readonly VERSION="0.2.2"

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

# Exit status for "installed, but needs attention" paths (see header). Never
# die once nextdns is live: exit 1 would claim nothing was installed.
EXIT_CODE=0

usage() {
    printf 'Usage: %s <nextdns_profile_id>\n' "$0" >&2
    printf '  Find yours at: https://my.nextdns.io → Setup → Endpoints\n' >&2
    exit 2
}

# Read one line from the user if any terminal is actually openable.
# Returns 1 (no prompt possible) instead of crashing under set -e.
#
# `[[ -r /dev/tty ]]` is not a usable test: /dev/tty is mode 0666, so it is
# "readable" even for a process with no controlling terminal (setsid, cron,
# `ssh host sudo ./tailwag.sh` without -t). Opening it then fails with ENXIO,
# and under set -e that failed redirection killed the script, once after
# nextdns was already live. Try the open itself and treat failure as "no
# prompt possible".
prompt_read() {  # usage: prompt_read VAR "Question: "
    local __var="$1" __q="$2" __ans=""
    if [[ -t 0 ]]; then
        read -rp "$__q" __ans || return 1
    elif { exec 3</dev/tty; } 2>/dev/null; then
        # Piped input (e.g. curl | bash) with a terminal available.
        # Prompt on stderr so it shows even if stdout is redirected.
        printf '%s' "$__q" >&2
        read -r __ans <&3 || { exec 3<&-; return 1; }
        exec 3<&-
    else
        return 1
    fi
    printf -v "$__var" '%s' "$__ans"
}

# Exact address match on one interface: field 4 of `ip -o addr show`, prefix
# length removed, string equality. Never a substring grep: `grep 100.64.1.2`
# also matches 100.64.1.23. Same matching as wait-listen-addrs below.
on_iface() {  # usage: on_iface ADDR IFACE
    local want="${1,,}" iface="$2" _idx _dev _fam cidr _rest
    while read -r _idx _dev _fam cidr _rest; do
        [[ "${cidr%/*}" == "$want" ]] && return 0
    done < <(ip -o addr show dev "$iface" 2>/dev/null || true)
    return 1
}

# -- Pre-flight ---------------------------------------------------------------

[[ $(id -u) -eq 0 ]] || die "Must run as root.  sudo $0 <profile_id>"

NEXTDNS_PROFILE="${1:-}"
if [[ -z "$NEXTDNS_PROFILE" ]]; then
    prompt_read NEXTDNS_PROFILE "Enter your NextDNS Profile ID: " || usage
fi

if [[ ! "$NEXTDNS_PROFILE" =~ ^[a-zA-Z0-9]{6,7}$ ]]; then
    printf "[%s] FATAL: Invalid profile ID '%s'. Expected 6-7 alphanumeric characters.\n" \
        "$(date '+%H:%M:%S')" "$NEXTDNS_PROFILE" >&2
    usage
fi

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

# The interface that carries the Tailscale address. Normally tailscale0, but
# tailscaled --tun=<name> renames it, and the boot gate below must watch the
# right one or it waits for an address that will never appear there.
TS_IFACE="tailscale0"
while read -r _idx ifname _fam cidr _rest; do
    if [[ "${cidr%/*}" == "$TS_IPV4" ]]; then
        TS_IFACE="$ifname"
        break
    fi
done < <(ip -o -4 addr show 2>/dev/null || true)
on_iface "$TS_IPV4" "$TS_IFACE" \
    || warn "$TS_IPV4 is not on any interface yet; assuming $TS_IFACE."
log "Tailscale interface: $TS_IFACE"

TS_IPV6=""
if [[ "$ENABLE_IPV6" == true ]]; then
    TS_IPV6=$($TS_BIN ip -6 2>/dev/null | head -n1)
    if [[ ! "$TS_IPV6" =~ ^fd7a:115c:a1e0: ]]; then
        warn "Could not get Tailscale IPv6 address. Continuing IPv4-only."
        TS_IPV6=""
    elif ! on_iface "$TS_IPV6" "$TS_IFACE"; then
        # `tailscale ip -6` reports the netmap address even when the kernel
        # has IPv6 disabled (net.ipv6.conf.all.disable_ipv6=1). The address is
        # then never added to the interface, the [fd7a:...]:53 bind fails and
        # nextdns restart-loops forever. Only bind what is actually on-link.
        warn "IPv6 address $TS_IPV6 assigned but not on $TS_IFACE (IPv6 disabled?). Continuing IPv4-only."
        TS_IPV6=""
    else
        log "Tailscale IPv6: $TS_IPV6"
    fi
fi

# -- Install NextDNS CLI (idempotent) -----------------------------------------

if command -v nextdns &>/dev/null; then
    log "NextDNS CLI already present: $(nextdns version)"
else
    log "Installing NextDNS CLI..."

    # No debconf prompts: a dialog would hang unattended or curl | bash runs.
    export DEBIAN_FRONTEND=noninteractive

    # dnsutils provides dig for the post-install DNS probe below.
    apt-get update -qq
    apt-get install -y -qq curl gnupg ca-certificates dnsutils

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
mdns disabled
auto-activate false
bogus-priv true
use-hosts true
STATIC
} > /etc/nextdns.conf

# -- Fix boot ordering (the actual reason it breaks on reboot) ----------------
#
# NextDNS ships a systemd unit with "After=network.target" — but that fires
# long before tailscaled has established its tunnel and assigned the 100.x /
# fd7a:: addresses. Result: bind() fails, service crashes, no DNS.
#
# The fix is a drop-in override that:
#   1. Waits for tailscaled.service to be up
#   2. Runs a pre-start helper that blocks until every `listen` address in
#      /etc/nextdns.conf is on the Tailscale interface (exact match, IPv4
#      and IPv6, 120s deadline). The config is the single source of truth:
#      no address is baked into the drop-in, so the two cannot drift.
#   3. Sets TimeoutStartSec=150 so systemd's default 90s start timeout does
#      not kill the helper before its own deadline and error message
#   4. Adds restart-on-failure so transient timing issues self-heal
#
# The helper body below is also committed as scripts/wait-listen-addrs, which
# ShellCheck lints and tests/verify-relay-invariants.sh compares byte for
# byte with this heredoc. Edit both together.

HELPER_DIR="/usr/local/libexec/tailwag"
HELPER="${HELPER_DIR}/wait-listen-addrs"

log "Installing boot gate helper: $HELPER"
install -d -m 0755 "$HELPER_DIR"
cat > "${HELPER}.tmp" <<'WAIT'
#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
#  wait-listen-addrs  ·  Tailwag host boot gate (systemd ExecStartPre)
# ==============================================================================
#
#  Installed by tailwag.sh to /usr/local/libexec/tailwag/wait-listen-addrs and
#  run as ExecStartPre= of nextdns.service. Blocks until every specific
#  `listen` address in /etc/nextdns.conf is assigned to the Tailscale
#  interface, so nextdns never tries to bind() an address that is not there
#  yet (the boot race the whole project exists to fix).
#
#  Why a helper and not the old inline `for i in $(seq 1 90)` loop:
#    - 90 x (sleep 1 + ip/grep) overran systemd's default 90s
#      TimeoutStartSec, so systemd killed the loop before its own
#      "timed out" message could print. This uses a $SECONDS deadline that
#      sits below the drop-in's TimeoutStartSec=150.
#    - `grep -q 100.64.1.2` also matched 100.64.1.23. Matching here is exact
#      string equality on `ip -o addr` field 4 with the prefix length removed.
#    - Only IPv4 was awaited although an IPv6 listen line was written. Every
#      listen address is awaited now, IPv4 and IPv6 alike.
#    - The drop-in baked in the install-time IPv4 separately from the
#      config. The config is now the single source of truth.
#
#  Usage:   wait-listen-addrs [interface]      (default: tailscale0)
#  Env:     TAILWAG_WAIT_SECS   deadline in seconds (default 120). If you
#                               raise it, raise TimeoutStartSec in the
#                               drop-in too, or systemd kills us first.
#           TAILWAG_CONF        config to read (default /etc/nextdns.conf)
#  Exit:    0 all addresses present (or none to wait for), 1 timed out.
#
#  Wildcard (`:53`, `0.0.0.0`, `[::]`) and loopback listeners are skipped:
#  they never live on the Tailscale interface.
#
# ==============================================================================

set -euo pipefail

IFACE="${1:-tailscale0}"
CONF="${TAILWAG_CONF:-/etc/nextdns.conf}"
WAIT_SECS="${TAILWAG_WAIT_SECS:-120}"

die() { printf 'Tailwag: %s\n' "$*" >&2; exit 1; }

[[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || die "TAILWAG_WAIT_SECS must be an integer (got '$WAIT_SECS')"

if [[ ! -r "$CONF" ]]; then
    printf 'Tailwag: %s not readable; nothing to wait for\n' "$CONF" >&2
    exit 0
fi

# --- Collect the specific listen addresses -----------------------------------
# nextdns syntax is `listen HOST:PORT`, with IPv6 hosts in brackets.

ADDRS=()
while read -r key value _; do
    [[ "$key" == "listen" && -n "${value:-}" ]] || continue
    if [[ "$value" == \[* ]]; then
        addr="${value#\[}"
        addr="${addr%%\]*}"
    else
        addr="${value%:*}"
    fi
    case "$addr" in
        ""|0.0.0.0|::|127.*|::1) continue ;;
    esac
    ADDRS+=("${addr,,}")
done < "$CONF"

[[ ${#ADDRS[@]} -gt 0 ]] || exit 0

# --- Wait until each one is on the interface ---------------------------------

on_iface() {
    local want="$1" _idx _dev _fam cidr _rest
    while read -r _idx _dev _fam cidr _rest; do
        [[ "${cidr%/*}" == "$want" ]] && return 0
    done < <(ip -o addr show dev "$IFACE" 2>/dev/null || true)
    return 1
}

deadline=$(( SECONDS + WAIT_SECS ))
while :; do
    missing=""
    for addr in "${ADDRS[@]}"; do
        if ! on_iface "$addr"; then
            missing="$addr"
            break
        fi
    done
    [[ -z "$missing" ]] && exit 0

    if (( SECONDS >= deadline )); then
        printf 'Tailwag: timed out after %ss waiting for %s on %s\n' \
            "$WAIT_SECS" "$missing" "$IFACE" >&2
        exit 1
    fi
    sleep 1
done
WAIT
chmod 0755 "${HELPER}.tmp"
mv -f "${HELPER}.tmp" "$HELPER"

DROPIN_DIR="/etc/systemd/system/nextdns.service.d"
DROPIN_FILE="${DROPIN_DIR}/tailwag.conf"

log "Installing systemd drop-in: $DROPIN_FILE"
mkdir -p "$DROPIN_DIR"

cat > "$DROPIN_FILE" <<EOF
# Installed by Tailwag ${VERSION}
# Ensures NextDNS waits for its Tailscale listen addresses before binding.

[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
# Block until every listen address in /etc/nextdns.conf is on ${TS_IFACE}.
# The helper gives up after 120s; TimeoutStartSec must stay above that.
ExecStartPre=${HELPER} ${TS_IFACE}
TimeoutStartSec=150
Restart=on-failure
RestartSec=5
EOF

systemctl daemon-reload

# -- Firewall (UFW) -----------------------------------------------------------

# LC_ALL=C: ufw ships translations, so on a localised server the status line
# is not "Status: active" and the rules were silently skipped. Capture first
# rather than `ufw status | grep -q` under pipefail.
UFW_STATUS=""
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(LC_ALL=C ufw status 2>/dev/null || true)
fi

if [[ "$UFW_STATUS" == *"Status: active"* ]]; then
    if ip link show "$TS_IFACE" &>/dev/null; then
        log "Configuring UFW rules on $TS_IFACE..."

        # ufw is idempotent for identical rules; safe to re-run.
        ufw allow in on "$TS_IFACE" to any port 53 proto udp \
            comment "Tailwag DNS relay" >/dev/null
        ufw allow in on "$TS_IFACE" to any port 53 proto tcp \
            comment "Tailwag DNS relay" >/dev/null
    else
        warn "$TS_IFACE interface not found. Skipping UFW rules."
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
        EXIT_CODE=3
    fi

    if [[ -n "$TS_IPV6" ]]; then
        PROBE6=$(dig +short +time=5 +tries=1 @"$TS_IPV6" example.com A 2>/dev/null || true)
        if [[ -n "$PROBE6" ]]; then
            log "DNS probe OK (IPv6): example.com -> $PROBE6"
        else
            warn "IPv6 DNS probe via $TS_IPV6 returned nothing."
            EXIT_CODE=3
        fi
    fi
else
    log "dig not found; skipping DNS probe. Install dnsutils to enable it."
fi

# -- Loop prevention -----------------------------------------------------------
#
# Mandatory for a relay: with accept-dns on, this server would take the
# tailnet's DNS settings, which point at this very relay, and resolve its own
# upstream lookups through itself. Applied automatically on every run, so a
# re-run re-asserts it; the opt-out is an environment variable, not a prompt.
#
# Use `tailscale set` so we only flip accept-dns and do not wipe other node
# settings (advertise-exit-node, routes, tags, ssh, etc.). The old path used
# `tailscale up --accept-dns=false --reset`, which resets the entire node
# config — a footgun on multi-role relays.
#
# Do NOT fall back to a bare `tailscale up --accept-dns=false`: on Tailscale
# 1.8–1.32 that form refuses to run when other non-default preferences are
# omitted, and on very old clients it can reset them. `set --accept-dns` has
# existed since stable 1.34.0.
#
# Never die here: nextdns is already live, and exit 1 would claim it is not.

MANUAL_ACCEPT_DNS="tailscale set --accept-dns=false"
LOOP_GUARD=""

if [[ "${TAILWAG_KEEP_ACCEPT_DNS:-}" == "1" ]]; then
    LOOP_GUARD="SKIPPED: TAILWAG_KEEP_ACCEPT_DNS=1"
    warn "Loop guard skipped (TAILWAG_KEEP_ACCEPT_DNS=1). This relay may resolve through itself. Fix manually: $MANUAL_ACCEPT_DNS"
else
    # Capture, then match: `cmd | grep -q` under pipefail can report a
    # false negative when grep exits early and cmd dies of SIGPIPE.
    TS_SET_HELP=$($TS_BIN set --help 2>&1 || true)
    if [[ "$TS_SET_HELP" != *--accept-dns* ]]; then
        LOOP_GUARD="SKIPPED: tailscale too old for 'set --accept-dns' (need >= 1.34)"
        warn "This Tailscale build lacks 'set --accept-dns' (older than 1.34). The relay is running but NOT protected against DNS loops."
        warn "Upgrade Tailscale, then re-run Tailwag or run: $MANUAL_ACCEPT_DNS"
        EXIT_CODE=3
    else
        TS_PREFS=$($TS_BIN debug prefs 2>/dev/null || true)
        if [[ "$TS_PREFS" =~ \"CorpDNS\":[[:space:]]*false ]]; then
            LOOP_GUARD="already set"
            log "Loop guard: accept-dns=false already set."
        elif $TS_BIN set --accept-dns=false; then
            LOOP_GUARD="applied"
            log "Loop guard: applied accept-dns=false. This relay will not consume its own DNS."
        else
            LOOP_GUARD="SKIPPED: 'tailscale set --accept-dns=false' failed"
            warn "'$MANUAL_ACCEPT_DNS' failed. The relay is running but NOT protected against DNS loops. Run it manually."
            EXIT_CODE=3
        fi
    fi
fi

# -- Summary -------------------------------------------------------------------

cat <<SUMMARY

==============================================================================
  TAILWAG  ·  Relay Active
==============================================================================

  Addresses:
    IPv4  ${TS_IPV4}
$( [[ -n "$TS_IPV6" ]] && printf '    IPv6  %s\n' "$TS_IPV6" )
  Profile:     ${NEXTDNS_PROFILE}
  Cache:       ${CACHE_SIZE}  ·  Client TTL: ${MAX_TTL}
  Loop guard:  accept-dns=false (${LOOP_GUARD})

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

if [[ "$EXIT_CODE" -ne 0 ]]; then
    warn "Relay installed, but needs attention (exit ${EXIT_CODE}). See the WARN lines above."
fi

exit "${EXIT_CODE:-0}"
