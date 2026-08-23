<p align="center">
  <img alt="Panoptes — Superior Linux Network Security"
       src="docs/brand/panoptes-logo-dark.svg" width="480">
</p>

# Panoptes — the all-seeing network watch

**A Linux network monitoring, DNS hardening and intrusion-investigation suite.**
Fourteen field-tested command-line tools for DNS leak auditing, DNSSEC and
DNS-over-TLS enforcement, Encrypted Client Hello (ECH) verification, Cloudflare
WARP control, firewalld/nftables drop monitoring, ARP-spoofing detection, Wi-Fi
recovery, and deep investigation of any IP that touches your machine.

[![lint](https://github.com/doug445/Panoptes/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/Panoptes/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25)
![Platform](https://img.shields.io/badge/platform-Linux-blue)

Built and used daily on **Fedora**. The suite is tested and working on
**Linux Mint**, **Manjaro**, **EndeavourOS**, **Debian/Ubuntu** and
**Fedora Asahi Remix** (Apple Silicon). It should work on any other Linux
distribution too — the list above is where it has been run, not a limit.
Anything running **systemd-resolved** and **NetworkManager** is in scope.

---

## Why this exists

Most network trouble on a modern Linux desktop is not a routing problem. It is a
*DNS* problem wearing a routing problem's clothes: your VPN pushed its own
resolver, DHCP quietly overrode the one you configured, `systemd-resolved` is
answering from a per-link server you never chose, or a killswitch left an
`nftables` table behind after the daemon died.

These tools were written one outage at a time, each after a real failure that
took hours to diagnose by hand. `netmaster` exists because a Wi-Fi link
associated fine, LAN worked, and the internet was simply gone — and stayed gone
across reboots. `probesource` exists because "who is 5.42.x.x and why is it
knocking" deserved a better answer than four terminals of `whois`, `dig` and
`tcpdump`.

## Quick start

```bash
git clone https://github.com/doug445/Panoptes.git
cd Panoptes
sudo ./install.sh
```

Then:

```bash
checkdns              # resolver, WARP, mDNS and ECH status in one readout
sudo audit-dns.sh     # what controls DNS here, and where a leak could get in
netcheck              # interfaces, Wi-Fi band/bitrate, firewall, whois
```

Nothing installs a service or changes your system until you ask it to.
`audit-dns.sh` and `netcheck` are strictly read-only.

---

## The tools

### DNS — auditing, hardening, leak prevention

| Tool | What it does |
|------|--------------|
| **`audit-dns.sh`** | Read-only audit of everything that can set DNS on the box: `systemd-resolved` global and per-link servers, NetworkManager connection overrides, `/etc/resolv.conf` and its symlink target, VPN pushed-DNS in WireGuard and OpenVPN configs, and `chattr` immutability. Prints where a **DNS leak** could get in. Run as root for full visibility — VPN configs are usually mode 600. |
| **`harden-dns.sh`** | Idempotent DNS hardening: enforces **DNSSEC**, **DNS-over-TLS (DoT)** with hostname pinning, and a fixed resolver policy across NetworkManager and `systemd-resolved`. Re-running changes nothing if already in the desired state. `--dry-run` supported. Policy is overridable by environment: `PRIMARY_DNS`, `FALLBACK_DNS`, `DOMAINS`, `DNSSEC_MODE`, `DOT_MODE`. |
| **`checkdns`** | One-screen status: which resolvers are live (annotated by provider), Cloudflare WARP state, Avahi/mDNS status, and **Encrypted Client Hello** verification at both layers — the DNS `HTTPS` record carrying the ECHConfig, and a real `curl --ech hard` handshake. |
| **`dns-toggle`** | Flips `systemd-resolved` between a filtering resolver (AdGuard) and a security-filtering one (Cloudflare `1.1.1.2`), handling the `chattr +i` immutability lock around `resolved.conf` and restoring it afterwards. |
| **`dns-status.sh`** | One-line current-resolver indicator, for status bars and tray applets. |
| **`dns-tray`** | System tray applet: shows the active resolver and toggles it on click. Daemonizes cleanly so closing the shell does not kill it. |

### Monitoring and investigation

| Tool | What it does |
|------|--------------|
| **`netwatch`** | Watches **firewalld** dropped packets, new inbound connections and **ARP anomalies**, and raises desktop notifications. Runs as a systemd service; resolves D-Bus so `notify-send` works from a unit. |
| **`probesource`** | **The centrepiece.** Investigate any address — a firewall drop, a probe, a live connection. Pass one in as `probesource <ip>`, or pick a target from the UFW journal, the `netwatch` log, the live `ss` table, or type one in. Then run a single tactic, a one-pass sweep, or a relentless escalating sweep. Passive tactics: `whois`, reverse DNS, GeoIP, journal and `netwatch` history, neighbour table and OUI lookup, live socket state, conntrack, ipset membership, short `tcpdump`/`tshark` capture, and a `p0f` fingerprint listener. |
| **`nettop`** | Lists hosts on the LAN and WAN with vendor attribution — active `arp-scan` for the LAN, falling back to `ip neigh` plus OUI lookup, with `whois` filling in vendor for public addresses. |
| **`netcheck`** | Full network status readout: every interface, Wi-Fi SSID, band, channel, frequency, protocol and bitrate for each adapter, firewall state, and cached `whois` for public addresses (private ranges are skipped). |

### Repair and control

| Tool | What it does |
|------|--------------|
| **`netmaster`** | The master repair tool, absorbing five earlier one-off scripts. Built from a specific outage: Wi-Fi associated, LAN worked, internet was gone, and it survived reboots — the cause was a stale VPN `tun` device NetworkManager had adopted and persisted with hundreds of static routes. Delegates to the other tools where they exist but does not require them. |
| **`wifi-recover.sh`** | Wi-Fi diagnosis and repair. Defaults to **diagnose-only, no system changes**. `--repair` performs safe reversible fixes; `--reload-modules` adds aggressive driver reloads (risky on patched `wl`); `--bundle` tars the logs for carrying off the box. |
| **`warp-killswitch`** | Tears Cloudflare WARP down to nothing — stops *and disables* the daemon so it stays down across reboot, removes its `nftables` table, and drops to plain DNS. `up` restores the previous DNS verbatim and reconnects. `state` prints `killed` or `armed`. For when WARP blackholes your connectivity and you need out, now. |
| **`warp-tray`** | Cloudflare WARP system tray applet with a single-instance guard, and a right-click path to the killswitch. |

---

## How it compares

| | Panoptes | `nmcli` / `resolvectl` | Wireshark | Fail2ban |
|---|---|---|---|---|
| Audits *every* source that can set DNS | **yes** | no — shows state, not causes | no | no |
| Detects VPN pushed-DNS leaks | **yes** | no | manually | no |
| Verifies DNSSEC + DoT + ECH end to end | **yes** | partial | manually | no |
| Investigates an unknown source IP | **yes**, 11 tactics | no | packet-level only | no |
| Watches firewall drops + ARP anomalies | **yes** | no | yes, manually | logs only |
| Recovers a broken Wi-Fi link | **yes** | no | no | no |
| Desktop tray integration | **yes** | no | no | no |
| Learning curve | one command | low | steep | moderate |

Panoptes is not an IDS and does not try to be. It is the layer between "something
is wrong with my network" and "I know exactly what and why".

---

## Installation

```bash
sudo ./install.sh              # installs everything
sudo ./install.sh --dns-only   # just the DNS tools
./install.sh --user            # user tools only, no sudo, into ~/.local/bin
sudo ./uninstall.sh            # removes everything it installed
```

System tools land in `/usr/local/bin`, user tools and tray applets in
`~/.local/bin`. Nothing is enabled as a service automatically.

### Dependencies

Everything degrades gracefully — a missing optional tool disables one tactic, it
does not break the run.

| Required | Optional (per tactic) |
|---|---|
| `bash` 4+, `systemd-resolved`, `iproute2`, `python3` | `arp-scan`, `whois`, `tcpdump`, `tshark`, `p0f`, `conntrack`, `ipset`, `dig` (bind-utils), `firewalld`, `warp-cli` |

---

## FAQ

### How do I check for a DNS leak on Linux?

Run `sudo audit-dns.sh`. It enumerates every mechanism that can set a resolver —
`systemd-resolved` global and per-link, NetworkManager per-connection overrides,
`/etc/resolv.conf` and what it points at, and pushed-DNS lines inside WireGuard
and OpenVPN configs — then tells you which one is actually winning. Most "leaks"
are a per-link resolver from DHCP quietly outranking your global setting.

### How do I know if DNS-over-TLS or DNSSEC is actually working?

`checkdns`. It reads live resolver state rather than what your config file
claims, and annotates each server with its provider so a substituted resolver is
obvious at a glance.

### How do I verify Encrypted Client Hello (ECH) is working?

`checkdns` tests both layers: whether the DNS `HTTPS` record carries an
ECHConfig, and whether a real TLS handshake with `curl --ech hard` succeeds
against `defo.ie`. Note that stock distribution `curl` builds often lack ECH
support entirely — the tool detects this and says so rather than reporting a
false failure.

### Something is probing my machine. How do I find out who?

`probesource`. Pick the address from your firewall journal or the live socket
table and it runs up to eleven investigative tactics, from `whois` and GeoIP
through conntrack state to a live `tcpdump` capture and a `p0f` fingerprint
listener — escalating from entirely passive to active only as you allow.

If you already know the address, pass it straight in and skip the picker:

```bash
probesource 203.0.113.42        # IPv4 or IPv6
```

You still choose the investigation mode, so nothing is sent to the target
until you pick one — `All passive` never emits a packet to it at all.

### Cloudflare WARP broke my internet. How do I get out?

`sudo warp-killswitch down`. It stops and *disables* the daemon so it does not
come back on reboot, deletes its `nftables` table, and restores plain DNS.
`sudo warp-killswitch up` puts everything back exactly as it was.

### My Wi-Fi associates but there is no internet, and rebooting does not fix it.

That is precisely what `netmaster` was written for. Run it. Also try
`sudo wifi-recover.sh` — diagnose-only by default, so it is safe to run first.

### Does this work on Debian, Ubuntu, Arch, or Apple Silicon?

Yes. The DNS tools target anything using NetworkManager plus
`systemd-resolved`, which covers Fedora, Linux Mint, Manjaro, EndeavourOS,
Debian and Ubuntu. `netcheck`, `nettop` and `probesource` are
distribution-agnostic. Everything runs on **Fedora Asahi Remix** on Apple
Silicon — that is where it is developed. The suite is tested and working on
all of them.

**A distribution not on that list should work too.** Nothing here is tied to a
package manager or a release — the requirements are `systemd-resolved`,
NetworkManager, and the optional tools listed under
[Dependencies](#dependencies). If your distribution has those, the suite
applies. If something does not work on one that is not listed, that is a bug
worth reporting.

### Is any of this safe to run on a production machine?

`audit-dns.sh`, `netcheck`, `nettop`, `checkdns`, `dns-status.sh` and
`wifi-recover.sh` (without `--repair`) make **no changes at all**. Everything
that writes says so, and `harden-dns.sh` supports `--dry-run`.

---

## Notes and caveats

- **Resolver choices are opinionated.** `dns-toggle` and `dns-status.sh` are
  hardcoded to flip between AdGuard and Cloudflare's security resolver, because
  that is the pair they were written for. Change the addresses at the top of
  each file to suit. `harden-dns.sh` is the one that takes policy from the
  environment instead.
- **Lint is clean and enforced.** CI fails on any `shellcheck` warning and on
  the full default `ruff` ruleset. Where word splitting is deliberate — a file
  list expanding into `tar` arguments, a tactic-id list into `run_set` — the
  line carries an inline `shellcheck disable=SC2046` stating why, rather than
  being quoted into something that would not work.
- **`netwatch` needs a firewalld log target** to have anything to read.

## Contributing

Issues and pull requests welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for
the diagnostic bundle to attach to a bug report, the full local lint block that
mirrors CI, and what a patch is expected to carry.

The short version — run this before opening a PR:

```bash
shellcheck -S warning bin/* install.sh uninstall.sh   # bash tools
ruff check --isolated bin/dns-tray bin/warp-tray      # python tools
```

Both are clean on `main` and CI fails on any regression.

Found a security issue? Do not open a public issue — see
[`SECURITY.md`](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 William MacKinnon.
