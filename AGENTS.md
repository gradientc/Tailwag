# AGENTS.md

> Guidance for AI coding agents and human contributors working on Tailwag.

**Tailwag** turns any Debian/Ubuntu machine (or Docker host) on your Tailscale tailnet into a [NextDNS](https://nextdns.io)-powered caching DNS relay — with proper boot ordering, dual-stack, firewall rules, and loop prevention.

**Core philosophy (read this first):**  
Every run must produce a *known-good, identical* state. The project exists because "just point Tailscale DNS at NextDNS" is full of race conditions, firewall quirks, and reboot surprises. All code comments that look overly long exist because someone (or their users) hit the exact failure mode they describe.

There are two supported delivery mechanisms that share the same principles:

- `tailwag.sh` — single-file Bash installer for bare Debian/Ubuntu hosts (apt + systemd)
- `docker/` — self-contained Alpine + s6-overlay container (Tailscale + NextDNS, no host systemd required)

---

## Quick Reference for Agents ("I want to...")

| Goal | Files you will almost certainly touch | Special warnings |
|------|---------------------------------------|------------------|
| Add / change a config variable (cache size, TTL, listen addr, etc.) | `docker/rootfs/etc/s6-overlay/scripts/init-config.sh`, `docker/.env.example`, `docker/Dockerfile` (ENV), `docker/docker-compose.yml`, `docker/fly.toml`, and the corresponding section in `tailwag.sh` + its README table | Update both the container *and* host paths; keep defaults consistent |
| Modify boot / race-condition logic | `tailwag.sh` (systemd drop-in), `docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh`, the s6-rc.d dependency files | You are touching the heart of the project. Re-read the 90-second poll and the `scripts/wait-listen-addrs` boot gate before writing code |
| Change Tailscale or NextDNS version | `docker/Dockerfile` (the four `ARG` lines + download stages) | Keep the checksum verification pattern for s6 and NextDNS; Tailscale has none |
| Add a new shell script | The new file + both duplication locations if applicable + `.github/workflows/shellcheck.yml` `additional_files` | See "Duplication" section below |
| Improve firewall / exit-node behavior | `docker/Dockerfile` (iptables-legacy symlinks), `docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run` (TS_DEBUG_FIREWALL_MODE) | This is the #1 source of "it works on my machine but not in the container" bugs |
| Update docs or examples | `README.md`, `docker/README.md`, `.env.example`, `fly.toml` comments | Keep the ASCII diagrams and "Why?" sections in sync |

**Before you propose any change to a `.sh` file:**

1. Run the full **ShellCheck command** listed in the Development section.
2. Re-read the race-condition and "why this exists" comments in the files you are editing.
3. Ask yourself: "Does this still produce a clean state on a fresh boot with no Tailscale IP for the first 60 seconds?"

---

## Repository Layout (with notes)

```
.
├── tailwag.sh                 # Host installer. Idempotent, strict mode, self-contained for curl|bash
├── scripts/
│   └── wait-listen-addrs      # Host boot gate (ExecStartPre). DUPLICATE of the heredoc inside tailwag.sh
├── tests/
│   └── verify-relay-invariants.sh # Static gates: pins, checksums, shared conf lines, duplicate identity, loop guard
├── LICENSE, SECURITY.md, README.md
├── .github/workflows/
│   ├── shellcheck.yml         # Enforces ShellCheck on a curated list of scripts (update when adding files)
│   ├── checks.yml             # Runs tests/verify-relay-invariants.sh; on release, tag must equal tailwag.sh VERSION
│   └── docker.yml             # Multi-arch build + push to ghcr.io/gradientc/tailwag
└── docker/
    ├── Dockerfile             # 4-stage build, checksums, Alpine 3.24, s6-overlay v3, pinned Tailscale/NextDNS
    ├── docker-compose.yml
    ├── .env.example           # All user-configurable knobs documented here
    ├── fly.toml               # Fly.io deployment (full kernel networking, cheap geo distribution)
    ├── init-config.sh         # DUPLICATE (see below)
    ├── tailscale-up.sh        # DUPLICATE
    ├── run                    # DUPLICATE (the svc-tailscaled run script)
    └── rootfs/                # What actually ends up in the image (COPY rootfs /)
        └── etc/s6-overlay/
            ├── scripts/           # Real init-config.sh and tailscale-up.sh (authoritative)
            ├── s6-rc.d/
            │   ├── init-config/   # oneshot – validates + writes /etc/nextdns.conf
            │   ├── svc-tailscaled/ # longrun – the daemon (userspace fallback, firewall mode override)
            │   ├── tailscale-up/   # oneshot – waits for socket + 100. IP, then `tailscale up`
            │   └── svc-nextdns/    # longrun – `nextdns run -config-file /etc/nextdns.conf`
            └── user-bundles.d/user/contents.d/ # declares the startup set
```

**s6 `user` bundle location:** the startup set lives in `user-bundles.d/user/contents.d/`, **not** `s6-rc.d/user/`. s6-overlay ≥ 3.2.3 ships `user-bundles.d/user` (with its own `type` file) and prints a deprecation warning on every boot if `s6-rc.d/user` exists. When adding a service, create its source dir under `s6-rc.d/` and an empty file named after it in `user-bundles.d/user/contents.d/`.

**Duplication reality check**  
`docker/{init-config.sh,tailscale-up.sh,run}` are currently byte-identical copies of files under `rootfs/`. The top-level copies are not packaged into the image; only `rootfs/` is.  

`scripts/wait-listen-addrs` is the same kind of duplicate on the host side: `tailwag.sh` must stay self-contained for `curl | bash`, so it carries the helper as a `<<'WAIT'` heredoc and writes it to `/usr/local/libexec/tailwag/`. The committed file exists so ShellCheck can lint it. Edit both together.

**Rule for agents:** When editing, make the change in the `rootfs/...` location first. Then mirror it to the top-level copy so the two stay in sync. If you are adding a brand-new script, place the source of truth under `rootfs/`, update the s6-rc.d files that reference it, and decide whether a convenience copy at `docker/` level is still needed.

---

## Local Development & Testing

### Mandatory: ShellCheck

```bash
# From repo root – canonical list of every managed shell script
shellcheck \
  tailwag.sh \
  scripts/wait-listen-addrs \
  docker/run \
  docker/init-config.sh \
  docker/tailscale-up.sh \
  docker/rootfs/etc/s6-overlay/s6-rc.d/svc-nextdns/run \
  docker/rootfs/etc/s6-overlay/scripts/init-config.sh \
  docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh \
  docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run \
  .agents/setup \
  .agents/resume \
  tests/verify-relay-invariants.sh
```

If you add a new `.sh` file, add it to the command above. Extensionless scripts must also be listed by **basename** in `.github/workflows/shellcheck.yml` `additional_files` (the action uses `find -name`, so path-valued entries are ignored).

### Mandatory: relay invariants

```bash
bash tests/verify-relay-invariants.sh
```

CI runs it on every push and PR (`.github/workflows/checks.yml`). It fails if a duplicated script drifts from its source of truth, if either `nextdns.conf` generator loses a shared invariant line (`forwarder ts.net=…`, `discovery-dns`, `bogus-priv true`, `auto-activate false`, `mdns disabled`), if the host loop guard turns back into a prompt, or if the Dockerfile pins and the table below disagree.

### Testing the host script

Requires a Debian/Ubuntu machine with Tailscale already up and a NextDNS profile ID.

```bash
sudo ./tailwag.sh abc123
# Re-run to prove idempotency
sudo ./tailwag.sh abc123
journalctl -u nextdns -f
```

### Testing the Docker path (recommended for most changes)

```bash
cd docker
cp .env.example .env
# Edit .env with real TS_AUTHKEY (or OAuth) + NEXTDNS_PROFILE
docker compose up -d --build
docker compose logs -f
# Inside the container
docker compose exec tailwag tailscale status
docker compose exec tailwag dig +short @127.0.0.1 example.com
docker compose exec tailwag cat /etc/nextdns.conf
```

Healthcheck is defined in the Dockerfile and uses `dig @127.0.0.1`.

Fly.io deployments are fully supported (see `fly.toml` and the docker README).

---

## Coding Standards

### All Bash files

- Line 1-2 must be:
  ```bash
  #!/usr/bin/env bash
  # shellcheck shell=bash
  ```
  or (for s6 longrun/oneshot scripts)
  ```bash
  #!/command/with-contenv bash
  # shellcheck shell=bash
  ```
- `set -euo pipefail` near the top (after any early env setup).
- Provide `log()` and `die()` helpers. Host script uses timestamps; container scripts use `[tailwag] <component>:`.
- Every file begins with a 15–40 line header comment block explaining purpose, architecture, and gotchas.
- Build complex commands with arrays:
  ```bash
  ARGS=(--foo bar)
  ARGS+=(--baz)
  cmd "${ARGS[@]}"
  ```
- Early validation + `die` with actionable message + URL to docs.
- `ip addr show | grep -q "100\."` style checks are intentional and have been battle-tested.

### Docker / s6-overlay specifics

- `init-config` (oneshot) is the only thing allowed to write `/etc/nextdns.conf`.
- `tailscale-up` (oneshot) **must** complete successfully (with a `100.` IPv4) before `svc-nextdns` is allowed to start. This is expressed both via `dependencies.d/` and the explicit polling loop inside the script.
- `S6_BEHAVIOUR_IF_STAGE2_FAILS=2` in the Dockerfile means a permanently failing service stops the container so Docker's restart policy can recover it cleanly.
- The `with-contenv` wrapper is how s6 injects the `.env` variables into every service script.

### Documentation & comments

- Prefer tables for variables, steps, and component roles (see READMEs).
- Every workaround (iptables-legacy, 90 s timeout, `forwarder ts.net=...`) must have a comment explaining the concrete failure it prevents.
- Keep the "How it works" ASCII diagrams in sync with reality.

**High-signal locations whose style and logic you should internalize**

- [tailwag.sh:66-68](/tailwag.sh) – host log/die helpers + timestamp
- [tailwag.sh:238-388](/tailwag.sh) – the boot gate helper + systemd drop-in that wait for the Tailscale listen addresses (original motivation for the whole project)
- [scripts/wait-listen-addrs](/scripts/wait-listen-addrs) – the same helper as a lintable file; must stay byte-identical to the `<<'WAIT'` heredoc in `tailwag.sh`
- [docker/Dockerfile](/docker/Dockerfile) – `iptables-legacy` package + `/usr/sbin` symlinks (Alpine 3.19+; tailscale#17854). Build-time `iptables -V | grep -qi legacy` guard.
- [docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh:68-88](/docker/rootfs/etc/s6-overlay/scripts/tailscale-up.sh) – the post-`tailscale up` 90-second poll for a routable `100.` IP ("the critical fix")
- [docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run:32-38](/docker/rootfs/etc/s6-overlay/s6-rc.d/svc-tailscaled/run) – "Firewall mode override — the #1 source of container deployment failures"
- Checksum download pattern in Dockerfile stages 1 and 3 (s6 and NextDNS)

---

## Critical Subsystems – "Do Not Regress" Areas

1. **Tailscale IP readiness**
   - The container version waits in `tailscale-up.sh` after `tailscale up` returns.
   - The host version uses a systemd `ExecStartPre=/usr/local/libexec/tailwag/wait-listen-addrs` gate in the drop-in. It waits until **every** `listen` address in `/etc/nextdns.conf` is on the Tailscale interface (exact match, IPv4 and IPv6, 120 s deadline, `TimeoutStartSec=150` above it). The config is the single source of truth; never bake an address into the drop-in again.
   - Both poll for an address matching `^100\.` (IPv4) or the `fd7a:115c:...` prefix (IPv6).

2. **iptables backend compatibility**
   - Install the `iptables-legacy` package and point `/usr/sbin/iptables` + `/usr/sbin/ip6tables` at the legacy multi-call binary (see Dockerfile and tailscale#17854). Paths are `/usr/sbin`, **not** `/sbin` — the old `/sbin/iptables-legacy` links were dangling and broke exit-node/subnet NAT. Removing or regressing this silently breaks users on Synology and other legacy-iptables hosts.

3. **MagicDNS preservation**
   - `forwarder ts.net=100.100.100.100` and `discovery-dns 100.100.100.100` in the generated `nextdns.conf` are mandatory. Clients on the tailnet must still resolve `.ts.net` names.

4. **State persistence**
   - `/var/lib/tailscale` (volume in compose, fly.toml mount, or host) must survive restarts. Without it every container launch creates a brand-new Tailscale node.

5. **DNS loop prevention**
   - `TS_ACCEPT_DNS=false` (env) / `tailscale set --accept-dns=false` (host script, applied automatically on every run) is not optional for relay nodes. The only host opt-out is `TAILWAG_KEEP_ACCEPT_DNS=1`; never turn it back into a prompt.

---

## Security & Supply Chain

See the full [SECURITY.md](/SECURITY.md).

- GPG key for the NextDNS apt repo is fetched over HTTPS and dearmored (known limitation documented).
- s6-overlay and NextDNS binaries are SHA256-checked against upstream checksum files.
- Tailscale Linux tarballs are SHA256-checked against the `.tgz.sha256` sidecars published on `pkgs.tailscale.com` (raw hex; verified before extract).
- The `curl ... | sudo bash` one-liner is convenient but carries the usual transport risks — the script itself validates inputs aggressively.

When touching any download or key-handling code, preserve or strengthen the existing verification steps.

---

## Dependency & Supply-Chain Update Policy

The container image (the only thing that ships to production) is built from four manually-pinned versions defined as build args at the top of the Dockerfile. The host `tailwag.sh` has **no** CLI pins (it uses the system Tailscale + the official NextDNS apt repository).

**Current pins (source of truth)**

| Component              | Current Pin | Latest (queried 2026-10-10) | Risk / Notes |
|------------------------|-------------|-----------------------------|--------------|
| `ALPINE_VERSION`      | 3.24.2     | 3.24.2 (2026-09-17)        | Patch bump 3.24.1 → 3.24.2 (official 2026-09-17, ~3 weeks of aging; security fixes + AMD/Intel microcode). `iptables` / `iptables-legacy` still 1.8.13-r0, `bind-tools` 9.20.29-r0, `bash` 5.3.9-r1. Build-time `iptables -V \| grep -qi legacy` guard passes on amd64 + arm64. **Safe**. |
| `S6_OVERLAY_VERSION`  | 3.2.3.2    | 3.2.3.2 (2026-07-16)       | Already at latest non-prerelease. Same tarball layout + SHA256 sidecars for noarch + x86_64 + aarch64. **Safe**. |
| `TAILSCALE_VERSION`   | 1.102.5    | 1.104.1 (2026-10-07) / 1.102.5 (2026-09-29) | **Deliberately held on the 1.102.x line.** 1.102.4 → 1.102.5 fixes tailscaled exiting when a client falls behind on status updates (it now reconnects). 1.104.1 was skipped: only 3 days old at query time, rebuilt on Go 1.27, and has an open Linux regression where TLS-inspecting middleboxes reset control-plane HTTPS because the ClientHello now offers ML-KEM (tailscale#21708 — node comes up logged out), plus a direct-path recovery regression (tailscale#21728). Re-evaluate 1.104.x once those are fixed. pkgs.tailscale.com amd64/arm64 `.tgz` + `.tgz.sha256` HTTP 200. **Known publish-lag risk** (see commit 7ddcec9 history). Image still forces `/usr/sbin/iptables` → legacy (tailscale#17854). **Safe**. |
| `NEXTDNS_VERSION`     | 1.47.3     | 1.47.3 (2026-06-03)        | Already at latest non-prerelease. Go 1.26.4 + x/net bump + OpenWrt DHCP CIDR strip. Full `checksums.txt` lists linux_amd64 and linux_arm64 tarballs. **Safe**. |

**GitHub Actions** (pins in `.github/workflows/`):

- `actions/checkout@v7`
- `docker/setup-qemu-action@v4`
- `docker/setup-buildx-action@v4`
- `docker/login-action@v4.6.0`
- `docker/metadata-action@v6.2.0`
- `docker/build-push-action@v7`
- `ludeeus/action-shellcheck@2.0.0`

These are kept on recent tags. **Dependabot + the 2-day cooldown** (see below) will open PRs for them after the aging period.

**The 2-day supply-chain cooldown (the feature you asked about)**

Yes, it is a real, recommended practice and is now **natively supported** by Dependabot via the `cooldown` key (added to address exactly the "new malicious/buggy release" timing attack).

- `cooldown.default-days: 2` tells Dependabot: do **not** create a PR for a newly published version until 2 days after its `published_at` timestamp.
- Supported for both `github-actions` and `docker` ecosystems.
- We have configured it in `.github/dependabot.yml` (created as part of this work).

This is the mechanism behind the "wait 48 h before merging Dependa PRs" advice you heard.

**Policy for this repo**

- Automated parts (the 7 Actions): Dependabot will propose updates only after the 2-day cooldown. Review + merge normally.
- Manual parts (the 4 ARGs): humans must still wait **≥2 days after the upstream release date** before merging any version bump, even if a colleague or Dependabot (for other reasons) opens a PR early.
- The recent Tailscale publish-lag incident is the canonical example of why the extra human check is required.

**Bump checklist (for the four ARGs)**

1. Confirm the new versions exist for **both** `linux/amd64` and `linux/arm64` (especially Tailscale tars).
2. Run a full multi-arch build locally or via the CI workflow in a PR.
3. Inside the resulting image: `dig +short @127.0.0.1 example.com` + basic Tailscale status / exit-node test if applicable.
4. Update **all four** ARGs in one PR (they are meant to move together).
5. Update the table above in this file (the duplication rule that already applies to the s6 scripts also applies here).
6. Run the project's ShellCheck command on any touched scripts.

**How to enable Dependabot**

Settings → Code security and analysis → Dependabot → "Enable" (or "Add Dependabot security updates" + version updates). The file `.github/dependabot.yml` is all that is required.

**Future / more automation**

If we ever want automatic age-based bumps for the exact `ARG` lines (Dependabot's docker parser has only partial support for `${VAR}` indirection today), we can evaluate Renovate with a custom regex manager + `minimumReleaseAge: "2 days"`. For now the native Dependabot + documented manual process is the right fit.

When you touch any of the four ARG lines, you **must** also update this table and re-read the Tailscale publish-lag warning.

---

## Release & Versioning

- `tailwag.sh` carries its own `readonly VERSION="0.2.2"` constant. `checks.yml` fails a published release whose tag (no `v` prefix, e.g. `0.2.2`) differs from it, so bump `VERSION` in the release PR, not after.
- Docker image versions are controlled by the four `ARG` lines at the top of the Dockerfile.
- On release, the GitHub Actions workflow tags the image with semver + `latest`.
- Update the version badges in both README files when cutting a release.

---

## Common Pitfalls (learned the hard way)

- Assuming `tailscale up` returning means the `100.` address is immediately usable on the interface — it isn't. Always poll.
- Forgetting that modern Alpine/Ubuntu default to nftables while Tailscale's firewall code still expects iptables-legacy inside the container.
- Starting NextDNS before the Tailscale interface has an address (the exact bug the whole project was written to solve).
- Editing only one of the duplicated script copies.
- Adding a new environment variable but forgetting to document it in `.env.example` and the README tables.
- Using `exec` incorrectly in s6 longrun scripts (must be the last thing, and `exec 2>&1` is intentional for log capture).

---

## References

- NextDNS CLI configuration & cache: https://github.com/nextdns/nextdns/wiki
- s6-overlay v3 service definition semantics (oneshot/longrun, dependencies, `with-contenv`)
- Tailscale's own container images and known issues with iptables/nftables on Alpine
- The original Tailwag motivation in the systemd drop-in comment block

---

**When in doubt, re-read the comments that look "too verbose". They are the accumulated wisdom of every user who hit the exact edge case you are about to re-introduce.**

This `AGENTS.md` was generated after a complete exploration of the 2026-05-23 worktree. Keep it up to date when architecture or process changes occur.
