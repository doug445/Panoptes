# Security Policy

## Supported Versions

Panoptes is maintained by one person and carries no backport branches. Fixes
land on `main` and go out in the next tagged release. Only the newest release
is supported; there is no long-term-support line and older tags do not receive
patches.

| Version | Supported |
| ------- | --------- |
| `main` | :white_check_mark: fixes land here first |
| Newest tagged release | :white_check_mark: |
| Any earlier tag | :x: upgrade to the newest release |

The [releases page](https://github.com/doug445/Panoptes/releases) lists every
tag, newest first, and [`CHANGELOG.md`](CHANGELOG.md) records what changed in
each one.

If you are running a checkout you pulled weeks ago, `git pull` and retry before
reporting — the issue may already be fixed. Include what you are running:

```bash
git -C /path/to/Panoptes describe --tags --always --dirty
```

A `-dirty` suffix means the working tree has local modifications, and a hash
with no tag means the checkout is somewhere between releases. Say so in the
report either way — it changes what I can reproduce.

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
configuration and firewall state, drop one file into
`/etc/NetworkManager/conf.d/`, and feed addresses taken from logs into other
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
  `dns-status.sh`, `persistcheck` (beyond its own snapshot under
  `~/.local/state/panoptes`) and `wifi-recover.sh` without `--repair` must
  change nothing.
* **The installers fetching or trusting the wrong thing.** `panoptes-deps.sh`,
  `warp-setup.sh`, `ech-build.sh` and `ech-browsers.sh` all run as root and pull
  in software: a repository added without `gpgcheck`, an unverified tarball, a
  source tree taken from the wrong ref, or a browser profile edited outside the
  documented paths.
* **The MAC randomization drop-in failing quietly, or landing where it must
  not.** `install.sh` writes `mac-randomization.conf` into
  `/etc/NetworkManager/conf.d/`. Three things there are findings: the guard not
  declining on a Wi-Fi driver that cannot associate with a cloned MAC (`wl`,
  `b43`, `b43legacy`, `brcmsmac`), which leaves a machine with no Wi-Fi and no
  obvious cause; the drop-in being written when `--no-mac-random` was passed, or
  by any mode other than a full install; and a displaced config being saved
  anywhere NetworkManager will still read it — the `.pre-panoptes` suffix is
  load-bearing, because `conf.d` parses every `*.conf`. Randomization silently
  *not* taking effect while the tools report that it has is also in scope:
  `netcheck` claiming MAC privacy that the adapter is not applying is a false
  assurance about a privacy control.
* **`ech-build.sh` shadowing the system TLS stack.** It installs curl into
  `/usr/local/bin`, which precedes `/usr/bin` on `PATH` — including root's
  `secure_path` — so it silently becomes the curl every script on the machine
  gets. Anything that widens that beyond curl, or that leaves the development
  OpenSSL linkable by other programs, is a finding. Since 3.0.0 curl is linked
  statically precisely because a shared `libcurl` in `/usr/local/lib` was
  found to be loaded by every program on the Debian family.
* **The passwordless sudoers rules widening.** `install.sh` writes
  `/etc/sudoers.d/panoptes-dns-toggle` (`dns-toggle`, which takes no
  arguments) and `warp-killswitch install` writes
  `/etc/sudoers.d/panoptes-warp-killswitch`, pinned to exactly `down`, `down
  --keep-dns`, `up`, `heal`, `heal manual`, `status`, `state`, `park` and
  `unpark`. Both are checked with `visudo -c` before they are installed. A
  rule with a wildcard, an unpinned argument list, or a target outside a
  root-owned directory chain is a finding, as is any way for a process running
  as the user to make the helper do something outside those nine paths.
* **`proton-setup.sh` trusting the wrong thing.** Proton's signing keys are
  pinned by fingerprint in the script; on APT the bootstrap must verify the
  signed `InRelease`, the `Packages` hash and the release package hash before
  `dpkg` runs, and refuse on any mismatch. A path that installs a package or a
  repository without that chain, or that accepts a key whose fingerprint
  differs, is a finding.
* **`proton-fallback` raising Proton VPN over a live WARP.** The tool must
  park WARP (or refuse) before it connects; connecting with WARP's daemon
  running is the wedge the park exists to prevent. Likewise `warp-tray` must
  refuse `connect` and `up` while Proton VPN is connected.
* **`endpoint-setup.sh` trusting the wrong thing, or the suite's OpenSnitch
  rules being wider than stated.** osquery's key is pinned by fingerprint;
  OpenSnitch on Fedora and openSUSE must verify the maintainer's signed
  `readme.txt` and the per-package SHA-512 before the package manager sees a
  file. The seeded rules are `allow` by exact process path, and for the two
  general tools (`ping`, `curl`) pinned to the watchdog's destinations; a rule
  that allows a general interpreter or any destination is a finding. So is
  `endpoint-setup.sh` overwriting an `osquery.conf` or an OpenSnitch rule it
  did not write.
* **`persistwatch` running untrusted text.** Everything it reads comes from
  osqueryd's results log — process names, cron commands, SSH key comments,
  file paths chosen by whoever put them there. It must only ever pass those
  as arguments to `notify-send`, never through a shell.
* **The trays claiming an action happened.** `dns-tray` and `warp-tray` run
  their helpers with `sudo -n` and must report a refusal; a success
  notification for an action that did not run is a finding.

## What is out of scope

* **Bugs in the tools Panoptes drives** — `systemd-resolved`, NetworkManager,
  `firewalld`, `warp-cli`, `tcpdump`, `p0f`, `arp-scan`. Report those upstream.
* **The privacy policy or filtering behaviour of any resolver.** The AdGuard and
  Cloudflare addresses are a hardcoded default, documented as opinionated and
  meant to be edited.
* **The investigation tools revealing information about your own network.** That
  is what they are for.
* **Missing optional dependencies** degrading a tactic to unavailable.
* **What MAC randomization does not hide.** A randomized MAC stops an access
  point recognizing the adapter across visits. It does not make you anonymous:
  the portal login, the DHCP hostname, the traffic itself and every layer above
  link-local still identify you. Captive portals breaking is documented
  behaviour, not a bug — every reconnect is a new client by design. Drivers
  outside the declined list that turn out not to handle a cloned MAC are a
  driver limitation; tell us anyway and the list grows, but the flaw is not
  Panoptes'.
* **Bugs in the OpenSSL ECH branch itself.** `ech-build.sh` builds an upstream
  OpenSSL ECH branch rather than a release; it was written before OpenSSL
  4.0.0 (April 2026), the first release with ECH. Flaws
  in that code belong upstream; how Panoptes builds, isolates and installs it
  is in scope.

## Standing rules

These came out of the 3.0.0 audit (see the README) and bind every future
change:

* **Every `--dry-run` is dry.** A dry run may read, print and create a scratch
  file; it may not write, rename, restart or replay anything.
* **Every lock is restored on every exit path.** A tool that removes
  `chattr +i` installs a trap that puts it back before it does anything else.
* **No tool deletes a device it did not create.** Physical NICs and bridges
  are never flushed or removed by a repair rung.
* **Names from the network and the user are data.** SSIDs, profile names and
  gateway identities are carried newline-separated or in arrays, never
  word-split, and never spliced into a command string.
* **A read-only tool changes nothing**, including resolver caches.
* **Passwordless rules are pinned and `visudo`-checked**, and the installer
  names any other rule on the machine that covers the same binary.
* **Vendor keys are pinned where the vendor publishes a fingerprint**, and
  the whole chain from key to package is verified before a package manager is
  handed anything.
* **Anything a sleep hook or a oneshot unit must finish is handed to a
  transient unit**, because systemd kills what the hook leaves behind.
* **Lint stays clean** (`shellcheck -S warning`, `ruff` default ruleset) and
  CI actions stay pinned to commit SHAs.

Accepted on purpose, with the reasoning here so it survives: the trays can
tear WARP down, park it and rebuild it without a password (they cannot work
otherwise; every invocation is pinned, verified, notified and logged);
Cloudflare's repository key is fetched over HTTPS rather than pinned (no
published fingerprint; the repository is `signed-by` / `gpgcheck=1`);
`probesource` interpolates a strictly validated IP literal into its tactic
strings; `ech-build.sh` builds OpenSSL's ECH branch and curl from upstream
`git` HEAD; and `proton-fallback`'s `app` driver can only open the window and
ask you to click when no CLI is present.

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
