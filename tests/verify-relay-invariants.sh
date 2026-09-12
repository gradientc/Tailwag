#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  verify-relay-invariants.sh
#  Static checks against the shipped Tailwag sources (not a reimplementation):
#    - Dockerfile ARG pins match the AGENTS.md "Current pins" table
#    - s6 / Tailscale / NextDNS checksum verification steps are still present
#    - MagicDNS forwarder, accept-dns=false default, and 100. wait still exist
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

# --- 100. wait on container (poll) and host (pre-check + ExecStartPre) -------

need docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh '^100\.'
need docker/tailscale-up.sh '^100\.'
need tailwag.sh '^100\.'
need tailwag.sh "fd7a:115c"
need tailwag.sh "ExecStartPre"

log "all relay invariants hold for pins Alpine=${PINS[ALPINE_VERSION]} s6=${PINS[S6_OVERLAY_VERSION]} tailscale=${PINS[TAILSCALE_VERSION]} nextdns=${PINS[NEXTDNS_VERSION]}"
