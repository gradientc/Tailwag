#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
#  TAILWAG  ·  Model 02
#  A caching DNS relay for Tailscale networks. One script. Full stack.
# ==============================================================================
#
#  What it does:
#    - Installs NextDNS CLI from the official NextDNS package repository for
#      your distribution (apt, apk or dnf)
#    - Configures it as a DNS53 relay bound to your Tailscale addresses
#    - Enables dual-stack (IPv4 + IPv6) by default
#    - Installs a boot gate for your init system (a systemd drop-in, or an
#      OpenRC gate service) so NextDNS waits for the Tailscale addresses on
#      every boot
#    - Sets up firewall rules if UFW or firewalld is active
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
#    sudo TAILWAG_CACHE_SIZE=4MB ./tailwag.sh <id>      # small-RAM host
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
#  Requirements:
#    - Linux with systemd or OpenRC as the service manager
#    - A package manager NextDNS publishes for: apt (Debian, Ubuntu, Devuan
#      and derivatives), apk (Alpine) or dnf/yum (Fedora, RHEL, Rocky, Alma,
#      CentOS Stream). Anything else: install the nextdns CLI yourself, run
#      `nextdns install`, and this script does the rest.
#    - bash 4+, Tailscale installed and authenticated
#
# ==============================================================================

set -euo pipefail

# "dev" in the source. checks.yml stamps the release tag over it in the copy
# attached to each GitHub release, so an installed host records which release
# wrote its config, and a copy fetched from main says it is unreleased.
readonly VERSION="dev"

# --- Tuning ------------------------------------------------------------------
#
# These defaults are good for home/small-office tailnets. Each one can be
# overridden for a single run with the TAILWAG_* environment variable named
# next to it (handy with `curl | sudo bash`, where there is no file to edit).
# The comments explain the trade-offs.

# In-memory cache cap. NextDNS charges each entry its response size in bytes
# (typically 100-300 B) and uses memory only for entries actually cached, so a
# generous cap costs nothing on a quiet relay. 20 MB holds roughly 60-120k
# responses: the whole working set of a small office, so the hit rate is
# bounded by TTL expiry, never by eviction. Same default as the container.
# On a 128-256 MB host, 4MB still holds 12-24k responses and bounds the worst
# case. Check with `nextdns cache-stats` (hit/miss) and the cache-metrics
# socket call documented in the README (keys_evicted should stay 0).
CACHE_SIZE="${TAILWAG_CACHE_SIZE:-20MB}"

# Max TTL handed to clients. This caps only the TTL in the answers sent to
# clients. The relay's own cache keeps the true upstream TTL, and NextDNS
# flushes that cache automatically when the profile is updated (see
# `nextdns run -h`, -cache-size). So this value is exactly how long a client
# may keep an answer that a profile change has since invalidated. 30s keeps
# allow/block edits near-immediate while cutting the re-queries that cross the
# tunnel to a sixth of the old 5s default (phones on battery notice). Raise to
# 60s for fewer still; browsers cap their own DNS cache near 60s anyway.
# Reference: https://github.com/nextdns/nextdns/wiki/Cache-Configuration
MAX_TTL="${TAILWAG_MAX_TTL:-30s}"

# Bind to the Tailscale IPv6 address in addition to IPv4.
# Both are always assigned by Tailscale; dual-stack is free redundancy.
ENABLE_IPV6="${TAILWAG_ENABLE_IPV6:-true}"

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
# also matches 100.64.1.23. Same matching as wait-listen-addrs below. The
# field layout is the same for iproute2 and BusyBox ip (Alpine), checked
# against BusyBox 1.37: `1: lo    inet 127.0.0.1/8 scope host lo\ ...`.
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

# Validate the tuning overrides before anything is written: an invalid
# cache-size or max-ttl is only noticed by nextdns at start, after the old
# config has been replaced, and the failure would read as a boot problem.
[[ "$CACHE_SIZE" =~ ^[0-9]+([KMG]i?)?B?$ ]] \
    || die "TAILWAG_CACHE_SIZE must be a size such as 20MB or 4MB (got '$CACHE_SIZE')"
[[ "$MAX_TTL" =~ ^([0-9]+(ms|s|m|h))+$ ]] \
    || die "TAILWAG_MAX_TTL must be a duration such as 30s or 1m (got '$MAX_TTL')"
[[ "$ENABLE_IPV6" == true || "$ENABLE_IPV6" == false ]] \
    || die "TAILWAG_ENABLE_IPV6 must be true or false (got '$ENABLE_IPV6')"

# -- Detect the distribution family and the service manager -------------------
#
# Two independent facts decide what this script does:
#   PKG   which NextDNS repository to add and which package manager installs
#         the CLI (apt, apk, dnf; empty means "unknown, nextdns must already
#         be installed")
#   INIT  which service manager owns nextdns and gets the boot gate
#         (systemd or openrc)
#
# The OpenRC test mirrors what `nextdns install` itself checks (PID 1 is
# `init`, /sbin/openrc-run exists, the runlevel is `default`,
# host/service/openrc/service.go upstream). Every package repository runs
# `nextdns install` from its post-install script, so matching its detection
# is what guarantees the service file this script gates is the one the
# package created. A mismatch (e.g. running in single-user mode) would gate
# a service that does not exist.

OS_ID="" OS_LIKE=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
    # shellcheck disable=SC1091
    OS_LIKE=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")
fi

PKG=""
case " ${OS_ID} ${OS_LIKE} " in
    *" alpine "*)                                     PKG="apk" ;;
    *" debian "*|*" ubuntu "*|*" devuan "*|*" raspbian "*) PKG="apt" ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) PKG="dnf" ;;
esac

INIT=""
PID1=$(cat /proc/1/comm 2>/dev/null || true)
if [[ "$PID1" == "systemd" ]]; then
    INIT="systemd"
elif [[ "$PID1" == "init" && -x /sbin/openrc-run ]] \
    && [[ "$(rc-status --runlevel 2>/dev/null || true)" == "default" ]]; then
    INIT="openrc"
else
    die "Unsupported service manager (PID 1 is '${PID1:-unknown}'). Tailwag needs systemd or OpenRC (runlevel default): it installs the boot gate as a systemd drop-in or an OpenRC gate service. sysvinit-only Devuan: install OpenRC (apt install openrc) first. See https://github.com/gradientc/Tailwag#requirements"
fi
log "Distribution: ${OS_ID:-unknown} (packages: ${PKG:-none known}, service manager: ${INIT})"

# Service control for the init system in use. Everything below goes through
# these so the two paths cannot drift. svc_exists is the check that the
# package's `nextdns install` actually registered a service: it is what the
# boot gate attaches to.
svc_exists() {
    case "$INIT" in
        systemd) systemctl cat nextdns.service >/dev/null 2>&1 ;;
        openrc)  [[ -e /etc/init.d/nextdns ]] ;;
    esac
}
svc_stop() {
    case "$INIT" in
        systemd) systemctl stop nextdns >/dev/null 2>&1 || true ;;
        openrc)  rc-service nextdns stop >/dev/null 2>&1 || true ;;
    esac
}
svc_enable() {
    case "$INIT" in
        systemd) systemctl enable nextdns >/dev/null 2>&1 \
                     || warn "systemctl enable nextdns failed; the relay will not start at boot" ;;
        openrc)  rc-update add nextdns default >/dev/null 2>&1 || true
                 rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx nextdns \
                     || warn "nextdns is not in the default runlevel; run: rc-update add nextdns default" ;;
    esac
}
svc_restart() {
    case "$INIT" in
        systemd) systemctl restart nextdns ;;
        openrc)  rc-service nextdns restart ;;
    esac
}
svc_active() {
    case "$INIT" in
        systemd) systemctl is-active --quiet nextdns ;;
        openrc)  rc-service -q nextdns status >/dev/null 2>&1 ;;
    esac
}
svc_logs() {
    case "$INIT" in
        systemd) journalctl -u nextdns --no-pager -n 15 2>/dev/null || true ;;
        openrc)  nextdns log 2>/dev/null | tail -n 15 || true ;;
    esac
}

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

# The OpenRC service that runs tailscaled, for the gate's dependency. Alpine's
# package ships /etc/init.d/tailscale (tailscale-openrc subpackage); a
# hand-installed daemon is usually `tailscaled`. Without it the gate still
# waits for the addresses, it just cannot order itself after the daemon.
TS_SVC=""
if [[ "$INIT" == "openrc" ]]; then
    for candidate in tailscale tailscaled; do
        if [[ -e "/etc/init.d/${candidate}" ]]; then
            TS_SVC="$candidate"
            break
        fi
    done
    if [[ -z "$TS_SVC" ]]; then
        warn "No OpenRC service for tailscaled found in /etc/init.d (tailscale or tailscaled). The boot gate will wait for the addresses but cannot start tailscaled first."
    elif ! rc-update show 2>/dev/null | awk '{print $1}' | grep -qx "$TS_SVC"; then
        warn "$TS_SVC is not in any OpenRC runlevel, so Tailscale will not come up after a reboot. Fix: rc-update add $TS_SVC default"
    fi
fi

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
#
# Each path adds NextDNS's own repository for that package manager and
# installs `nextdns` from it, exactly as NextDNS's installer
# (https://nextdns.io/install, install_deb / install_apk / install_rpm) does,
# so later updates arrive with the system's normal package upgrades. Every
# repository's post-install script runs `nextdns install`, which detects the
# service manager and writes /etc/systemd/system/nextdns.service or
# /etc/init.d/nextdns and enables it; that service is what the boot gate
# below attaches to. All three fetch the repository signing key over HTTPS on
# first install (see SECURITY.md).
#
# dig (dnsutils / bind-tools / bind-utils) is for the post-install DNS probe.

if command -v nextdns &>/dev/null; then
    log "NextDNS CLI already present: $(nextdns version)"
else
    case "$PKG" in
        apt)
            log "Installing NextDNS CLI from repo.nextdns.io/deb ..."

            # No debconf prompts: a dialog would hang unattended or curl | bash runs.
            export DEBIAN_FRONTEND=noninteractive

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
            ;;
        apk)
            log "Installing NextDNS CLI from repo.nextdns.io/apk ..."

            # bind-tools is dig (about 2 MB); the script itself needs bash.
            apk add --no-progress bash curl ca-certificates bind-tools

            # apk looks for the key named in the repository's APKINDEX
            # signature under /etc/apk/keys; NextDNS signs as nextdns.pub.
            curl -fsSL https://repo.nextdns.io/nextdns.pub -o /etc/apk/keys/nextdns.pub
            chmod 644 /etc/apk/keys/nextdns.pub

            APK_REPO="https://repo.nextdns.io/apk"
            grep -qxF "$APK_REPO" /etc/apk/repositories 2>/dev/null \
                || printf '%s\n' "$APK_REPO" >> /etc/apk/repositories

            apk update --no-progress
            apk add --no-progress nextdns
            ;;
        dnf)
            log "Installing NextDNS CLI from repo.nextdns.io (rpm) ..."

            DNF="dnf"
            command -v dnf &>/dev/null || DNF="yum"

            # curl-minimal already provides `curl` on RHEL 9+ and installing
            # the full package over it needs --allowerasing, so only add curl
            # when there is none.
            command -v curl &>/dev/null || "$DNF" install -y curl
            "$DNF" install -y ca-certificates bind-utils

            install -m 0755 -d /etc/yum.repos.d
            curl -fsSL https://repo.nextdns.io/nextdns.repo -o /etc/yum.repos.d/nextdns.repo
            "$DNF" install -y nextdns
            ;;
        *)
            die "No NextDNS repository is known for '${OS_ID:-this distribution}' (ID_LIKE='${OS_LIKE}'). Install the nextdns CLI yourself (https://github.com/nextdns/nextdns/wiki), run 'nextdns install' so your service manager knows it, then re-run Tailwag: it skips this step when nextdns is already present."
            ;;
    esac

    log "Installed: $(nextdns version)"
fi

svc_exists \
    || die "nextdns is installed but has no ${INIT} service (the package's 'nextdns install' did not run or failed). Run 'nextdns install' and re-run Tailwag."

# -- Write configuration ------------------------------------------------------
# Written atomically via cat. Wipes any previous state, which is the point:
# run the script again and you get a known-good config every time.

log "Writing /etc/nextdns.conf ..."

# cache-metrics: keeps Ristretto hit/miss/eviction counters so the cache cap can
# be sized from evidence (`nextdns cache-stats`, and the control-socket call in
# the README for keys_evicted). NextDNS documents the overhead as "small CPU
# and memory". Host only: the container has no python or socket-capable nc to
# read the richer counters, so it is not worth the overhead there.

svc_stop

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
cache-metrics true
STATIC
} > /etc/nextdns.conf

# -- Fix boot ordering (the actual reason it breaks on reboot) ----------------
#
# NextDNS's own service file orders itself "After=network.target" (systemd)
# or "use net" (OpenRC), but both fire long before tailscaled has established
# its tunnel and assigned the 100.x / fd7a:: addresses. Result: bind() fails,
# service crashes, no DNS.
#
# The fix is a pre-start gate for the service manager in use:
#   1. Waits for tailscaled's service to be up
#   2. Runs a helper that blocks until every `listen` address in
#      /etc/nextdns.conf is on the Tailscale interface (exact match, IPv4
#      and IPv6, 120s deadline). The config is the single source of truth:
#      no address is baked into the service files, so the two cannot drift.
#   3. systemd: ExecStartPre= in a drop-in, with TimeoutStartSec=150 so
#      systemd's default 90s start timeout does not kill the helper before
#      its own deadline and error message, plus restart-on-failure so
#      transient timing issues self-heal
#      OpenRC: a `tailwag-gate` service whose start() is the helper, declared
#      as rc_need in /etc/conf.d/nextdns, so nextdns cannot start before it
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

case "$INIT" in
systemd)
    DROPIN_DIR="/etc/systemd/system/nextdns.service.d"
    DROPIN_FILE="${DROPIN_DIR}/tailwag.conf"

    log "Installing systemd drop-in: $DROPIN_FILE"
    mkdir -p "$DROPIN_DIR"

    # A drop-in, not an edited unit: `nextdns install` (run again by every
    # package upgrade) rewrites /etc/systemd/system/nextdns.service and
    # would drop an edit, while the drop-in directory survives.
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
    ;;
openrc)
    GATE_FILE="/etc/init.d/tailwag-gate"
    CONFD_FILE="/etc/conf.d/nextdns"

    log "Installing OpenRC gate service: $GATE_FILE"

    # The gate is its own service rather than a start_pre() in nextdns's
    # init script, for the same reason systemd gets a drop-in: `nextdns
    # install` rewrites /etc/init.d/nextdns on every package upgrade.
    # /etc/conf.d/nextdns is not touched by it, and rc_need there is OpenRC's
    # documented way to add a dependency from outside the script
    # (openrc-run(8), "rc_need"). `need`, not `use`: if tailscaled's service
    # is stopped, OpenRC stops the gate and nextdns with it, and a restart of
    # tailscaled re-runs the wait before nextdns binds again. A service with
    # no daemon is marked started once start() returns 0, so the wait runs
    # once per boot (or per tailscaled restart), never on a plain
    # `rc-service nextdns restart`.
    GATE_DEPEND="    after net"
    [[ -n "$TS_SVC" ]] && GATE_DEPEND="    need ${TS_SVC}"$'\n'"${GATE_DEPEND}"

    cat > "${GATE_FILE}.tmp" <<EOF
#!/sbin/openrc-run
# Installed by Tailwag ${VERSION}
# Blocks until every listen address in /etc/nextdns.conf is on ${TS_IFACE},
# so nextdns never tries to bind an address that is not there yet.
# /etc/conf.d/nextdns declares rc_need="tailwag-gate".

description="Tailwag boot gate: wait for the Tailscale listen addresses"

depend() {
${GATE_DEPEND}
}

start() {
    ebegin "Waiting for the Tailscale listen addresses on ${TS_IFACE}"
    ${HELPER} ${TS_IFACE}
    eend \$?
}

stop() {
    return 0
}
EOF
    chmod 0755 "${GATE_FILE}.tmp"
    mv -f "${GATE_FILE}.tmp" "$GATE_FILE"

    log "Installing OpenRC dependency: $CONFD_FILE"
    cat > "$CONFD_FILE" <<EOF
# Installed by Tailwag ${VERSION}
# Start nextdns only after the Tailwag boot gate has seen every listen
# address from /etc/nextdns.conf on ${TS_IFACE}. This file survives nextdns
# package upgrades; /etc/init.d/nextdns does not (see $GATE_FILE).
rc_need="tailwag-gate"
EOF

    # Refresh the dependency cache so the new need is honoured on the restart
    # below, not only after the next boot.
    rc-update -u >/dev/null 2>&1 || true
    ;;
esac

# -- Firewall -----------------------------------------------------------------
#
# nextdns binds only the Tailscale addresses, so the rules open port 53 on
# the Tailscale interface alone (UFW) or in the zone that interface belongs
# to (firewalld). Nothing else listens on 53.

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
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    # Fedora / RHEL family. An interface with no explicit zone is governed by
    # the default zone (usually `public`, which drops inbound 53), so the
    # relay is unreachable from the tailnet until that zone opens the port.
    # `--get-zone-of-interface` prints "no zone" and exits non-zero for an
    # unassigned interface.
    FW_ZONE=$(firewall-cmd --get-zone-of-interface "$TS_IFACE" 2>/dev/null || true)
    [[ -n "$FW_ZONE" && "$FW_ZONE" != "no zone" ]] \
        || FW_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    if [[ -n "$FW_ZONE" ]]; then
        log "Configuring firewalld: port 53 in zone $FW_ZONE ($TS_IFACE)..."
        # --permanent then --reload: idempotent, and the running config
        # matches what survives a reboot.
        firewall-cmd --permanent --zone="$FW_ZONE" --add-port=53/udp >/dev/null
        firewall-cmd --permanent --zone="$FW_ZONE" --add-port=53/tcp >/dev/null
        firewall-cmd --reload >/dev/null
    else
        warn "firewalld is running but no zone could be determined for $TS_IFACE. Open port 53 there yourself."
    fi
else
    log "No active firewall found (ufw, firewalld). Ensure port 53 on $TS_IFACE is reachable from your tailnet."
fi

# -- Start & verify -----------------------------------------------------------

log "Starting NextDNS service..."
svc_enable
svc_restart
sleep 2

if ! svc_active; then
    warn "Service did not start cleanly. Recent logs:"
    svc_logs
    die "nextdns service is not running."
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
    log "dig not found; skipping DNS probe. Install dnsutils / bind-tools / bind-utils to enable it."
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

case "$INIT" in
    systemd) LOG_CMD="journalctl -u nextdns -f      Follow service logs" ;;
    openrc)  LOG_CMD="rc-service nextdns status     Service state (gate: rc-service tailwag-gate status)" ;;
esac

cat <<SUMMARY

==============================================================================
  TAILWAG  ·  Relay Active
==============================================================================

  Addresses:
    IPv4  ${TS_IPV4}
$( [[ -n "$TS_IPV6" ]] && printf '    IPv6  %s\n' "$TS_IPV6" )
  Profile:     ${NEXTDNS_PROFILE}
  Cache:       ${CACHE_SIZE}  ·  Client TTL: ${MAX_TTL}
  Boot gate:   ${INIT} (${HELPER} ${TS_IFACE})
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
  nextdns cache-stats           Cache hit / miss counters
  cat /etc/nextdns.conf         View configuration
  ${LOG_CMD}

==============================================================================
SUMMARY

if [[ "$EXIT_CODE" -ne 0 ]]; then
    warn "Relay installed, but needs attention (exit ${EXIT_CODE}). See the WARN lines above."
fi

exit "${EXIT_CODE:-0}"
