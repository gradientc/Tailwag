#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  verify-relay-invariants.sh
#  Static checks against the shipped Tailwag sources (not a reimplementation):
#    - Dockerfile ARG pins match the AGENTS.md "Current pins" table
#    - s6 / Tailscale / NextDNS checksum verification steps are still present
#    - MagicDNS forwarder, accept-dns=false default, and 100. wait still exist
#    - Duplicated scripts are byte-identical to their source of truth
#    - Both nextdns.conf generators (host + container) share the invariants
#    - The host loop guard is applied, never asked for
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

log "all relay invariants hold for pins Alpine=${PINS[ALPINE_VERSION]} s6=${PINS[S6_OVERLAY_VERSION]} tailscale=${PINS[TAILSCALE_VERSION]} nextdns=${PINS[NEXTDNS_VERSION]}"
