# Changelog

All notable changes to Panoptes are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

## [2.5.0] — 2026-08-24

### Added

- **Wi-Fi MAC randomization is now part of a full install.** Panoptes shipped
  three tools that *read* or *undo* MAC randomization — `netcheck` reports it,
  `netmaster` flags it as a captive-portal blocker, `wifi-recover.sh` disables
  it — but nothing that turned it on. The enabler had been left behind in the
  predecessor deploy kit. `share/nm/mac-randomization.conf` is now installed to
  `/etc/NetworkManager/conf.d/` by `sudo ./install.sh`, setting
  `wifi.scan-rand-mac-address=yes` and `wifi.cloned-mac-address=random` so an
  access point cannot recognize the machine across visits. Skip it with
  `--no-mac-random`. This is the only file Panoptes places outside a `bin`
  directory.
- **The installer declines MAC randomization on drivers that cannot associate
  with a cloned MAC.** `wl`, `b43`, `b43legacy` and `brcmsmac` — Intel Macs and
  older Broadcom laptops — take the MAC from the chip: NetworkManager clones
  it, association fails, and the machine has no Wi-Fi at all, which is the exact
  hole `wifi-recover.sh` exists to dig out of. On a match the installer names
  the interface and driver, explains why, writes nothing, and prints the manual
  override. The test is the driver rather than the vendor, so `brcmfmac`
  Broadcom parts — Apple Silicon BCM4377/4387, and the SDIO parts on
  single-board machines — are not skipped; they clone correctly.
- `uninstall.sh` removes the drop-in, but only when it is still byte-for-byte
  the file Panoptes shipped; an edited or pre-existing file is left alone and
  reported. A config displaced at install time is saved as
  `mac-randomization.conf.pre-panoptes` — deliberately not a `.conf` suffix, as
  NetworkManager reads only `*.conf` from `conf.d` — and is put back on
  uninstall.

### Fixed

- `uninstall.sh` never removed `warp-setup.sh`. It was added to `install.sh`'s
  system tools without being added to the uninstaller's, so it survived a
  `sudo ./uninstall.sh` in `/usr/local/bin`.

### Changed

- **`README.md` has a "Captive portals" section.** Hotel, airport and café
  Wi-Fi is where a hardened stack most convincingly looks broken, and WARP is
  the layer that does it: the tunnel carries traffic past the portal, so the
  portal never gets a request to redirect and the login page simply never
  appears. The section tabulates each layer against the reason the portal
  fails, then gives the order that works — `sudo netmaster portal`, log in,
  confirm you are actually online, `sudo netmaster restore` — and states
  plainly that WARP must not come back up until the portal has authorised you.
  A FAQ entry and the MAC randomization section both link to it.
- `SECURITY.md` now covers the drop-in. In scope: the driver guard failing to
  decline, the file being written when `--no-mac-random` was passed or by a
  partial install, a displaced config saved somewhere `conf.d` still parses,
  and `netcheck` reporting MAC privacy the adapter is not actually applying.
  Out of scope: what a randomized MAC does not hide, and captive portals
  breaking, which is documented behaviour rather than a bug.

### Notes

- **NetworkManager is not restarted by the installer.** A restart tears down
  every connection mid-install, and on a machine whose default route belongs to
  a VPN's adopted tunnel that can strand the route table. Randomization takes
  effect on the next reboot, or immediately with
  `sudo systemctl restart NetworkManager`.
- Captive portals will stop working while randomization is on — every reconnect
  looks like a new client. Pin a single network back to the real MAC with
  `nmcli con mod <NAME> 802-11-wireless.cloned-mac-address permanent`.

## [2.4.1] — 2026-08-24

### Fixed

- **`SECURITY.md` claimed "Panoptes has no tagged releases yet".** It had been
  wrong since v1.0.0 — there are eight. The supported-versions table now says
  what is actually true: `main` and the newest tagged release, no backport
  branches, no LTS line. It links the releases page and the changelog instead of
  naming a version that goes stale, and asks reporters for
  `git describe --tags --always --dirty` rather than a bare commit hash.
- `SECURITY.md`'s in-scope list predated the ECH and installer tools. Added the
  four root-level installers (`panoptes-deps.sh`, `warp-setup.sh`,
  `ech-build.sh`, `ech-browsers.sh`) and the fact that `ech-build.sh` puts curl
  in `/usr/local/bin`, ahead of `/usr/bin` on every `PATH` including root's
  `secure_path`. Bugs in the OpenSSL ECH branch itself are called out as
  upstream's, while how Panoptes builds and isolates it stays in scope.

## [2.4.0] — 2026-08-24

### Changed

- **`dns-tray`'s off state is a yellow `C` shield, not a red `AG` one.** The red
  icon said "something is wrong". Nothing is: the toggle never turns DNS off, it
  moves `systemd-resolved` from AdGuard to Cloudflare `1.1.1.2` security, which
  is just as encrypted and DNSSEC-validated. Red is now reserved for
  `warp-tray`, where the tunnel really can be down. The new icon names the
  resolver you are actually on instead of colour-coding it as a fault.
- `dns-tray`'s tooltip and notification named neither resolver, and the off-state
  notification claimed "using default DNS" — which was never true. Both states
  now report the resolver and the address: *AdGuard 94.140.14.14 — ad and
  tracker filtering* / *Cloudflare 1.1.1.2 — malware filtering, no ad blocking*.
- `share/icons/adguard-red.svg` removed; `share/icons/cloudflare-shield.svg`
  added. Nothing loaded the red icon after this change. `install.sh` globs the
  icon directory, so no change was needed there, but a stale `adguard-red.svg`
  left by an earlier install is harmless and can be deleted by hand.

## [2.0.0] — 2026-08-23

Panoptes gains a TLS arm and stops assuming you have already installed its
dependencies.

### Added

- **`ech-build.sh`** — builds an ECH-capable curl and installs it where package
  updates cannot reach it. No distribution ships one, because no released
  OpenSSL implements Encrypted Client Hello. The OpenSSL ECH branch is built
  statically into `/opt/openssl-ech` so nothing else on the system can link a
  development TLS stack, and curl is built against it into `/usr/local`.
  `--verify` performs a live `--ech hard` handshake, which refuses to fall back
  to a cleartext SNI. `--full` restores the features a minimal build omits when
  their libraries are present. `--uninstall` returns curl to the distribution.
- **`ech-browsers.sh`** — detects every browser on the machine across native,
  Flatpak and Snap installs, and enables ECH together with the secure DNS it
  depends on. Firefox-family settings are written to `user.js` so they survive
  a preferences reset; Chromium-family settings go into `Local State`.
  Idempotent, backs up every file it writes, and `--revert` undoes all of it.
- **`panoptes-deps.sh`** — identifies the distribution and package manager and
  installs whatever the suite needs and the machine lacks, across dnf5/dnf/yum,
  apt, pacman, zypper and apk. Requirements are grouped (`core`, `dns`,
  `firewall`, `investigate`, `tray`, `build`) and probed by capability — a
  command in `PATH`, a `pkg-config` module, a Python import or a typelib file —
  rather than by package name.
- `install.sh` gains `--ech-only`, `--deps-only` and `--no-deps`, and resolves
  dependencies before installing anything.

### Notes on behaviour worth knowing about

- `panoptes-deps.sh` identifies the system from `/etc/os-release` `ID` and
  `ID_LIKE`, never by probing for a package-manager binary. A Fedora machine can
  carry `/usr/bin/pacman` — it is the arcade game.
- `ech-browsers.sh` never touches **Tor Browser** or **Mullvad Browser**. Those
  resolve names through their proxy circuit deliberately; configuring a DoH
  resolver would route lookups around it. That is a deanonymisation bug, not
  hardening.
- `ech-browsers.sh` refuses to run under `sudo`. Browser profiles live in a
  person's home directory, and under `sudo` it would find root's empty home and
  configure nothing while appearing to succeed.
- Chromium-family browsers rewrite `Local State` when they exit, so the script
  skips one that is running rather than making an edit that would silently
  vanish.
- Enabling ECH without secure DNS accomplishes nothing — the browser must fetch
  the site's HTTPS DNS record over a protected channel to learn the ECH key, and
  Firefox will not attempt ECH at all with TRR off. Both are set together.

## [2.3.1] — 2026-08-23

### Fixed

- `.github/dependabot.yml` was still the GitHub starter template with an empty
  `package-ecosystem`, which Dependabot rejects — it was watching nothing.
  Filled in with `github-actions`, the only ecosystem that applies: the workflow
  pins `actions/checkout` and `actions/setup-python`, and the repository has no
  package manifests. Bumps are grouped into one pull request rather than one per
  action. The file records why `pip` is absent — `ruff` is installed inline in a
  `run:` step, which Dependabot does not parse — and carries the block to paste
  in if it is ever pinned in a manifest.

## [2.3.0] — 2026-08-23

The suite shipped two tools for controlling WARP and no way to get it. Now it
installs it.

### Added

- **`warp-setup.sh`** — installs and activates Cloudflare WARP. No distribution
  packages it, so this adds Cloudflare's own repository (an RPM repo file with
  `gpgcheck=1`, or an APT list with a dearmoured keyring in
  `/usr/share/keyrings`), installs the client, registers the device and
  connects. Fedora/RHEL and Debian/Ubuntu, which is what Cloudflare publishes
  for; Arch is told to use the AUR build and re-run with `--register`.

  It sets `tunnel_only` mode by default, deliberately. WARP's other modes proxy
  DNS themselves, which fights everything else here — `harden-dns.sh` pins
  DNSSEC and DoT in `systemd-resolved`, `dns-toggle` switches the resolver
  underneath it, and `checkdns` audits the result. `tunnel_only` carries traffic
  and leaves resolution alone, so the two stop arguing. `--mode` overrides it.

  Registration asks first, because it creates a device record on Cloudflare's
  side. `--check` reports state, `--uninstall` removes the client and the
  repository, and it flushes the resolver after connecting for the same reason
  `warp-tray` does.

- **`panoptes-deps.sh` now knows about `warp-cli`**, in a new `warp` group. It
  is the one requirement no distribution ships, so instead of staying silent it
  reports "no distro packages WARP — run: warp-setup.sh".

### Clarified

- README: **AdGuard needs no installation.** It is a public resolver
  (`94.140.14.14` / `94.140.15.15` over DoT), not software — the DNS tools just
  point `systemd-resolved` at it. WARP was the only component that runs a local
  daemon and therefore had to be installed, which is why it was the only gap.

## [2.2.1] — 2026-08-23

### Changed

- README: the ECH caveat about the destination IP said only "your IP address is
  still visible", which is true of ECH standing alone and misleading for anyone
  running a tunnel. It now says what actually happens: behind a VPN the
  destination goes inside the tunnel and out of the ISP's view, but the tunnel
  operator then sees both ends — and with WARP that operator is Cloudflare, who
  is already the far end of most ECH-enabled connections. It also flags
  split-tunnel excludes, which travel outside the tunnel and put the
  destination IP back on the wire, leaving ECH as the only thing still hiding
  the hostname.

## [2.2.0] — 2026-08-23

2.1.0 fixed the resolver-flush in `warp-tray` only. An audit of every path in
the suite that changes WARP state found three more that needed it.

### Fixed

- **`netmaster warp off`, `warp on` and `warp reset` now flush the resolver.**
  Each of `off` and `on` has two branches: one delegating to `warp-killswitch`,
  and a fallback for when the killswitch is not installed. The killswitch
  branches were already covered — `warp-killswitch` restarts
  `systemd-resolved`, which drops both the cache and the learned per-server
  feature grades. The fallback branches, and the whole of `reset`, brought the
  tunnel up or down and left the cache untouched.

### Audited and found already correct

Recorded here so the next person does not re-check them:

- `warp-killswitch down` / `up` — restart `systemd-resolved` directly.
- `netmaster fix` (the S5/S6 ladder) — restarts `systemd-resolved` at S6.
- `dns-toggle` — restarts the resolver and resets server features (2.1.0).
- `checkdns` — read-only.
- `netcheck` — its `resolvectl flush-caches` is unrelated; it provokes a real
  upstream round-trip so the DoT probe is not answered from cache.

## [2.1.0] — 2026-08-23

Toggling WARP off used to leave the resolver answering from a poisoned cache.

### Fixed

- **`warp-tray` now flushes the resolver after any WARP state change.** Tearing
  the tunnel down kills every DNS lookup in flight over it; those fail DNSSEC
  validation with `failed-auxiliary`, because the transport carrying the DS and
  DNSKEY chain vanished mid-lookup, and `systemd-resolved` caches the failure.
  The network is fine immediately afterwards — verified directly: with WARP
  disconnected the `nftables` table, `ip rule` and routing table are all gone,
  the route falls back to the LAN gateway, and both ping and DNS work. Only the
  cache is stale. It reads as "no internet", and it is enough to make Firefox's
  captive-portal probe declare the link down.

  Measured over a teardown with lookups deliberately in flight: **4 of 12
  probes failed without the flush, 0 of 12 with it.** `resolvectl
  reset-server-features` runs too, so resolved re-probes DoT and DNSSEC support
  rather than trusting grades it learned over the old transport. The killswitch
  menu path flushes as well.

- **`dns-toggle` now appends Quad9 to `DNS=`, giving real resolver failover.**
  `FallbackDNS=` never provided this: per `resolved.conf(5)` it is *"only used
  if no other DNS server information is known"* — that is, only when `DNS=` is
  empty. It is not consulted when the servers in `DNS=` stop answering, which is
  exactly what people assume it covers. The trade-off is documented in the
  script: resolved sticks with whichever server last worked, so after a failover
  you stay on Quad9, with malware filtering but no ad blocking, until it
  restarts.

- **The tray icons are now shipped and installed.** Both applets load their
  icons by absolute path from `~/.local/share/icons`, but the repository never
  contained them — a fresh install produced trays with no artwork, which looks
  like a crash. `install.sh` now places all four.

### Changed

- README: a section on the two tray toggles, with an annotated screenshot
  showing each icon in place and both of its states.

## [2.0.1] — 2026-08-23

### Fixed

- `ech-browsers.sh` could not detect a running browser at all. `chromium_running`
  tested `[ -e SingletonLock ]`, but that lock is a symlink to `hostname-pid`,
  which is not a real path — `-e` follows it and always reported false. The
  advertised "will not edit a running Chromium" protection never fired.
- Both detectors now look for an open file descriptor under the profile, which
  is the only evidence that survives sandboxing, and fall back to the lock file
  only for non-sandboxed profiles. A Flatpak or Snap browser records its
  *namespace* pid in the lock; testing that against host pids is meaningless and
  actively wrong — a stale Flatpak lock here named pid 2, and pid 2 is
  `kthreadd`, which is always alive.
- The descriptor scan was itself broken by `pipefail`: `find -print -quit |
  grep -q .` lets grep close the pipe first, so find dies of SIGPIPE with status
  141 and the pipeline reports failure. Replaced with command substitution.
- `ech-browsers.sh` now comments out earlier hand-written copies of the prefs it
  manages, tagged `// PANOPTES-SUPERSEDED`, instead of appending a second
  definition of each. `--revert` restores them, verified byte-for-byte.
- Tor Browser and Mullvad Browser tarball install paths added to the skip table
  so the report names them explicitly. Safety never depended on this — the
  browser table is an allowlist and an unlisted profile is never written — but
  a skip you cannot see is not a skip you can trust.

### Added

- README: a section explaining what ECH is, why SNI is the leak that DNS
  encryption does not close, and — honestly — what ECH does not protect.

## [1.0.0] — 2026-08-22

First public release: fourteen tools assembled from years of one-outage-at-a-time
scripts.

### Added

- DNS auditing and hardening: `audit-dns.sh`, `harden-dns.sh`, `checkdns`,
  `dns-toggle`, `dns-status.sh`, `dns-tray`.
- Monitoring and investigation: `netwatch`, `probesource`, `nettop`, `netcheck`.
- Repair and control: `netmaster`, `wifi-recover.sh`, `warp-killswitch`,
  `warp-tray`.
- `install.sh` / `uninstall.sh`, MIT licence, and CI running shellcheck at
  warning level and ruff's full default ruleset as fatal gates.

[2.5.0]: https://github.com/doug445/Panoptes/releases/tag/v2.5.0
[2.4.1]: https://github.com/doug445/Panoptes/releases/tag/v2.4.1
[2.4.0]: https://github.com/doug445/Panoptes/releases/tag/v2.4.0
[2.3.1]: https://github.com/doug445/Panoptes/releases/tag/v2.3.1
[2.3.0]: https://github.com/doug445/Panoptes/releases/tag/v2.3.0
[2.2.1]: https://github.com/doug445/Panoptes/releases/tag/v2.2.1
[2.2.0]: https://github.com/doug445/Panoptes/releases/tag/v2.2.0
[2.1.0]: https://github.com/doug445/Panoptes/releases/tag/v2.1.0
[2.0.1]: https://github.com/doug445/Panoptes/releases/tag/v2.0.1
[2.0.0]: https://github.com/doug445/Panoptes/releases/tag/v2.0.0
[1.0.0]: https://github.com/doug445/Panoptes/releases/tag/v1.0.0
