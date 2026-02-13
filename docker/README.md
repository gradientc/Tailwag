<p align="center">
  <img src="https://img.shields.io/badge/version-0.1.0-blue" alt="Version">
  <img src="https://img.shields.io/badge/platform-Docker-2496ED?logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-orange" alt="Arch">
</p>

# Tailwag Docker

**A portable, caching NextDNS relay for Tailscale networks. One container. Full stack.**

:warning: This is an experimental docker version of Tailwag. It is not yet tested.

Tailwag Docker packages [NextDNS](https://nextdns.io) CLI and [Tailscale](https://tailscale.com) into a single, minimal container with proper process supervision, persistent state, and multi-arch support. Deploy it on a Raspberry Pi, a Synology NAS, a Hetzner VPS, or across 30 Fly.io regions — same image, same config.

---

## Why?

The original [Tailwag](https://github.com/tailwag/tailwag) script turns a Debian/Ubuntu machine into a NextDNS relay for your tailnet. This is the same idea, but containerized: no host dependencies, no systemd plumbing, runs anywhere Docker runs.

Self-hosting the NextDNS CLI (instead of using Tailscale's built-in NextDNS integration) gives you local caching without round-trips, conditional per-subnet profiles, and independence from Tailscale's DNS infrastructure.

## What's inside

| Component | Role |
| --- | --- |
| **Alpine Linux** | Minimal base (~5 MB), multi-arch, matches Tailscale's own image |
| **s6-overlay v3** | PID 1, process supervision, dependency ordering, clean shutdown |
| **tailscaled** | WireGuard tunnel — kernel TUN mode by default, userspace fallback |
| **NextDNS CLI** | DNS53-to-DoH proxy with in-memory LRU cache |

Total footprint: ~80 MB image, ~60 MB RAM at runtime with a 10 MB cache.

## Quick start

```bash
# 1. Clone and configure
git clone https://github.com/tailwag/tailwag-docker.git
cd tailwag-docker
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

## Configuration

All configuration is through environment variables in `.env`. See [`.env.example`](.env.example) for the full reference.

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
| `TS_USERSPACE` | `false` | Userspace networking (no TUN device needed) |
| `TS_EXTRA_ARGS` | | Extra flags for `tailscale up` |
| `TS_DEBUG_FIREWALL_MODE` | | Override: `nftables` or `iptables` |

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

**OAuth client secrets** (recommended for production) never expire and create tag-owned nodes with automatic key-expiry disabling. Create one at [Tailscale OAuth settings](https://login.tailscale.com/admin/settings/oauth) with minimal scopes.

**Auth keys** work for testing but expire after 90 days maximum. Once the container has authenticated and state is persisted, the key is no longer needed — `TS_AUTHKEY` can be removed from `.env` after first boot.

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

Synology's Container Manager normally supports `NET_ADMIN` and TUN device mapping. Use the `docker-compose.yml` directly, or create the container manually with the equivalent capabilities. The iptables-legacy symlinks in the image handle Synology's older kernel.

### Fly.io (geodistributed)

Fly.io's Firecracker microVMs provide full kernel networking — no capability hacks needed. See `fly.toml` in this repo.

```bash
fly launch --no-deploy
fly secrets set TS_AUTHKEY=tskey-client-... NEXTDNS_PROFILE=abc123
fly volumes create tailwag_state --size 1 --region iad
fly deploy

# Scale to 3 regions (~$7-10/month total)
fly volumes create tailwag_state --size 1 --region ams
fly volumes create tailwag_state --size 1 --region sin
fly scale count 3 --region ams,iad,sin
```

Each region gets its own Tailscale IP. Add all of them as nameservers in the admin console for automatic geographic failover.

### Restricted platforms

Railway, Render, and Cloud Run lack `NET_ADMIN` / `/dev/net/tun`. Set `TS_USERSPACE=true` for basic tailnet connectivity, but note that exit node functionality will not be available.

## How it works

```
┌──────────────┐     WireGuard tunnel     ┌─────────────────────────────┐     HTTPS/DoH     ┌──────────┐
│  Any device  │ ──── DNS query ────────▶ │       Tailwag Docker        │ ────────────────▶ │  NextDNS │
│  on tailnet  │                          │                             │ ◀──────────────── │  cloud   │
└──────────────┘                          │  s6-overlay (PID 1)         │                   └──────────┘
                                          │  ├─ tailscaled (tunnel)     │
                                          │  └─ nextdns (cache+relay)   │
                                          └─────────────────────────────┘
```

### Boot sequence

1. **init-config** (oneshot) — validates env vars, writes `/etc/nextdns.conf`
2. **svc-tailscaled** (longrun) — starts the Tailscale daemon
3. **svc-tailscale-up** (oneshot) — authenticates, waits for 100.x.x.x IP assignment
4. **svc-nextdns** (longrun) — starts NextDNS relay bound to port 53

If either longrun service crashes, s6-overlay stops the container so Docker's restart policy can recover it cleanly. No "zombie container" problem.

## Useful commands

```bash
# Container logs
docker compose logs -f

# Check Tailscale status
docker compose exec tailwag tailscale status

# Check NextDNS relay health
docker compose exec tailwag dig +short @127.0.0.1 example.com

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
No. The NextDNS config includes `forwarder ts.net=100.100.100.100`, so `.ts.net` queries are forwarded to Tailscale's internal resolver.

**What if I change my NextDNS config?**
The 5-second `MAX_TTL` default means clients pick up changes almost immediately. No container restart needed.

**How much RAM does it use?**
~60 MB with a 10 MB cache. Should run comfortably in 128 MB. For extremely constrained environments, set `NEXTDNS_CACHE_SIZE=2MB`.

**Can I use this without the exit node feature?**
Yes. The exit node is entirely opt-in via `EXIT_NODE=true`. Without it, the container only needs `CAP_NET_ADMIN` and the TUN device for basic Tailscale connectivity.
