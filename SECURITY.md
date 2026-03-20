# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Tailwag, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, open a [GitHub Security Advisory](https://github.com/gradientc/Tailwag/security/advisories/new) (private by default) or email the maintainers directly. We aim to acknowledge reports within 48 hours and provide a fix or mitigation within 14 days.

## Supported Versions

Only the latest release is actively maintained and receives security fixes.

## Known Limitations

### `tailwag.sh` — NextDNS GPG key fetched without checksum

During installation, `tailwag.sh` fetches the NextDNS apt signing key directly from `repo.nextdns.io` and pipes it into `gpg`:

```bash
curl -fsSL https://repo.nextdns.io/nextdns.gpg | gpg --dearmor ...
```

This means a compromised `repo.nextdns.io` or a network-level MITM could substitute a malicious key. This is a standard limitation of the apt repository bootstrap pattern (shared by many popular tools). For high-security environments, download the GPG key out-of-band, verify its fingerprint against a trusted source, and install it manually before running the script.

### `curl | bash` install pattern

The one-liner install (`curl ... | sudo bash`) is convenient but inherits the risks of the transport layer — DNS hijacking or BGP hijacking of `raw.githubusercontent.com` could serve a modified script. Mitigations:

- GitHub enforces HTTPS with a CA-pinned certificate, making passive MITM impractical.
- The script validates all its own inputs (profile ID, Tailscale addresses) and refuses to proceed on unexpected values.
- For sensitive environments, use the manual download method, inspect the script, and run it locally.

### Docker image — binary checksums

The Docker build stages download Tailscale, NextDNS, and s6-overlay binaries and verify their SHA256 checksums against the official release files. If the upstream release servers are compromised at the source, both the binary and checksum file would be affected. This is a known limitation of the single-source verification model.
