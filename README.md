<p align="center">

<img src="https://img.shields.io/badge/version-0.0.2-blue" alt="Version">

<img src="https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-orange" alt="Platform">

</p>

# 🐕 Tailwag

**A caching DNS relay for Tailscale networks. One script. Full stack.**

Tailwag turns any Debian/Ubuntu machine on your tailnet into a [NextDNS](https://nextdns.io)-powered DNS relay — with caching, dual-stack IPv4/IPv6, firewall rules, and a systemd boot fix, in under a minute.

---

## Why?

Tailscale's [DNS settings](https://login.tailscale.com/admin/dns) let you point your entire tailnet at custom nameservers. Pair that with NextDNS and you get ad-blocking, threat protection, and analytics across every device, no per-device app required.

The problem: getting NextDNS to **bind only to your Tailscale address**, **survive reboots**, and **not create DNS loops** takes a surprising amount of plumbing. Tailwag does all of it in one idempotent script.

## What it does

| Step | Detail |
| --- | --- |
| **Install** | Adds the official NextDNS apt repo and installs the CLI |
| **Configure** | Binds NextDNS to your Tailscale IPv4 (and IPv6) addresses only |
| **Cache** | Enables a 20 MB in-memory cache with a 5 s client TTL for fast config propagation |
| **Boot fix** | Installs a systemd drop-in so NextDNS waits for Tailscale before starting |
| **Firewall** | Opens port 53 on `tailscale0` via UFW (if active) |
| **Loop prevention** | Prompts to run `tailscale set --accept-dns=false` on the relay itself |

Every run produces the same configuration state. Safe to re-run.

## Requirements

> Experimental docker version at [docker/README.md](docker/README.md)

- **OS:** Debian or Ubuntu (uses `apt`)
- **Tailscale:** Installed and authenticated (`tailscale status` must work)
- **NextDNS account:** [Get a free profile ID](https://my.nextdns.io) → Setup → Endpoints
- **Root access**

## Quick start

```bash
# On your relay server:
sudo ./tailwag.sh abc123    # replace with your NextDNS profile ID
```

Then, in the [Tailscale admin console](https://login.tailscale.com/admin/dns):

1. Add the relay's Tailscale IP as a **Custom Nameserver**
2. Enable **Override local DNS**
3. For redundancy, run Tailwag on a second server and add that IP too

## Configuration

Defaults are set for home and small-office tailnets. Edit the variables at the top of the script to tune:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CACHE_SIZE` | `20MB` | In-memory DNS cache size |
| `MAX_TTL` | `5s` | Max TTL served to clients — low value means NextDNS config changes propagate fast |
| `ENABLE_IPV6` | `true` | Bind to Tailscale's IPv6 address as well |

## Useful commands

```bash
nextdns status              # Relay health check
nextdns log                 # Live query log (Ctrl-C to stop)
cat /etc/nextdns.conf       # View current configuration
journalctl -u nextdns -f    # Follow service logs
```

## How it works

```
┌──────────────┐     Tailscale tunnel     ┌──────────────────┐     HTTPS/DoH     ┌──────────┐
│  Any device  │ ──── DNS query ────────▶ │  Tailwag relay  │ ────────────────▶ │  NextDNS │
│  on tailnet  │                          │  (NextDNS CLI)   │ ◀──────────────── │  cloud   │
└──────────────┘                          │  cache · filter  │                   └──────────┘
                                          └──────────────────┘
```

1. Tailscale clients send DNS queries to the relay's Tailscale IP.
2. NextDNS CLI resolves upstream via DoH, applies your NextDNS profile (ad-blocking, security, allowlists).
3. Responses are cached locally; subsequent queries for the same domain are served instantly.
4. The systemd drop-in ensures the relay survives reboots by waiting for Tailscale to be ready.

## FAQ

**Can I run multiple relays?**

Yes, and you should. Run Tailwag on two servers, add both IPs as nameservers in Tailscale, and you get automatic failover.

**Will this break MagicDNS?**

No. Tailwag forwards `.[ts.net](http://ts.net)` queries to `100.100.100.100` (Tailscale's internal resolver), so MagicDNS hostnames keep working.

**What if I change my NextDNS config (e.g., allowlist a domain)?**

The 5-second `MAX_TTL` means clients pick up changes almost immediately. No restart needed.
