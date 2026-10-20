<p align="center">
  <a href="https://github.com/gradientc/Tailwag/releases">
    <img src="https://img.shields.io/github/v/release/gradientc/Tailwag?label=version" alt="Version">
  </a>
  <img src="https://img.shields.io/badge/platform-Docker-2496ED?logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-orange" alt="Arch">
  <a href="https://github.com/gradientc/Tailwag/pkgs/container/tailwag">
    <img src="https://img.shields.io/badge/ghcr.io-gradientc%2Ftailwag-blue?logo=github" alt="GHCR">
  </a>
</p>

# Tailwag Docker

**A portable, caching NextDNS relay for Tailscale networks. One container. Full stack.**

Tailwag Docker packages [NextDNS](https://nextdns.io) CLI and [Tailscale](https://tailscale.com) into a single, minimal container with proper process supervision, persistent state, and multi-arch support. Deploy it on a Raspberry Pi, a Synology NAS, a Hetzner VPS, or across 30 Fly.io regions — same image, same config.

---

## Why?

The original [Tailwag](https://github.com/gradientc/Tailwag) script turns a Debian/Ubuntu machine into a NextDNS relay for your tailnet. This is the same idea, but containerized: no host dependencies, no systemd plumbing, runs anywhere Docker runs.

Self-hosting the NextDNS CLI (instead of using Tailscale's built-in NextDNS integration) gives you local caching without round-trips, conditional per-subnet profiles, and independence from Tailscale's DNS infrastructure.

## What's inside

| Component | Role |
| --- | --- |
| **Alpine Linux** | Minimal base (~5 MB), multi-arch, matches Tailscale's own image |
| **s6-overlay v3** | PID 1, process supervision, dependency ordering, clean shutdown |
| **tailscaled** | WireGuard tunnel — kernel TUN mode; userspace only as an explicit, degraded opt-in |
| **NextDNS CLI** | DNS53-to-DoH proxy with in-memory LRU cache |

Total footprint: ~80 MB image, ~60 MB RAM at runtime with a 10 MB cache.

## Quick start

### Option A — One-liner (pre-built image)

No clone needed. Replace `<YOUR_TS_AUTHKEY>` and `<YOUR_NEXTDNS_PROFILE>` with your values:

```bash
docker run -d \
  --name tailwag \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun \
  -e TS_AUTHKEY=<YOUR_TS_AUTHKEY> \
  -e NEXTDNS_PROFILE=<YOUR_NEXTDNS_PROFILE> \
  -v tailwag-state:/var/lib/tailscale \
  --restart unless-stopped \
  ghcr.io/gradientc/tailwag:0.3.0
```

| Tag | Points at |
| --- | --- |
| `:0.3.0` | That exact release. Pin this in production |
| `:0.3` | Newest patch release of 0.3 |
| `:latest` | Newest full release (never a prerelease) |
| `:edge` | Tip of `main`, rebuilt only when the image's inputs change. For testing |

There is no floating `:0` tag: 0.x releases make no compatibility promise across minors. A stale `:0` from 0.2.1 may still exist in the registry; do not use it. Verify an image's origin with `gh attestation verify oci://ghcr.io/gradientc/tailwag:0.3.0 -R gradientc/Tailwag`.

- **`TS_AUTHKEY`** — create one at [Tailscale › Settings › Keys](https://login.tailscale.com/admin/settings/keys). For long-lived deployments use an **OAuth client secret** (never expires) from [Tailscale › Settings › OAuth](https://login.tailscale.com/admin/settings/oauth); it also needs `-e TS_EXTRA_ARGS=--advertise-tags=tag:dns-relay` (see [Authentication](#authentication)).
- **`NEXTDNS_PROFILE`** — the 6-7 character ID from [my.nextdns.io › Setup › Endpoints](https://my.nextdns.io) (e.g. `abc123`).

Check logs with `docker logs -f tailwag`.

### Option B — docker compose (from source)

```bash
# 1. Clone and configure
git clone https://github.com/gradientc/Tailwag.git
cd Tailwag/docker
cp .env.example .env
# Edit .env: set NEXTDNS_PROFILE and TS_AUTHKEY

# 2. Launch
docker compose up -d

# 3. Check logs
docker compose logs -f
```

Then, in the [Tailscale admin console](https://login.tailscale.com/admin/dns):

1. Add the container's Tailscale IP as a **Custom Nameserver**
2. Enable **Override local DNS**
3. For redundancy, deploy a second Tailwag on another machine

## Upgrading to 0.3.0

0.3.0 changes three behaviours. Read this before pulling the new tag.

| Change | What you see | What to do |
| --- | --- | --- |
| **No silent userspace fallback** (breaking) | Without `/dev/net/tun` the container logs `tailscaled: FATAL: /dev/net/tun not found` and stops, instead of starting in userspace mode | Pass `--device /dev/net/tun --cap-add NET_ADMIN` (the compose file already does). Only on platforms with no TUN device, set `TS_USERSPACE=true` explicitly and accept the [degraded mode](#restricted-platforms) |
| **`tailscale up --reset` on every start** | Changing `EXIT_NODE`, `SUBNET_ROUTES` or `TS_EXTRA_ARGS` between restarts now works (it used to stop the container with "requires mentioning all non-default flags") | Treat the env as the source of truth. Preferences changed with `tailscale set` inside the container are reverted on restart |
| **Health check tests the relay path** | `unhealthy` when the node has no `100.x` address or NextDNS cannot resolve upstream (SERVFAIL, REFUSED, empty answer), not only when nothing answers on loopback | Nothing, unless you relied on the old always-green check. `start-period` is now 180 s |

An OAuth client secret without `--advertise-tags` in `TS_EXTRA_ARGS` now fails at start with an explicit message instead of a failed login.

## Configuration

All configuration is through environment variables in `.env`. See [`.env.example`](.env.example) for the full reference.

The environment is the source of truth for the node's Tailscale preferences: `tailscale up --reset` runs on every start, so anything not expressed in the env (including changes made with `tailscale set` inside the container) is reset to its default on restart.

### Required

| Variable | Example | Purpose |
| --- | --- | --- |
| `NEXTDNS_PROFILE` | `abc123` | Your NextDNS profile ID |
| `TS_AUTHKEY` | `tskey-auth-...` | Tailscale auth key or OAuth client secret |

### Optional — Tailscale

| Variable | Default | Purpose |
| --- | --- | --- |
| `TS_HOSTNAME` | `tailwag` | Node name on your tailnet |
| `TS_ACCEPT_DNS` | `false` | Accept tailnet DNS (must be false for relay nodes) |
| `TS_USERSPACE` | `false` | Userspace networking (no TUN device needed). Explicit, degraded opt-in; without it a missing `/dev/net/tun` is fatal |
| `TS_EXTRA_ARGS` | | Extra flags for `tailscale up`, split on whitespace. Required with an OAuth client secret: `--advertise-tags=tag:dns-relay`. Keep it unchanged after first boot |
| `TS_DEBUG_FIREWALL_MODE` | | Leave unset (auto) or `iptables`. Do not set `nftables`: the image forces iptables-legacy ([tailscale#17854](https://github.com/tailscale/tailscale/issues/17854)) |

### Optional — NextDNS

| Variable | Default | Purpose |
| --- | --- | --- |
| `NEXTDNS_CACHE_SIZE` | `10MB` | In-memory cache (2-4 MB for constrained devices) |
| `NEXTDNS_MAX_TTL` | `5s` | Max TTL to clients — low = fast config propagation |
| `NEXTDNS_LISTEN` | `:53` | Bind address for DNS queries |

### Optional — Features

| Variable | Default | Purpose |
| --- | --- | --- |
| `EXIT_NODE` | `false` | Advertise as Tailscale exit node |
| `SUBNET_ROUTES` | | CIDR routes to advertise (e.g., `192.168.1.0/24`) |

## Authentication

**OAuth client secrets** (recommended for production) never expire and create tag-owned nodes with automatic key-expiry disabling. Because the node is owned by a tag, not a user, `tailscale up` with a `tskey-client-…` secret **requires** `--advertise-tags`. Tailwag refuses to start without it.

1. In your [tailnet policy file](https://login.tailscale.com/admin/acls), declare the tag and who may own it:
   ```json
   "tagOwners": {
     "tag:dns-relay": ["autogroup:admin"]
   }
   ```
   Make sure your ACLs/grants let tailnet clients reach `tag:dns-relay` on port 53 (UDP and TCP).
2. Create an OAuth client at [Tailscale › Settings › OAuth](https://login.tailscale.com/admin/settings/oauth) with the minimal scope: **`auth_keys` (write)**, and select `tag:dns-relay` as a tag it may assign.
3. Configure the container:
   ```bash
   TS_AUTHKEY=tskey-client-...
   TS_EXTRA_ARGS=--advertise-tags=tag:dns-relay
   ```
   Keys minted from an OAuth secret are ephemeral and not pre-approved unless you say otherwise. A relay must not be ephemeral, so append the attributes to the secret: `TS_AUTHKEY='tskey-client-...?ephemeral=false&preauthorized=true'`.

**Auth keys** work for testing but expire after 90 days maximum. Once the container has authenticated and state is persisted, the key is no longer needed — `TS_AUTHKEY` can be removed from `.env` after first boot. Leave `TS_EXTRA_ARGS` as it was: `--reset` would otherwise drop the advertised tags on the next start.

## Exit node

To use Tailwag as a VPN exit node, set `EXIT_NODE=true` in `.env` and uncomment the `sysctls` block in `docker-compose.yml`:

```yaml
sysctls:
  net.ipv4.ip_forward: "1"
  net.ipv6.conf.all.forwarding: "1"
```

After deploying, approve the exit node in the [Tailscale admin console](https://login.tailscale.com/admin/machines). This requires kernel networking mode (`TS_USERSPACE=false`) and `CAP_NET_ADMIN`.

## Platform notes

### Raspberry Pi / ARM64

Should work out of the box. The image builds for `linux/arm64` natively. On a Pi 4 with 2 GB RAM, the full stack uses ~60 MB.

### Synology NAS

Synology's Container Manager normally supports `NET_ADMIN` and TUN device mapping. Use the `docker-compose.yml` directly, or create the container manually with the equivalent capabilities. The image installs `iptables-legacy` and rewrites `/usr/sbin/iptables` → legacy (see tailscale#17854) so exit-node/subnet NAT works on Synology's older kernel.

### Fly.io (geodistributed)

Fly.io's Firecracker microVMs provide full kernel networking — no capability hacks needed. See `fly.toml` in this repo.

```bash
fly launch --no-deploy
fly secrets set TS_AUTHKEY='tskey-client-...?ephemeral=false&preauthorized=true' NEXTDNS_PROFILE=abc123
# OAuth secrets need tags: set TS_EXTRA_ARGS = "--advertise-tags=tag:dns-relay" in fly.toml [env]
fly volumes create tailwag_state --size 1 --region iad
fly deploy

# Scale to 3 regions (~$7-10/month total)
fly volumes create tailwag_state --size 1 --region ams
fly volumes create tailwag_state --size 1 --region sin
fly scale count 3 --region ams,iad,sin
```

Each region gets its own Tailscale IP. Add all of them as nameservers in the admin console for automatic geographic failover.

`fly.toml` deliberately has no `[[services]]` section: all DNS traffic arrives over the tailnet, and a UDP service on port 53 could be published on Fly's public edge as an open resolver.

### Restricted platforms

Railway, Render, and Cloud Run lack `NET_ADMIN` / `/dev/net/tun`. Since 0.3.0 the container refuses to start there unless you set `TS_USERSPACE=true` explicitly. That mode is **degraded**:

- No exit node or subnet routing.
- No kernel `tailscale0` interface, so the container has no route to `100.100.100.100`. MagicDNS forwarding (`-forwarder <tailnet>.ts.net=100.100.100.100`) is therefore expected to fail, which means tailnet clients using this relay cannot resolve `.ts.net` names through it.
- Peer queries to the node's `100.x` address reach NextDNS only through tailscaled's userspace netstack, not the kernel.

The project has not yet confirmed either of the last two points against a live tailnet in userspace mode. Test with `dig @127.0.0.1 <node>.<tailnet>.ts.net` inside the container and from a peer against the node's `100.x` address before relying on it. The health check queries `127.0.0.1` in this mode, so it cannot detect either failure.

## How it works

```
┌──────────────┐     WireGuard tunnel     ┌────────────────────────────┐     HTTPS/DoH     ┌─────────┐
│  Any device  │ ──── DNS query ─────────▶ │       Tailwag Docker        │ ────────────────▶ │  NextDNS │
│  on tailnet  │                          │                             │ ◀─────────────── │  cloud   │
└──────────────┘                          │  s6-overlay (PID 1)         │                   └──────────┘
                                          │  ├─ tailscaled (tunnel)     │
                                          │  └─ nextdns (cache+relay)   │
                                          └─────────────────────────────┘
```

### Boot sequence

1. **init-config** (oneshot) — validates env vars, writes `/etc/nextdns.conf`
2. **svc-tailscaled** (longrun) — starts the Tailscale daemon (kernel TUN; fatal if `/dev/net/tun` is missing and `TS_USERSPACE` is not `true`)
3. **tailscale-up** (oneshot) — waits up to 30 s for the daemon socket, runs `tailscale up --reset` (bounded to 120 s), then waits up to 90 s for a `100.x` address
4. **svc-nextdns** (longrun) — starts NextDNS relay bound to port 53

**Failure handling.** If bring-up fails (a oneshot exits non-zero, or times out), `S6_BEHAVIOUR_IF_STAGE2_FAILS=2` stops the container, so Docker's restart policy retries from a clean start. After boot, s6 supervises the longruns: if `tailscaled` or `nextdns` crashes, s6 restarts it in place and the container keeps running. A failure that persists shows up as `unhealthy` in the health check; plain Docker does not restart unhealthy containers, so use an orchestrator or an autoheal sidecar if you want that.

## Useful commands

```bash
# Container logs
docker compose logs -f

# Check Tailscale status
docker compose exec tailwag tailscale status

# Check NextDNS relay health (same probe as the HEALTHCHECK)
docker compose exec tailwag tailwag-health
docker inspect --format '{{json .State.Health}}' tailwag

# View NextDNS config
docker compose exec tailwag cat /etc/nextdns.conf

# Get the container's Tailscale IP
docker compose exec tailwag tailscale ip -4
```

## Building from source

```bash
# Single architecture
docker build -t tailwag .

# Multi-arch (requires buildx)
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 -t tailwag .
```

## FAQ

**Can I run multiple relays?**
Yes, and you should. Deploy Tailwag on two or more machines, add all their Tailscale IPs as nameservers. Tailscale handles failover automatically.

**Will this break MagicDNS?**
No. The NextDNS service forwards your tailnet's own suffix (`tailXXXX.ts.net`, read from `tailscale status --json` on every start) to Tailscale's internal resolver at `100.100.100.100`. Other `*.ts.net` names, such as another tailnet's public Funnel URL, go to NextDNS like any public name.

**What if I change my NextDNS config?**
The 5-second `MAX_TTL` default means clients pick up changes almost immediately. No container restart needed.

**How much RAM does it use?**
~60 MB with a 10 MB cache. Should run comfortably in 128 MB. For extremely constrained environments, set `NEXTDNS_CACHE_SIZE=2MB`.

**Can I use this without the exit node feature?**
Yes. The exit node is entirely opt-in via `EXIT_NODE=true`. Without it, the container still needs `CAP_NET_ADMIN` and the TUN device: the relay itself runs in kernel TUN mode.
