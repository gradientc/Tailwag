<p align="center">
  <a href="https://github.com/gradientc/Tailwag/releases">
    <img src="https://img.shields.io/github/v/release/gradientc/Tailwag?label=version" alt="Version">
  </a>
  <img src="https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-orange" alt="Platform">
  <a href="https://github.com/gradientc/Tailwag/pkgs/container/tailwag">
    <img src="https://img.shields.io/badge/ghcr.io-gradientc%2Ftailwag-blue?logo=github" alt="GHCR">
  </a>
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
| **Cache** | Enables a 20 MB in-memory cache with a 30 s client TTL; the relay cache is flushed on every profile change |
| **Boot fix** | Installs a systemd drop-in so NextDNS waits for Tailscale before starting |
| **Firewall** | Opens port 53 on `tailscale0` via UFW (if active) |
| **Loop prevention** | Runs `tailscale set --accept-dns=false` on the relay itself, on every run (other node settings untouched) |

Every run produces the same configuration state. Safe to re-run.

## Requirements

> Docker image: [`ghcr.io/gradientc/tailwag`](https://github.com/gradientc/Tailwag/pkgs/container/tailwag) · docs in [docker/README.md](docker/README.md)

- **OS:** Debian or Ubuntu (uses `apt`)
- **Tailscale:** Installed and authenticated (`tailscale status` must work)
- **NextDNS account:** [Get a free profile ID](https://my.nextdns.io) → Setup → Endpoints
- **Root access**

## Quick start

Every [GitHub release](https://github.com/gradientc/Tailwag/releases) carries `tailwag.sh`, a `SHA256SUMS` file and a signed build attestation. The commands below fetch the latest release, not the moving `main` branch.

**One-line install (interactive)**

```bash
curl -fsSL https://github.com/gradientc/Tailwag/releases/latest/download/tailwag.sh | sudo bash
```

**One-line install (with argument)**

```bash
curl -fsSL https://github.com/gradientc/Tailwag/releases/latest/download/tailwag.sh | sudo bash -s -- abc123
```

**Verified manual run (recommended)**

```bash
curl -fsSLO https://github.com/gradientc/Tailwag/releases/latest/download/tailwag.sh
curl -fsSLO https://github.com/gradientc/Tailwag/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
# Optional, stronger: proves the file was built by this repo's release workflow
gh attestation verify tailwag.sh -R gradientc/Tailwag
sudo bash tailwag.sh abc123
```

`SHA256SUMS` comes from the same release, so it catches corruption, not a tampered release; the attestation is the check that does. To pin a version, replace `latest/download` with `download/<tag>` (e.g. `download/0.3.0`). The development version is at `https://raw.githubusercontent.com/gradientc/Tailwag/main/tailwag.sh`.

Then, in the [Tailscale admin console](https://login.tailscale.com/admin/dns):

1. Add the relay's Tailscale IP as a **Custom Nameserver**
2. Enable **Override local DNS**
3. For redundancy, run Tailwag on a second server and add that IP too

## Configuration

Defaults are set for home and small-office tailnets. Edit the variables at the top of the script to tune:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CACHE_SIZE` | `20MB` | In-memory DNS cache cap (same default as the container). Memory is used only by cached entries; 20 MB holds roughly 60-120k responses |
| `MAX_TTL` | `30s` | Max TTL handed to clients. Bounds how long a client keeps an answer after a profile change; the relay cache itself is flushed by NextDNS on every profile update |
| `ENABLE_IPV6` | `true` | Bind to Tailscale's IPv6 address as well (skipped automatically if the address is not on `tailscale0`, e.g. IPv6 disabled in the kernel) |

One environment variable changes behaviour at run time:

| Variable | Effect |
| --- | --- |
| `TAILWAG_KEEP_ACCEPT_DNS=1` | Skip the `accept-dns=false` loop guard (prints a warning with the manual command). Only for nodes that are not used as nameservers. |

```bash
sudo TAILWAG_KEEP_ACCEPT_DNS=1 ./tailwag.sh abc123
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Installed and healthy |
| `1` | Not installed (fatal error before or during setup) |
| `2` | Usage error (no profile ID and no terminal to prompt on, or invalid profile ID) |
| `3` | Installed, but needs attention: the loop guard could not be applied, or the post-install DNS probe failed. NextDNS is running; read the `WARN` lines. |

## Useful commands

```bash
nextdns status              # Relay health check
nextdns log                 # Live query log (Ctrl-C to stop)
nextdns cache-stats         # Cache hit / miss counters since the last restart
cat /etc/nextdns.conf       # View current configuration
journalctl -u nextdns -f    # Follow service logs
```

### Cache metrics

The host config enables `cache-metrics true`, so the relay keeps Ristretto's counters as well as the plain hit/miss pair. `nextdns cache-stats` shows the hit/miss pair. The richer counters (evictions, bytes added and evicted) are only exposed on NextDNS's control socket; NextDNS 1.47 has no CLI subcommand for them, so read them with one JSON line:

```bash
sudo python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.connect("/var/run/nextdns.sock");s.sendall(b"{\"name\":\"cache-metrics\"}\n");print(s.recv(4096).decode())'
```

Hit ratio is `hit / (hit + miss)`. If `keys_evicted` is still 0 after a day of traffic, `CACHE_SIZE` is large enough and raising it changes nothing; if it keeps climbing, the working set is bigger than the cap. Counters reset when nextdns restarts.

## How it works

```
┌──────────────┐     Tailscale tunnel     ┌─────────────────┐     HTTPS/DoH     ┌─────────┐
│  Any device  │ ──── DNS query ─────────▶ │  Tailwag relay  │ ────────────────▶ │  NextDNS │
│  on tailnet  │                          │  (NextDNS CLI)   │ ◀─────────────── │  cloud   │
└──────────────┘                          │  cache · filter  │                   └──────────┘
                                          └─────────────────┘
```

1. Tailscale clients send DNS queries to the relay's Tailscale IP.
2. NextDNS CLI resolves upstream via DoH, applies your NextDNS profile (ad-blocking, security, allowlists).
3. Responses are cached locally; subsequent queries for the same domain are served instantly.
4. The systemd drop-in ensures the relay survives reboots: a pre-start helper (`/usr/local/libexec/tailwag/wait-listen-addrs`) blocks until every listen address in `/etc/nextdns.conf` is on `tailscale0`, for up to 120 s.

## FAQ

**Can I run multiple relays?**

Yes, and you should. Run Tailwag on two servers, add both IPs as nameservers in Tailscale, and you get automatic failover.

**Will this break MagicDNS?**

No. Tailwag forwards `.ts.net` queries to `100.100.100.100` (Tailscale's internal resolver), so MagicDNS hostnames keep working.

**What if I change my NextDNS config (e.g., allowlist a domain)?**

NextDNS flushes the relay cache the moment the profile changes, and the 30-second `MAX_TTL` bounds how long a client keeps an older answer. No restart needed.
