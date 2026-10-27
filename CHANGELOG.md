# Changelog

All notable changes to Panoptes are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [3.1.1] — 2026-10-27

The 3.1.0 installers meeting Fedora 44, plus the first real run of the
endpoint component.

### Changed

- **Persistence-change notifications no longer make a sound.** `persistwatch`
  sends the freedesktop `suppress-sound` hint and drops the urgency below
  critical, because Cinnamon plays its notification sound whenever
  `!silent || urgency >= Urgency.HIGH` — a critical alert beeps however the
  hint is set. The `resident` hint buys back what critical gave us, so an
  alert still waits to be dismissed instead of expiring. A burst of them is
  now quiet. `PERSISTWATCH_SOUND=1` restores the old critical-with-sound
  behaviour.

### Added

- **`proton-setup.sh --trust-new-key`.** Proton mints a signing key per
  Fedora release, so each new Fedora lands with no pinned fingerprint. That
  case now fetches the release's key over HTTPS, refuses any uid naming a
  *different* release, prints the fingerprint and creation date, and asks
  before importing. `--trust-new-key` accepts it unattended; with no terminal
  and no flag it refuses, so trust is never widened silently.

### Fixed

- **`proton-setup.sh` refused to bootstrap on Fedora 44.** Proton signs each
  Fedora release's repository with its *own* key, and the pinned fingerprint
  was Fedora 43's, so the check correctly refused a legitimate key. The pin is
  now per release (41–44, each read from `repo.protonvpn.com` over a verified
  TLS chain and matched to its `Proton Technologies AG (Fedora NN)
  <opensource@proton.me>` uid). An unlisted release **fails closed** and
  prints the `gpg --show-keys` command to verify the new key by its uid,
  rather than trusting whatever the repository happens to serve.
- **`panoptes-deps.sh` tried to install `wireless-tools` on Fedora**, which
  retired the package — `dnf5` answers `No match for argument`. `iwconfig` is
  now `-` for Fedora: `iw` is already a core requirement, and every
  `iwconfig` call in `wifi-recover.sh` is guarded by `have iwconfig`.
- **`install.sh` advertised `--with-optional` but rejected it.**
  `panoptes-deps.sh` names the flag in its own summary line, yet `install.sh`
  neither accepted it — unknown options hit `exit 1` — nor forwarded it to
  the bootstrapper. It now does both, and `--help` lists it.
- **`proton-setup.sh` reported "signing key not imported" for a key it had
  just imported**, from two independent bugs in one line: rpm now names the
  `gpg-pubkey` package after the key's full 40-hex fingerprint rather than
  the 8-hex short id the script derived, and `rpm -qa … | grep -q` exits
  **141** under `set -o pipefail` because `grep -q` closes the pipe on the
  first match and rpm dies of `SIGPIPE`. The lookup now matches either
  naming scheme and uses no pipe at all.

- **The persistence pack's `startup_items` query listed every systemd unit
  and mount** (728 rows on a laptop): osquery's Linux table folds those in
  under `type = 'systemd unit'`. Restricted to `type = 'Startup Item'` — XDG
  autostart entries and init.d scripts — since units are covered by
  `systemd_units_admin`.
- **`deleted_binaries` flagged every process whose binary had merely been
  upgraded** (`systemd-logind`, Xorg, every gvfs helper after an update). A
  process is listed only when nothing exists at its path any more.
- **`persistwatch` could still raise single alerts during the install-time
  inventory**, because osqueryd delivers that first pass in several batches.
  Rows from a query's first run since osqueryd started (osquery's
  `counter = 0`) are now folded into one "first pass" summary per batch; a
  catch-up after a daemon restart reads the same way. Real changes keep their
  individual alerts; a burst of them is one critical summary.
- `osquery.conf` no longer sets `logger_plugin`/`logger_path`, which are
  CLI-only flags osquery warned about; the suite wanted their defaults.

## [3.1.0] — 2026-10-27

### Added

- **The endpoint component** — the Linux counterpart of Panoptes-macOS's
  `objective-see` component (LuLu, KnockKnock, BlockBlock), on x86_64 and
  aarch64 alike. `endpoint-setup.sh` installs **OpenSnitch**, the outbound
  application firewall, from the distribution on the Debian, Ubuntu and Arch
  families and, on Fedora and openSUSE, which package neither it nor its UI,
  from upstream's GitHub release verified against the maintainer's signed
  `readme.txt` (pinned key `F34016AC…`, SHA-512 per package); seeds *allow*
  rules for the suite's own traffic (`systemd-resolved`, NetworkManager,
  `warp-svc`, and the kill-switch watchdog's pings and portal checks pinned to
  their destinations) so a rebuild never waits on a dialog; and starts the
  prompt UI with the session where the package ships no autostart entry. It
  installs **osquery** from osquery's own repository with the key pinned by
  fingerprint (`1484120A…`; one key for APT, dnf and zypper), ships a
  **persistence pack** (systemd units in admin paths, cron, autostart items,
  kernel modules, `ld.so.preload`, SSH authorized keys, sudoers, setuid
  binaries, exposed listeners with their process, deleted-binary processes,
  hashes of shell/dispatcher/drop-in hook files, accounts), writes
  `osquery.conf` only when none exists and keeps a copy so a hand-edited file
  is left alone, and enables `osqueryd`. Idempotent; `--check`, `--dry-run`,
  `--yes`, `--no-opensnitch`, `--no-osquery`, `--uninstall` (packages stay;
  `--purge` removes them). A full `install.sh` runs it; `--no-endpoint`
  leaves it out; `uninstall.sh` reverses it.
- **`persistcheck`** (KnockKnock): runs the installed pack's queries through
  `osqueryi` — via `sudo -n` when it can — and prints everything with `+`/`-`
  against the snapshot from last time; `--diff`, `--json`, `--baseline`,
  per-query selection. Exit 1 when something changed.
- **`persistwatch`** (BlockBlock): a root service following `osqueryd`'s
  results log, notifying every graphical session of a new pack row; keeps its
  position across restarts and rotation; collapses bursts into one summary;
  `--once`, `--test`, `--from-start`.
- `panoptes-deps.sh` gains an `endpoint` group; the bug-report template lists
  the new tools.

### Changed

- `install.sh` reports exactly which services it enabled.

## [3.0.0] — 2026-10-27

A major version because the tunnel story changed in ways you will notice:
Proton VPN is now a first-class fallback that **parks** WARP rather than
sharing the machine with it, the trays work on every desktop and tell the
truth about what they did, the kill-switch's service pieces finally ship in
the repository, `install.sh` wires the privileged helpers, and a full audit
found and fixed 47 defects — several of which changed the behaviour of
`netmaster`, `ech-build.sh` and `warp-setup.sh` on the distributions the
README has always listed.

### Added

- **Proton VPN as the fallback tunnel, with WARP parked.** `proton-fallback
  on` parks the WARP stack first (`warp-killswitch park`: daemon stopped and
  disabled, DNS untouched, watchdog standing by), connects Proton VPN, waits
  for the tunnel and verifies it; `off` disconnects and rebuilds WARP if the
  tool was the one that parked it. A WARP torn down by you is left down. It
  drives whichever client is present — the official `protonvpn` CLI, a
  NetworkManager profile, a wg-quick config, or the desktop app — and
  `import` turns a WireGuard or OpenVPN file from account.proton.me into a
  NetworkManager profile with autoconnect off and Proton's pushed resolver
  stripped (`--keep-dns` keeps it). Configuration from the environment or
  `~/.config/panoptes/proton.conf`. The same park-before-raise pattern, on the
  same evidence, as Panoptes-macOS.
- **`proton-setup.sh`** installs the official Proton VPN Linux client — the
  desktop app, the official CLI and the AppIndicator pieces its tray icon
  needs — from Proton's own repository with the signing key **pinned by
  fingerprint**. On APT the bootstrap verifies the signed `InRelease`, the
  `Packages` index and the release package hash before `dpkg` runs, then lets
  Proton's own `protonvpn-stable-release` package own the sources file and
  keyring; on Fedora it imports the pinned key and checks the release RPM's
  signature; the Arch family goes through an AUR helper already present
  (`paru`, `yay` or `pamac`, as the invoking user); anything with Flatpak gets
  the Flathub build. Idempotent: every step reports *unchanged* when it is.
  `--check`, `--dry-run`, `--yes`, `--no-tray`, `--no-cli`, `--flatpak`,
  `--uninstall`. A full `install.sh` runs it, after asking; `--no-proton`
  leaves it out.
- **`warp-killswitch park` / `unpark`**, a `parked` marker beside the kill
  marker, `state` printing `parked|killed|armed`, and `status` showing it.
  `heal`, the watchdog and the sleep hooks stand by while parked exactly as
  when killed; a deliberate `down` clears the park marker so the tray can tell
  the two apart.
- **`warp-killswitch install` / `uninstall`.** The watchdog unit, the
  `warp-svc` ExecStopPost crash-purge drop-in, the system-sleep hook, the
  NetworkManager guard that keeps the WARP tun unmanaged, the NetworkManager
  connectivity-check disable, and a sudoers rule pinned to the nine
  invocations `warp-tray` and `proton-fallback` make — all written
  idempotently (byte-compared, `visudo -c`-checked) and all previously
  present only on the maintainer's machines. `warp-setup.sh` runs it after a
  WARP install; `install.sh` runs it on a full install when WARP is present.
- **`install.sh` wires the privileged helpers**: a pinned sudoers rule for
  `dns-toggle` for the invoking user, and the kill-switch service above.
  `--no-helpers` leaves them out. `uninstall.sh` reverses both, and now
  removes the tray icons too.
- **`warp-tray` v4**: a Proton VPN section in the right-click menu (*Connect
  (parks WARP first)* / *Disconnect → rebuild WARP*), two new icon states —
  orange `W` for *parked but Proton VPN not connected*, a yellow circle with a
  black `P` for *Proton VPN connected* — a left-click refused while Proton VPN
  is up or WARP is parked/torn down (with a notification saying why), *Rebuild*
  refused while Proton VPN is up, and *Status* including the Proton VPN state.
- **`panoptes-deps.sh`**: a `proton` group pointing at `proton-setup.sh`;
  `conntrack`, `ipset` and `p0f` for `probesource`; PyQt6 (optional) for the
  KDE trays.
- **Logo tagline** is now *Linux Secure Network*, matching the macOS sibling,
  and is live text rather than outlines.

### Changed

- **warp-killswitch v3.** `down` now removes WARP's v4 and v6 policy rules,
  routes in every table (main included) and every `cloudflare-warp` nft table,
  then proves plain internet works. `up` waits for a verified tunnel and rolls
  back to a clean disconnected state if one never comes. New subcommands:
  `heal`, `watchdog`, `purge`, `status`, `verify`, and `sleep-pre`/`sleep-post`.
  Every `warp-cli` call is time-bounded. A manual `heal` now posts a result
  even when there was nothing to fix.
- **netmaster** recognizes warp-killswitch v3: rung R4 delegates to
  `warp-killswitch purge`, and `status` / `warp` report the watchdog and the
  parked state. `warp off` keeps DNS (`down --keep-dns`); `portal` is the
  command for the DNS downgrade.
- **`ech-build.sh` links curl statically.** No shared `libcurl` is installed
  any more, so nothing else on the machine can pick the development TLS stack
  up through the loader (see Fixed). `--verify` checks for exactly that.
- **`dns-tray` and `warp-tray`** no longer gate on desktop names. The GTK
  branch uses `XApp.StatusIcon` whenever the binding imports (Cinnamon, MATE,
  XFCE on Mint and relatives) and `Gtk.StatusIcon` otherwise, with a themed
  icon when the SVGs are not installed yet. Both reach their helpers with
  `sudo -n`, check the result, and notify on failure with the rule that is
  missing.
- **README** restructured to mirror Panoptes-macOS: tunnel section, tray icon
  and menu tables, *Updating*, *What gets installed where*, *Docs*, *Code of
  conduct*, and the audit report. The bug-report template lists every tool.
- **CI** actions are pinned to commit SHAs.

### Fixed

Found by the 3.0.0 audit unless noted. Severity as the reviewers rated it.

*netmaster*
- `undo --dry-run` executed the undo journal and consumed it (high).
- The undo journal replayed forwards, so `chattr +i` ran before the `cp` it
  was meant to follow and the restore failed with EPERM (high); replayed in
  reverse now.
- `diagnose` flagged and `fix` deleted any bridge with no ports (virbr0,
  docker0) or route-flushed an unplugged physical NIC that showed a
  `linkdown` route (high); physical devices and bridges are skipped.
- "killed AND immutable" was read as the EPERM deadlock, but `down --keep-dns`
  (every watchdog heal, and now `park`) sets the kill marker without swapping
  DNS, so a hardened `resolved.conf` lost its immutable flag and gained a
  relock marker nothing consumed (high); decided on the DNS backup now.
- `restore` never reverted portal mode's profile changes (stable MAC,
  accept-DHCP-DNS) and, without the kill-switch, left DNS plaintext (high);
  profile settings are recorded and restored, and a direct DNS restore path
  exists.
- Output was block-buffered through `sed`, so prompts could sit unseen while
  the tool waited on them (high); line-buffered.
- `panic` dropped the immutable flag without a relock marker, so `restore`
  never put it back (medium-high).
- A `grep -q` under `pipefail` let `ip -6 rule show` die of SIGPIPE and skip
  rung R4 (medium).
- Profile names and SSIDs with spaces broke three detectors and three repairs
  (medium); newline-separated lists.
- `portal` matched the Wi-Fi profile by SSID, which `wl` cards do not report
  (medium); matched by device.
- `panic` hard-coded the `FedoraWorkstation` zone and produced `--zone='no
  zone'` in its undo line (medium); probed, with `home` as the fallback.
- `restore` left `connection.zone` persisted on NM-managed interfaces
  (medium).
- The ladder restarted NetworkManager and reloaded `brcmfmac` for a
  resolver-only failure, on machines without `brcmfmac` (medium).
- `portal` without the kill-switch left DNS-over-TLS on, so the portal stayed
  invisible (medium).
- Colours were computed after stdout became a pipe, so they were always off;
  the watchdog status line printed `inactive` twice (low).

*Tunnel and resolver tools*
- WARP never reconnected after resume: the sleep hook backgrounded the
  reconnect and systemd kills a sleep hook's children when it returns (high);
  delegated to a transient unit.
- `warp-setup.sh` wrote Cloudflare's APT line with the derivative's codename
  (`zena`, `faye`), so the install failed on Mint, Pop!_OS and LMDE (high);
  the base codename is used.
- `warp-setup.sh` registered before `warp-svc` had opened its socket, so a
  fresh install routinely died with "registration failed" (medium); it waits.
- No `warp-cli` call in `warp-setup.sh` was time-bounded (medium); all are.
- `dns-tray` and `warp-tray` announced success before `sudo` had answered,
  with no `-n` and stderr discarded (medium).
- A left-click on `warp-tray` ran `warp-cli connect` against a stopped,
  disabled daemon and said "Connected" (medium).
- The kill-switch's state directory was created with sudo's umask (0750), so
  the tray running as the user could never see the `killed` marker — a torn
  down WARP looked merely "off" unless DNS had been swapped — and would not
  have seen the new `parked` marker either (found while verifying the park
  path on a live tunnel). The directory is 0755 and the markers 0644 now.
- `harden-dns.sh` left `resolved.conf` writable if anything failed, or Ctrl-C
  landed, between unlock and relock (high); relocked on every exit path.
- `dns-tray` and `warp-tray` exited on MATE — and on any desktop other than
  KDE, Cinnamon or (for `warp-tray`) XFCE — with `Unsupported desktop
  environment`, after forking, so an autostart entry silently produced no icon
  (found before the audit).

*Monitoring and investigation*
- `netwatch` raised a false "ARP spoofing" alert on every network change,
  comparing the new gateway against the old network's MAC before noticing the
  SSID had changed, and never compared the gateway address (high).
- `netwatch` spun at 100% CPU if `journalctl` exited (medium); re-opens it.
- `netwatch` triggered a real Wi-Fi scan every ~30 s for the life of the
  daemon (medium); `--rescan no`.
- `netcheck` flushed the resolver cache on every run while documented as
  read-only (high); the flush is gone.
- `netcheck` never showed which process owned a listening port (medium).
- `probesource`'s single-host ARP tactic passed the target to `--destaddr`,
  which is a MAC (medium); the host is a positional target on the routing
  interface.

*ECH, Wi-Fi, dependencies, install*
- `ech-build.sh` installed a shared `libcurl` into `/usr/local/lib`, which the
  Debian family's loader searches first, so git, cmake and pycurl silently
  loaded the minimal ECH build (high); static now.
- `ech-browsers.sh --no-doh` still switched Chromium's resolver to secure DoH
  (high), and `--revert` restored a default rather than the user's previous
  mode and template (medium); the previous values are stashed and restored.
- `panoptes-deps.sh` never found GTK or XApp typelibs on the Debian family
  (multiarch path), so every Mint/Ubuntu install exited 1 after "installing"
  them (high). openSUSE package names for GTK 3 fixed; `libtool-bin` on
  Debian.
- `wifi-recover.sh` wrote logs and a tarball into `/usr/local/bin/logs` on
  every run (high); `--bundle` was a no-op because the condition was always
  true (high); "most recent connection" sorted a human-readable timestamp and
  picked an arbitrary profile (high); `--reload-modules` could load `wl` over
  a `b43` card (medium).
- A `--dns-only` install shipped `dns-tray` without its icons (high);
  `uninstall.sh` left the icons behind (medium); the PATH note fired on every
  sudo install (low).

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

[3.1.1]: https://github.com/doug445/Panoptes/releases/tag/v3.1.1
[3.1.0]: https://github.com/doug445/Panoptes/releases/tag/v3.1.0
[3.0.0]: https://github.com/doug445/Panoptes/releases/tag/v3.0.0
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
