#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  verify-relay-invariants.sh
#  Static checks against the shipped Tailwag sources (not a reimplementation):
#    - Dockerfile ARG pins match the AGENTS.md "Current pins" table
#    - Every FROM uses the Alpine tag@digest pin, also in that table
#    - s6 / Tailscale / NextDNS checksum verification steps are still present
#    - MagicDNS forwarder, accept-dns=false default, and 100. wait still exist
#    - Duplicated scripts are byte-identical to their source of truth
#    - Both nextdns.conf generators (host + container) share the invariants
#    - The host loop guard is applied, never asked for
#    - tailwag.sh keeps VERSION="dev" for checks.yml to stamp at release
#    - tailwag.sh parses os-release (run against fixtures with VERSION
#      readonly) instead of sourcing it
#    - The OpenRC gate and conf.d are real code, not comments; firewalld is
#      opened by tailnet source, never as a bare port, and never reloaded
#
#  Run by .github/workflows/checks.yml on every push and pull request.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

log() { printf '[verify] %s\n' "$*"; }
die() { printf '[verify] FAIL: %s\n' "$*" >&2; exit 1; }

need() {
    local file="$1"
    local needle="$2"
    grep -qF -- "${needle}" "${file}" \
        || die "${file} is missing required text: ${needle}"
    log "ok  ${file}: ${needle}"
}

# Byte-identical pair: copy == source of truth.
same() {
    local copy="$1"
    local source="$2"
    cmp -s -- "${copy}" "${source}" \
        || die "${copy} differs from ${source} (edit the source, then mirror it)"
    log "ok  ${copy} == ${source}"
}

# --- Release version stamp ---------------------------------------------------
# checks.yml replaces this exact line with the release tag. Any other value in
# the source would ship unstamped (or stamp the wrong line), so pin it here.

[[ "$(grep -c '^readonly VERSION=' tailwag.sh)" -eq 1 ]] \
    || die "tailwag.sh must have exactly one readonly VERSION= line"
need tailwag.sh 'readonly VERSION="dev"'

# --- Pins: Dockerfile ARG is the build source of truth; table must match -----

mapfile -t ARG_LINES < <(grep -E '^ARG (ALPINE|S6_OVERLAY|TAILSCALE|NEXTDNS)_VERSION=' docker/Dockerfile)
[[ ${#ARG_LINES[@]} -eq 4 ]] || die "expected 4 ARG version pins in docker/Dockerfile, got ${#ARG_LINES[@]}"

declare -A PINS
for line in "${ARG_LINES[@]}"; do
    key="${line#ARG }"
    key="${key%%=*}"
    val="${line#*=}"
    PINS["${key}"]="${val}"
    log "dockerfile ${key}=${val}"
done

for key in ALPINE_VERSION S6_OVERLAY_VERSION TAILSCALE_VERSION NEXTDNS_VERSION; do
    [[ -n "${PINS[${key}]:-}" ]] || die "missing ${key} in Dockerfile"
    # AGENTS.md table: `ALPINE_VERSION` | <pin>
    table_pin="$(grep -E "\`${key}\`" AGENTS.md | awk -F'|' 'NR==1 {gsub(/ /,"",$3); print $3}')"
    [[ -n "${table_pin}" ]] || die "could not parse ${key} from AGENTS.md pin table"
    [[ "${table_pin}" == "${PINS[${key}]}" ]] \
        || die "${key} mismatch: Dockerfile=${PINS[${key}]} AGENTS.md=${table_pin}"
    log "ok  ${key} Dockerfile==AGENTS.md==${PINS[${key}]}"
done

# --- Alpine base pinned by digest, not just by the mutable tag ---------------
# Every stage must use the same tag@digest so all four stages build from one
# known base. A bare `FROM alpine:${ALPINE_VERSION}` (or :latest) fails here.

alpine_digest="$(grep -E '^ARG ALPINE_DIGEST=' docker/Dockerfile | head -n1 || true)"
alpine_digest="${alpine_digest#*=}"
[[ "${alpine_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "ARG ALPINE_DIGEST missing or not sha256:<64 hex> in docker/Dockerfile"
table_digest="$(grep -E "^\| +\`ALPINE_DIGEST\`" AGENTS.md | awk -F'|' 'NR==1 {gsub(/[ `]/,"",$3); print $3}' || true)"
[[ "${table_digest}" == "${alpine_digest}" ]] \
    || die "ALPINE_DIGEST mismatch: Dockerfile=${alpine_digest} AGENTS.md=${table_digest:-<missing>}"
mapfile -t FROM_LINES < <(grep -E '^FROM ' docker/Dockerfile)
[[ ${#FROM_LINES[@]} -gt 0 ]] || die "no FROM lines in docker/Dockerfile"
want_from="FROM alpine:\${ALPINE_VERSION}@\${ALPINE_DIGEST}"
for line in "${FROM_LINES[@]}"; do
    [[ "${line}" == "${want_from}"* ]] \
        || die "unpinned base image in docker/Dockerfile: ${line}"
done
log "ok  ALPINE_DIGEST Dockerfile==AGENTS.md, ${#FROM_LINES[@]} FROM lines use tag@digest"

# --- Checksum verification still in the shipped Dockerfile -------------------

need docker/Dockerfile "sha256sum -c"
need docker/Dockerfile "s6-overlay-noarch.tar.xz.sha256"
need docker/Dockerfile "\${TS_TGZ}.sha256"
need docker/Dockerfile "checksums.txt"

# --- Duplicates are identical (AGENTS.md "Duplication reality check") -------
# Named explicitly, not globbed. docker/run mirrors svc-tailscaled, not
# svc-nextdns.

same docker/init-config.sh  docker/rootfs/etc/s6-overlay/scripts/init-config.sh
same docker/tailscale-up.sh docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh
same docker/run             docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run

# The host boot gate lives in tailwag.sh as a <<'WAIT' heredoc (curl | bash
# needs a single file) and in scripts/wait-listen-addrs (so ShellCheck sees
# it). Extract the heredoc body and compare.
HEREDOC="$(mktemp)"
trap 'rm -f "${HEREDOC}"' EXIT
awk '
    /<<'"'"'WAIT'"'"'$/ { inside = 1; found = 1; next }
    inside && /^WAIT$/  { inside = 0; next }
    inside              { print }
    END                 { exit found ? 0 : 1 }
' tailwag.sh > "${HEREDOC}" || die "tailwag.sh has no <<'WAIT' heredoc"
cmp -s -- "${HEREDOC}" scripts/wait-listen-addrs \
    || die "tailwag.sh WAIT heredoc differs from scripts/wait-listen-addrs (edit both together)"
log "ok  tailwag.sh <<'WAIT' heredoc == scripts/wait-listen-addrs"

# --- Shared nextdns.conf invariants in both generators -----------------------
# MagicDNS (.ts.net → 100.100.100.100), no private-range leaks upstream, no
# system resolver takeover, no mDNS listener on public NICs.

for gen in tailwag.sh docker/rootfs/etc/s6-overlay/scripts/init-config.sh; do
    for line in \
        "forwarder ts.net=100.100.100.100" \
        "discovery-dns 100.100.100.100" \
        "bogus-priv true" \
        "auto-activate false" \
        "mdns disabled"; do
        need "${gen}" "${line}"
    done
done

# --- MagicDNS: .ts.net → 100.100.100.100 in generated NextDNS config ---------

need docker/rootfs/etc/s6-overlay/scripts/init-config.sh "forwarder ts.net=100.100.100.100"
need docker/rootfs/etc/s6-overlay/scripts/init-config.sh "discovery-dns 100.100.100.100"
need docker/init-config.sh "forwarder ts.net=100.100.100.100"
need tailwag.sh "forwarder ts.net=100.100.100.100"
need tailwag.sh "discovery-dns 100.100.100.100"

# --- Loop prevention: refuse tailnet DNS by default --------------------------

need docker/Dockerfile 'TS_ACCEPT_DNS="false"'
# Literal ${...} is the text in the shipped scripts, not a shell expansion.
# shellcheck disable=SC2016
need docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh '--accept-dns="${TS_ACCEPT_DNS:-false}"'
# shellcheck disable=SC2016
need docker/tailscale-up.sh '--accept-dns="${TS_ACCEPT_DNS:-false}"'
need tailwag.sh "--accept-dns=false"

# Host-only observability: the cache cap is sized from evidence, so the host
# generator must keep cache-metrics on (the container has no reader for it).
need tailwag.sh "cache-metrics true"

# Host loop guard is applied on every run, not offered as a prompt (audit P0).
need tailwag.sh 'set --accept-dns=false'
if grep -q 'accept-dns=false" on this server now' tailwag.sh; then
    die "tailwag.sh asks before applying accept-dns=false; it must apply it"
fi
if grep -nE '(^|[^[:alnum:]_])(read|prompt_read)[[:space:]].*accept-dns' tailwag.sh; then
    die "tailwag.sh reads user input about accept-dns; the loop guard is not optional"
fi
log "ok  tailwag.sh applies accept-dns=false without a prompt"

# --- 100. wait on container (poll) and host (pre-check + ExecStartPre) -------

need docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh '^100\.'
need docker/tailscale-up.sh '^100\.'
need tailwag.sh '^100\.'
need tailwag.sh "fd7a:115c"
need tailwag.sh "ExecStartPre"
need tailwag.sh "wait-listen-addrs"
need scripts/wait-listen-addrs "TAILWAG_WAIT_SECS"

# --- Host: one gate per service manager, both fed by the same helper --------
# systemd gets the drop-in above; OpenRC (Alpine, Devuan with openrc) gets a
# tailwag-gate service that nextdns needs via /etc/conf.d/nextdns. The
# helper is installed once and both gates call it, so the wait logic cannot
# fork. The NextDNS apk repository and its key are what make the Alpine path
# an official install rather than a hand-copied binary.

need tailwag.sh '/etc/init.d/tailwag-gate'
need tailwag.sh 'https://repo.nextdns.io/apk'
need tailwag.sh '/etc/apk/keys/nextdns.pub'
need tailwag.sh 'https://repo.nextdns.io/nextdns.repo'
if grep -qE '^[[:space:]]*start_pre\(\)' tailwag.sh; then
    die "tailwag.sh defines start_pre() for nextdns; the OpenRC gate must be its own service (nextdns install rewrites /etc/init.d/nextdns)"
fi

# Whole-line matches, so a comment that merely mentions them cannot satisfy
# the check: the conf.d content, the heredocs that write the gate and the
# conf.d, the gate's start() running the generated body, and both gate
# variants (supervised 30s, unsupervised 120s) calling the helper.
# shellcheck disable=SC2016  # literal source text to look for, not expansions
for line in 'rc_need="tailwag-gate"' 'supervisor=supervise-daemon' 'respawn_max=0' \
            '    cat > "${GATE_FILE}.tmp" <<EOF' '    } > "$CONFD_FILE"'; do
    grep -qxF -- "$line" tailwag.sh || die "tailwag.sh is missing the line: $line"
    log "ok  tailwag.sh line: $line"
done
awk '/^    cat > "\$\{GATE_FILE\}\.tmp" <<EOF$/ { f = 1; next }
     f && /^EOF$/ { exit }
     f && prev == "start() {" && $0 == "${GATE_START}" { ok = 1 }
     f { prev = $0 }
     END { exit !ok }' tailwag.sh \
    || die "the tailwag-gate heredoc's start() does not run \${GATE_START}"
[[ "$(grep -cE '^[[:space:]]*(if TAILWAG_WAIT_SECS=30 )?\$\{HELPER\} \$\{TS_IFACE\}(; then)?$' tailwag.sh)" -eq 2 ]] \
    || die "both OpenRC gate variants must call \${HELPER} \${TS_IFACE}"
log "ok  tailwag-gate start() runs the helper (supervised and unsupervised)"

# firewalld: a bare port or service in the zone that governs tailscale0
# (usually the default zone, which also holds the uplink) opens 53 beyond the
# tailnet, and a reload drops runtime-only rules such as fail2ban's bans.
# The tokens are banned anywhere in uncommented code, not only on lines that
# say firewall-cmd, so an array, a variable or a line continuation cannot
# bring them back. `systemctl daemon-reload` does not match (one dash).
if grep -nE '^[^#]*(add-port|add-service|(^|[[:space:]"'"'"'=])--(complete-)?reload([^[:alnum:]_-]|$)|(reload|restart)[[:space:]]+firewalld)' tailwag.sh; then
    die "tailwag.sh opens a bare port/service or reloads firewalld; use the tailnet-source rich rules, runtime and permanent, without a reload"
fi
# Both writes, each to its own zone, and all four rules exactly.
# shellcheck disable=SC2016,SC1003  # literal source text, trailing backslash included
for line in '            out=$(firewall-cmd --zone="$FW_RT_ZONE" --add-rich-rule="$rule" 2>&1) \' \
            '            out=$(firewall-cmd --permanent --zone="$FW_PERM_ZONE" --add-rich-rule="$rule" 2>&1) \' \
            "        'rule family=\"ipv4\" source address=\"100.64.0.0/10\" port port=\"53\" protocol=\"udp\" accept'" \
            "        'rule family=\"ipv4\" source address=\"100.64.0.0/10\" port port=\"53\" protocol=\"tcp\" accept'" \
            "        'rule family=\"ipv6\" source address=\"fd7a:115c:a1e0::/48\" port port=\"53\" protocol=\"udp\" accept'" \
            "        'rule family=\"ipv6\" source address=\"fd7a:115c:a1e0::/48\" port port=\"53\" protocol=\"tcp\" accept'"; do
    grep -qxF -- "$line" tailwag.sh || die "tailwag.sh is missing the firewalld line: $line"
    log "ok  tailwag.sh line: ${line#"${line%%[![:space:]]*}"}"
done

# --- Host: os-release is parsed, never sourced --------------------------------
# tailwag.sh has `readonly VERSION`, and Debian, Ubuntu and Fedora set
# VERSION= in os-release before ID=, so sourcing the file, even inside
# $( ), killed the script under set -e with no output. Every grep above
# passed while every Debian/Ubuntu run exited 1, so this runs real code with
# VERSION readonly as it is there: the reader on its own, and the whole
# detection block from tailwag.sh (reader, OS_ID/OS_LIKE call sites and the
# PKG case) with the os-release paths pointed at each fixture, so sourcing
# through a variable or eval at the call site fails here too.

if grep -nE '^[^#]*(^|[;&|({[:space:]])(\.|source)[[:space:]]+["'"'"']?(/etc|/usr/lib)/os-release' tailwag.sh; then
    die "tailwag.sh sources os-release; parse it with os_release_field instead"
fi
OSR_FN=$(sed -n '/^os_release_field() {/,/^}/p' tailwag.sh)
[[ -n "$OSR_FN" ]] || die "tailwag.sh has no os_release_field() reader"
OSR_DIR=$(mktemp -d)
trap 'rm -f "${HEREDOC}"; rm -rf "$OSR_DIR"' EXIT
printf '%s\n' 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"' 'NAME="Debian GNU/Linux"' \
    'VERSION_ID="12"' 'VERSION="12 (bookworm)"' 'VERSION_CODENAME=bookworm' 'ID=debian' \
    > "$OSR_DIR/debian"
printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.1 LTS"' 'NAME="Ubuntu"' 'VERSION_ID="24.04"' \
    'VERSION="24.04.1 LTS (Noble Numbat)"' 'ID=ubuntu' 'ID_LIKE=debian' > "$OSR_DIR/ubuntu"
printf '%s\n' 'NAME="Rocky Linux"' 'VERSION="9.5 (Blue Onyx)"' 'ID="rocky"' \
    'ID_LIKE="rhel centos fedora"' > "$OSR_DIR/rocky"
printf '%s' 'NAME="Alpine Linux"'$'\n''ID=alpine' > "$OSR_DIR/alpine"   # no final newline

check_osr() {  # usage: check_osr FIXTURE KEY EXPECTED
    local got
    got=$(bash -c 'set -euo pipefail; readonly VERSION="dev"; eval "$1"; os_release_field "$2" "$3"' \
            _ "$OSR_FN" "$2" "$OSR_DIR/$1") \
        || die "os_release_field $2 failed on the $1 fixture with VERSION readonly"
    [[ "$got" == "$3" ]] || die "os_release_field $2 on $1: got '$got', want '$3'"
    log "ok  os_release_field $2 on $1 = '$3'"
}
check_detect() {  # usage: check_detect FIXTURE EXPECTED_PKG
    local block got
    block=$(awk '/^os_release_field\(\) \{/ { f = 1 } f { print } f && /^esac$/ { exit }' tailwag.sh \
            | sed -e "s|/etc/os-release|$OSR_DIR/$1|g" -e "s|/usr/lib/os-release|$OSR_DIR/$1|g")
    [[ "$block" == *'PKG=""'* ]] || die "could not extract the os-release detection block from tailwag.sh"
    got=$(bash -c 'set -euo pipefail; readonly VERSION="dev"; eval "$1"; printf "%s" "$PKG"' _ "$block") \
        || die "the tailwag.sh detection block fails on the $1 fixture with VERSION readonly"
    [[ "$got" == "$2" ]] || die "detection block on $1: PKG='$got', want '$2'"
    log "ok  detection block on $1 -> PKG=$2"
}
check_detect debian apt
check_detect ubuntu apt
check_detect rocky dnf
check_detect alpine apk

check_osr debian ID debian
check_osr debian ID_LIKE ""
check_osr ubuntu ID ubuntu
check_osr ubuntu ID_LIKE debian
check_osr rocky ID rocky
check_osr rocky ID_LIKE "rhel centos fedora"
check_osr alpine ID alpine

# --- Every workflow pins a top-level token scope ------------------------------
# Without one, GITHUB_TOKEN gets the repository default, which is read-write on
# older repos (CodeQL actions/missing-workflow-permissions, CWE-275). Jobs may
# widen it for themselves.

for wf in .github/workflows/*.yml; do
    grep -qE '^permissions:' "${wf}" \
        || die "${wf} has no top-level permissions: block (least privilege)"
    log "ok  ${wf}: top-level permissions"
done

# --- Container fail-closed / health / env-as-truth (0.3.0) -------------------

need docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run "FATAL: /dev/net/tun not found"
need docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run "FATAL: CAP_NET_ADMIN is not in the effective capability set"
if grep -q 'falling back to userspace' docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run; then
    die "svc-tailscaled silently falls back to userspace again; it must fail closed"
fi
need docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh "    --reset"
# shellcheck disable=SC2016
need docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh 'timeout "${UP_TIMEOUT}"'
need docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh "did not finish within"
need docker/Dockerfile 'CMD ["/usr/local/bin/tailwag-health"]'
need docker/rootfs/usr/local/bin/tailwag-health "status: NOERROR"
need docker/rootfs/usr/local/bin/tailwag-health "/etc/nextdns.conf"
[[ -x docker/rootfs/usr/local/bin/tailwag-health ]] \
    || die "docker/rootfs/usr/local/bin/tailwag-health is not executable"
need docker/.dockerignore ".env"

log "all relay invariants hold for pins Alpine=${PINS[ALPINE_VERSION]}@${alpine_digest:0:19} s6=${PINS[S6_OVERLAY_VERSION]} tailscale=${PINS[TAILSCALE_VERSION]} nextdns=${PINS[NEXTDNS_VERSION]}"
