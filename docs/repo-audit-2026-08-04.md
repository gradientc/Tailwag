# Tailwag repository audit — 2026-08-04

> Multi-agent review of the whole repository: host installer (`tailwag.sh`), Docker/s6 path, security/supply chain, CI, and docs.
> **Status:** findings only — no product code was changed as part of this audit.
> **Line numbers** refer to the tree as of the audit date and may drift.

| | |
|---|---|
| **Date** | 2026-08-04 |
| **Scope** | Entire repo (`tailwag.sh`, `docker/`, CI, docs, SECURITY) |
| **Method** | Workflow `repo-audit`: 8 specialist agents → adversarial verify of medium+ claims → synthesis; plus 3 independent explore agents |
| **Agents** | ~36 read-only agents total |
| **Finding count** | 25 confirmed (after verification) |

---

## Executive summary

Tailwag’s core race fix—**do not start NextDNS until a Tailscale `100.x` address is ready**—is correctly implemented on both delivery paths (systemd `ExecStartPre` on the host; s6 dependency graph + socket/IP polls in Docker). The Docker supply chain (SHA256-checked s6 / NextDNS / Tailscale pins, Dependabot 2-day cooldown, mirrored rootfs scripts) is in solid shape.

The most serious production gaps are **behavioral and operational**, not missing architecture:

1. The host installer treats mandatory DNS-loop prevention (`tailscale set --accept-dns=false`) as an **opt-in** prompt that defaults to skip and is **silently skipped non-interactively**.
2. Docker can fall back to **userspace networking** and still report a successful boot via **loopback-only** dig healthchecks even when peers cannot reach the relay on `100.x:53`.

Secondary medium risks cluster around readiness/timeouts (IPv4-only dual-stack wait, HEALTHCHECK `start-period` under the 120s+ boot budget, unbounded `tailscale up`, overstated `S6_BEHAVIOUR` crash semantics), residual auth-key exposure in the shared container env, host apt GPG bootstrap without fingerprint pin, and docs that contradict the image’s forced iptables-legacy design.

Fixing the accept-dns default and the userspace/healthcheck false-success paths would eliminate the failure modes this project was explicitly built to prevent.

---

## Top priorities

1. **Host:** Default-apply `tailscale set --accept-dns=false` (opt-out only); auto-apply non-interactively; fail closed or warn loudly if set is unavailable.
2. **Docker:** Fail closed or hard-warn on userspace / missing `/dev/net/tun` for the DNS-relay role; document that userspace cannot serve peer DNS to NextDNS on `:53`.
3. **Healthcheck:** Require `tailscale ip -4` matching `^100\.` and dig against that address (not only `@127.0.0.1`); raise `start-period` to ≥ boot budget (e.g. 180s).
4. Wrap `tailscale up` in a hard timeout; correct S6_BEHAVIOUR / README claims or add finish/halt on longrun failure.
5. **Host dual-stack:** Wait for IPv6 on-link when v6 listen lines are written; tighten ExecStartPre IP matching (exact address / any `^100.`).
6. Fix `.env.example` firewall guidance: recommend unset/auto or `iptables`—not `nftables`—against the legacy-rewired image.
7. Reduce `TS_AUTHKEY` lifetime: file/secret mount, scrub after first successful up, document post-auth removal as the default ops path.
8. **Host supply chain:** Pin NextDNS apt GPG fingerprint; set `DEBIAN_FRONTEND=noninteractive` and OS/apt preflight before apt-get.

---

## Confirmed findings

Severity guide: **high** = likely user-facing failure or loop; **medium** = real bug under common conditions; **low** = edge, docs, consistency.

### High

#### Host loop prevention is opt-in and silently skipped non-interactively

| | |
|---|---|
| **File** | `tailwag.sh` (~294–322) |
| **Category** | bug / ux |

**Issue:** AGENTS.md and script headers treat `--accept-dns=false` as essential loop prevention, but the final prompt defaults to `[y/N]` (Enter = no) and non-TTY runs force `REPLY=n` with no warning. Automated installs leave accept-dns enabled while docs urge “Override local DNS” at this node—exactly the self-resolver loop Tailwag exists to prevent. Docker always defaults `TS_ACCEPT_DNS=false`.

**Fix:** Default-apply `tailscale set --accept-dns=false` (opt-out only); auto-apply non-interactively; on decline/skip warn with the manual command; optionally verify prefs and fail closed if accept-dns remains true. Align header / README / AGENTS with host behavior.

#### Userspace fallback makes DNS relay unreachable while boot still succeeds

| | |
|---|---|
| **File** | `docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run` (~25–27) |
| **Category** | architecture / race |

**Issue:** Missing `/dev/net/tun` or `TS_USERSPACE=true` starts tailscaled with `--tun=userspace-networking`. Peer traffic to `100.x` typically never reaches NextDNS on the Linux stack (`NEXTDNS_LISTEN=:53`), yet socket + `tailscale ip -4` polls succeed, NextDNS starts, and HEALTHCHECK digs `@127.0.0.1` go green. Docs advertise userspace for restricted platforms with only exit-node caveats, not DNS-serve failure.

**Fix:** Treat kernel TUN as mandatory for DNS-relay unless explicitly opt-in with loud warnings; fail closed on silent auto-fallback by default; document that userspace cannot deliver peer DNS to NextDNS; do not treat loopback dig as “relay ready.”

---

### Medium

#### Healthcheck only validates loopback, not the product path

| | |
|---|---|
| **File** | `docker/Dockerfile` (~192–193) |
| **Category** | bug / ops |

**Issue:** HEALTHCHECK runs `dig @127.0.0.1 example.com`. With default listen `:53`, NextDNS answers on loopback as soon as it is up, independent of whether the tailnet dataplane can deliver queries to the node’s `100.x` nameserver IP (userspace, missing caps, NAT/firewall, interface not ready). Orchestrators report healthy while the relay’s purpose is broken.

**Fix:** Require `tailscale ip -4` matching `^100\.` and dig against that address (keep `127.0.0.1` as secondary). Document that in-container probes cannot fully prove remote ACL reachability.

#### HEALTHCHECK start-period shorter than worst-case s6 boot budget

| | |
|---|---|
| **File** | `docker/Dockerfile` (~192–193) |
| **Category** | race |

**Issue:** `start-period=60s` but `tailscale-up` alone can wait 30s for the socket plus 90s for a `100.` IP (120s), excluding `tailscale up` RTT. NextDNS is gated behind that oneshot. With interval 30s and retries 3, platforms can mark unhealthy or restart mid-bootstrap during a legitimate slow boot.

**Fix:** Set `--start-period` to at least the documented oneshot budget plus headroom (e.g. 180s), or lower socket/IP budgets and document the new total so start-period, timeouts, and dig readiness stay aligned.

#### No timeout around `tailscale up`; stage-2 can hang forever

| | |
|---|---|
| **File** | `docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh` (~64–68) |
| **Category** | race |

**Issue:** Socket (30s) and IP (90s) waits die on timeout, but bare `tailscale up` has none and `S6_CMD_WAIT_FOR_SERVICES_MAXTIME` is unset (infinite). A blocked control plane or bad state leaves the oneshot unfinished, NextDNS never starts, and stage-2 never fails closed for Docker restart.

**Fix:** Wrap `tailscale up` in `timeout` (e.g. 60–120s) and die on non-zero/124; optionally set s6-rc `timeout-up` / `S6_CMD_WAIT_FOR_SERVICES_MAXTIME` covering socket + up + IP.

#### `S6_BEHAVIOUR_IF_STAGE2_FAILS=2` does not stop the container on later longrun crashes

| | |
|---|---|
| **File** | `docker/Dockerfile` (~186), `docker/README.md` |
| **Category** | bug / docs |

**Issue:** That ENV only aborts stage-2 bring-up failures. Longruns lack readiness notification and finish/halt scripts, so post-boot crashes of tailscaled or nextdns are supervised in-place while the container stays up. README and AGENTS.md claim longrun crashes stop the container for Docker restart recovery—operators get false confidence about partial failure modes.

**Fix:** Add finish scripts that halt on unexpected non-zero exit, or rewrite Dockerfile / README / AGENTS to describe stage-2-only semantics and that HEALTHCHECK unhealthy ≠ container exit.

#### Dual-stack config waits only for IPv4 at boot

| | |
|---|---|
| **File** | `tailwag.sh` (~152–153, ~193–201) |
| **Category** | race |

**Issue:** When IPv6 is discovered at install, `nextdns.conf` gets both IPv4 and IPv6 listen lines, but ExecStartPre only polls for the IPv4 string. Boots where v4 is ready before `fd7a::` is on-link can fail the v6 bind and `Restart=on-failure` churn despite the critical wait succeeding.

**Fix:** When a v6 listen is written, also require that address (or any `fd7a:115c:a1e0::/48`) on-link before start; better, re-resolve current Tailscale IPs at start and rewrite listen lines so boots cannot use stale dual-stack addresses.

#### `TS_AUTHKEY` remains in shared container environment for all services

| | |
|---|---|
| **File** | `docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh` (~40), compose env |
| **Category** | security |

**Issue:** `TS_AUTHKEY` via compose `env_file` / `-e` is injected into every `with-contenv` service for the container lifetime. Any process and `docker inspect` can read a reusable auth key or OAuth client secret long after first auth, even though state reuse allows key removal after first boot. The key is also passed on argv as `--authkey=…`.

**Fix:** Add `TS_AUTHKEY_FILE` / secret mount; unset after successful up; document removing the key from compose / `.env` after first successful auth when state is persisted as the default path.

#### Host NextDNS GPG key fetched without fingerprint pin

| | |
|---|---|
| **File** | `tailwag.sh` (~128), `SECURITY.md` |
| **Category** | supply-chain |

**Issue:** `curl … nextdns.gpg | gpg --dearmor` trusts whatever HTTPS serves as the signing key. A compromised `repo.nextdns.io` (or MITM against that host) can substitute a key and ship a malicious package. Documented in SECURITY.md as a known limitation but remains the main host-path supply-chain surface vs checksummed Docker downloads.

**Fix:** After fetch, verify a hard-coded fingerprint (`gpg --show-keys`) and refuse mismatch; document the pin in SECURITY.md; optionally vendor a known-good key blob.

#### Exit-node firewall override docs contradict forced iptables-legacy image

| | |
|---|---|
| **File** | `docker/.env.example` (~31–33) |
| **Category** | docs |

**Issue:** `.env.example` suggests `TS_DEBUG_FIREWALL_MODE=nftables` if exit-node routing fails, but the image installs `iptables-legacy` and rewrites `/usr/sbin/iptables` / `ip6tables` with a build-time legacy guard ([tailscale#17854](https://github.com/tailscale/tailscale/issues/17854)). Forcing nftables against legacy-only userspace binaries is likely to break the NAT path the Dockerfile carefully fixed.

**Fix:** Recommend leaving the mode unset (auto) or `iptables`; document the deliberate legacy rewrite. Remove or gate the nftables recommendation unless the image stops forcing legacy symlinks.

#### No Debian/Ubuntu preflight before apt/dpkg usage

| | |
|---|---|
| **File** | `tailwag.sh` (~117–137) |
| **Category** | ux |

**Issue:** Requirements say Debian/Ubuntu only, but the script never checks `/etc/os-release` or apt/dpkg presence before `apt-get`, keyrings paths, and dpkg architecture. On other systemd hosts, failures come late and opaque after Tailscale discovery already succeeded.

**Fix:** Early preflight: die unless Debian/Ubuntu (`ID` / `ID_LIKE`) or `apt-get` + `dpkg` exist; message should name supported platforms and point to `docker/` for others.

#### Fly.io UDP service stanza risks public DNS exposure

| | |
|---|---|
| **File** | `docker/fly.toml` (~45–51) |
| **Category** | security / deployment |

**Issue:** Comments say all traffic arrives via Tailscale, but `[[services]]` defines UDP `internal_port = 53` with no explicit “do not publish” guard. Combined with default `NEXTDNS_LISTEN=:53`, adding `[[services.ports]]` later would create a public open resolver.

**Fix:** Remove `[[services]]` for tailnet-only apps, or document clearly never to publish 53 publicly; prefer in-VM healthchecks.

#### No automated functional / runtime tests in CI

| | |
|---|---|
| **File** | `.github/workflows/docker.yml` |
| **Category** | ci |

**Issue:** CI builds multi-arch images and runs ShellCheck, but never asserts generated `nextdns.conf` contents, boot ordering, or a dig path. “Do not regress” areas only fail in production.

**Fix:** At minimum: static checks that conf templates still contain MagicDNS forwarders; ideally a smoke job that exercises boot + dig (with secrets or mocks).

#### Build context may include local `.env` (no `.dockerignore`)

| | |
|---|---|
| **File** | missing `docker/.dockerignore` |
| **Category** | security |

**Issue:** `.gitignore` excludes `.env`, but there is no `.dockerignore`. A local `docker/.env` with `TS_AUTHKEY` is sent as build context even though the Dockerfile does not currently `COPY` it.

**Fix:** Add `docker/.dockerignore` excluding `.env`, `.env.*`, and junk (`!.env.example` if needed).

---

### Low

#### Docs / header overclaim automatic loop prevention

| | |
|---|---|
| **File** | `tailwag.sh` (~14–27) |
| **Category** | docs |

Header claims the script prevents DNS loops and “handles `--accept-dns=false` for you”; the post-install SUMMARY omits accept-dns and prints before the opt-in prompt.

**Fix:** Soften wording or change default; print clear status whether accept-dns was applied; include accept-dns in SUMMARY next steps.

#### ExecStartPre greps raw IPv4 substring without boundaries

| | |
|---|---|
| **File** | `tailwag.sh` (~195–201) |
| **Category** | race |

Unanchored `grep -q "${TS_IPV4}"` can match overlapping addresses (e.g. `100.64.1.2` vs `100.64.1.20`).

**Fix:** Exact address presence (`ip -4 addr show to …` or line-anchored match).

#### Systemd readiness check hardcodes install-time Tailscale IPv4

| | |
|---|---|
| **File** | `tailwag.sh` (~195–201) |
| **Category** | race |

ExecStartPre waits for the exact IP baked at last run. Address change leaves NextDNS waiting 90s then failing forever even if another valid `100.` address exists. Docker correctly polls any `^100\.`.

**Fix:** Wait for any `^100\.` (and optional `fd7a`) or re-query `tailscale ip` each second; pair with listen-line regeneration or document re-run of `tailwag.sh` on IP change.

#### accept-dns failure dies after NextDNS is already live

| | |
|---|---|
| **File** | `tailwag.sh` (~315–321) |
| **Category** | ux |

If the user answers `y` but Tailscale lacks `set --accept-dns`, the script dies after nextdns is already running. Exit 1 implies total failure while the relay is partially active.

**Fix:** Check capability earlier; use partial-success messaging if the relay is up.

#### Idempotency claim does not cover accept-dns state

| | |
|---|---|
| **File** | `tailwag.sh` (~16–17) |
| **Category** | bug |

Comments claim every run produces a clean identical state. Re-runs rewrite conf and drop-in but never re-assert accept-dns=false unless the operator answers the prompt again.

**Fix:** On each run detect and re-apply accept-dns=false when needed.

#### apt-get runs without noninteractive dpkg frontend

| | |
|---|---|
| **File** | `tailwag.sh` (~124–137) |
| **Category** | ux |

No `DEBIAN_FRONTEND=noninteractive` — can block unattended `curl | bash` installs.

**Fix:** Export noninteractive frontend for apt blocks.

#### Cache size defaults diverge between host and Docker

| | |
|---|---|
| **File** | `tailwag.sh` (~43) vs Docker ENV / `.env.example` |
| **Category** | drift |

Host defaults to **20MB**; Docker to **10MB**. AGENTS.md asks to keep defaults consistent.

**Fix:** Pick one default and align all paths, or document intentional container reduction (e.g. Fly 256MB).

#### Host `nextdns.conf` omits `mdns disabled` present in Docker

| | |
|---|---|
| **File** | `tailwag.sh` (~156–163) vs `init-config.sh` |
| **Category** | drift |

**Fix:** Add `mdns disabled` to the host STATIC block unless host mDNS is intentional and documented.

#### `init-config` expands `TS_STATE_DIR` without default under `set -u`

| | |
|---|---|
| **File** | `docker/rootfs/etc/s6-overlay/scripts/init-config.sh` (~25) |
| **Category** | maintainability |

Bare `${TS_STATE_DIR}` dies if ENV is stripped; `svc-tailscaled` already uses a default. Variable missing from `.env.example` / README tables.

**Fix:** `TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"`; document volume-match warning.

#### Docker NextDNS listens on all interfaces; host is Tailscale-only

| | |
|---|---|
| **File** | `init-config.sh` (~33–42) vs `tailwag.sh` |
| **Category** | security |

Docker default `listen :53` vs host `listen ${TS_IPV4}:53`. Safe only when ports are not published and network is isolated.

**Fix:** Document threat model; optional post-up rewrite of listen to TS IPs; warn when `:53` is published or host-networked.

#### `curl | bash` install tracks mutable `main` without integrity pin

| | |
|---|---|
| **File** | `README.md` |
| **Category** | security |

Recommended one-liner pipes `main` into `sudo bash` with no commit SHA, release tag, or checksum pin.

**Fix:** Document release-tag / commit-pinned URL plus sha256 verification.

#### No concurrency group on publish job races `:latest`

| | |
|---|---|
| **File** | `.github/workflows/docker.yml` |
| **Category** | ci |

Overlapping main pushes (or main concurrent with a release) can finish out of order and leave `:latest` on an older build.

**Fix:** Concurrency group for docker publish.

#### OAuth “minimal scopes” never specified

| | |
|---|---|
| **File** | `docker/README.md` |
| **Category** | docs |

Production auth recommends OAuth with “minimal scopes” but never lists them.

**Fix:** Document exact scopes, example tag (e.g. `tag:dns-relay`), ACL notes.

#### Product version signals split and boot docs misname service

| | |
|---|---|
| **File** | `docker/README.md`, `docker/Dockerfile` header, `tailwag.sh` |
| **Category** | docs |

Docker badge / header **0.1.0** vs host `VERSION="0.2.0"`. Boot sequence naming and longrun crash recovery oversold. AGENTS.md still says “Tailscale has none” for checksums though stage 2 verifies `.tgz.sha256`. Wrong upstream link: `github.com/tailwag/tailwag`. docker/README still says “experimental… not yet tested.”

**Fix:** Document version spaces; fix URL and experimental language; update AGENTS checksum wording; accurate boot/crash docs.

#### `TS_EXTRA_ARGS` intentional word-split; `NEXTDNS_EXTRA_ARGS` misnamed

| | |
|---|---|
| **File** | `tailscale-up.sh`, `init-config.sh` |
| **Category** | safety / ux |

`TS_EXTRA_ARGS` is IFS-split into argv (injection if env is untrusted). `NEXTDNS_EXTRA_ARGS` appends **config file lines**, not CLI flags.

**Fix:** Prefer first-class env vars; document split rules; rename to `NEXTDNS_EXTRA_CONFIG`.

---

## Strategic improvements

| Improvement | Effort | Why |
|-------------|--------|-----|
| CI smoke test for critical DNS-relay path | M–L | ShellCheck + multi-arch build cannot catch accept-dns / userspace / healthcheck mismatches |
| Enforce rootfs vs `docker/` script identity in CI | S | Duplication is healthy only by convention today |
| Path-filtered CI + least-privilege ShellCheck | S | Docs-only PRs still burn QEMU multi-arch minutes |
| SBOM / provenance (optional cosign) on GHCR | M | Consumers cannot verify image origin beyond registry ACL |
| Day-2 ops runbook (troubleshoot / upgrade / uninstall) | M | Happy-path install covered; failure modes are not |
| Align host/container nextdns.conf and defaults | S | Cache, mdns, listen-scope differ without intentional docs |
| `TS_AUTHKEY_FILE` + post-auth scrub | M | Long-lived keys in env/argv expand blast radius |
| Renovate / regex manager for ARG pins + 2-day age | M | Dependabot does not cover s6/Tailscale/NextDNS ARGs |
| Compose profile for userspace-only deploys | S | Always granting NET_ADMIN + TUN is broader than needed |
| Alpine base digest pin | S | Tag-only `FROM alpine` remains mutable |

---

## Healthy areas

These are working as intended and should not be casually “simplified” away:

- **Boot race fixed** — host systemd ExecStartPre waits for Tailscale IPv4; Docker s6 graph is `init-config` → `svc-tailscaled` → `tailscale-up` → `svc-nextdns` with socket + `100.x` IP polls
- **MagicDNS preserved** — `forwarder ts.net=100.100.100.100` and `discovery-dns 100.100.100.100` on both paths
- **Docker loop prevention default** — `TS_ACCEPT_DNS=false`; state persisted at `/var/lib/tailscale` (compose volume + Fly mount)
- **iptables-legacy** — package install, `/usr/sbin` symlinks, build-time `iptables -V | grep -qi legacy` guard ([tailscale#17854](https://github.com/tailscale/tailscale/issues/17854))
- **Container supply chain** — s6, NextDNS, and Tailscale downloads SHA256-checked; four Dockerfile ARGs match the AGENTS.md pin table; Dependabot 2-day cooldown for Actions + docker
- **Duplication currently green** — `docker/{init-config.sh,tailscale-up.sh,run}` match rootfs counterparts (verified by `diff` at audit time)
- **Host installer hygiene** — `set -euo pipefail`, root-gated, profile-validated; prefers `tailscale set` over `up --reset` for accept-dns; UFW rules when UFW is active
- **CI** — ShellCheck on push/PR; multi-arch Buildx on PRs without push; GHCR publish with least-privilege `packages: write` only on non-PR
- **Secrets posture** — Fly keeps `TS_AUTHKEY` out of `[env]`; `.env` gitignored; SECURITY.md documents known limitations honestly
- **AGENTS.md / comments** — encode hard-won failure modes (90s poll, firewall mode, MagicDNS) that keep contributors from regressing the heart of the system

---

## Suggested implementation order

| Priority | Work |
|----------|------|
| **P0** | Host: default-apply `--accept-dns=false` (incl. non-interactive) |
| **P0** | Docker: userspace fail-closed for relay; healthcheck + `start-period` |
| **P1** | Timeout `tailscale up`; fix S6/README crash semantics; host dual-stack + exact IP wait |
| **P1** | Firewall docs (legacy, not nftables); Fly UDP service; `.dockerignore` |
| **P2** | CI conf asserts + rootfs diff gate; cache/mdns/version/AGENTS checksum docs |
| **P3** | Authkey file/scrub, GPG fingerprint pin, uninstall runbook, SBOM/provenance |

---

## Method notes

1. **Workflow `repo-audit`** (saved under `~/.grok/workflows/repo-audit.rhai` and project `.grok/workflows/`): eight specialists (host installer, Docker/s6 boot, security/supply, network/DNS/firewall, config/env/Fly, duplication/drift, CI quality, UX/ops/docs) → adversarial verification of high/medium claims → synthesis agent.
2. **Independent explore agents** re-audited host, Docker/s6, and security/CI paths and converged on the same P0 conclusions.
3. **Local checks at audit time:** ShellCheck on the canonical script list (clean); `diff` of duplicated scripts (identical); Dockerfile ARGs matched AGENTS.md pin table.

Re-run: invoke the `repo-audit` workflow after large changes, or treat this document as the baseline backlog and update findings as they are fixed.
