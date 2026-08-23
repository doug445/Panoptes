# Security Policy

## Supported Versions

Panoptes has no tagged releases yet. `main` is the only supported line, and
fixes land there.

| Version | Supported          |
| ------- | ------------------ |
| `main`  | :white_check_mark: |
| any older checkout | :x:     |

If you are running a checkout you pulled weeks ago, `git pull` and retry before
reporting — the issue may already be fixed. Include the commit you are on:

```bash
git -C /path/to/Panoptes rev-parse --short HEAD
```

Once the first tag exists this table will list versions instead.

## Reporting a Vulnerability

I take the security of Panoptes seriously. If you discover a security
vulnerability, please do not open a public issue.

Instead, please report it privately by emailing the report to: spilled-bowline0j@icloud.com

**What to expect:**
* **Acknowledgment:** You will receive an initial response to your report within 72 hours.
* **Updates:** I will keep you informed of my progress as I investigate the issue and develop a fix.
* **Resolution:** If the vulnerability is accepted, I will address it promptly and notify you. If declined, I will provide a clear explanation of my reasoning.

Please include as much detail as possible in your email, including steps to
reproduce. Thank you for helping keep this project secure!

## What is in scope

These tools install into `/usr/local/bin`, run as root, rewrite resolver
configuration and firewall state, and feed addresses taken from logs into other
programs. That is the interesting surface:

* **Command injection from untrusted input.** `probesource` takes a target from
  the UFW journal, the `netwatch` log, the live `ss` table or typed input, then
  hands it to `whois`, `dig`, `tcpdump`, `tshark` and `p0f`. An address that
  escapes into a shell is a real finding — a hostile scanner controls what ends
  up in those logs.
* **Privilege escalation** through the install paths, or through any tool that
  writes somewhere a non-root user can influence before root reads it.
* **A hardening tool that fails open.** `harden-dns.sh` reporting success while
  leaving DNSSEC or DoT off is a vulnerability, not a cosmetic bug. So is
  `dns-toggle` leaving `resolved.conf` mutable after it claims to have restored
  the `chattr +i` lock.
* **`warp-killswitch` not killing.** Reporting `killed` while the machine is
  still reachable through WARP, or failing to restore the previous DNS verbatim
  on `up`.
* **Anything that writes outside its documented paths**, or that a read-only
  tool writes at all. `audit-dns.sh`, `netcheck`, `nettop`, `checkdns`,
  `dns-status.sh` and `wifi-recover.sh` without `--repair` must change nothing.

## What is out of scope

* **Bugs in the tools Panoptes drives** — `systemd-resolved`, NetworkManager,
  `firewalld`, `warp-cli`, `tcpdump`, `p0f`, `arp-scan`. Report those upstream.
* **The privacy policy or filtering behaviour of any resolver.** The AdGuard and
  Cloudflare addresses are a hardcoded default, documented as opinionated and
  meant to be edited.
* **The investigation tools revealing information about your own network.** That
  is what they are for.
* **Missing optional dependencies** degrading a tactic to unavailable.

## Before you send diagnostics

Panoptes output is network output, and a bug report is not a good reason to
publish your own topology. Read what you are about to attach:

* `nettop`, `netcheck` and `probesource` print MAC addresses, Wi-Fi SSIDs, your
  public address and third-party addresses.
* `probesource`'s `pcap`, `tshark` and `p0f` tactics capture live traffic off
  the wire. Do not attach a capture you have not read.
* `~/.local/share/netwatch/events.log` is a running record of everything that
  has touched the machine.

Redact addresses down to what the bug needs, and send the smallest thing that
demonstrates it.
