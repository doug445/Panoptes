# Changelog

All notable changes to Panoptes are recorded here.
This project follows [Semantic Versioning](https://semver.org/).

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

[2.0.0]: https://github.com/doug445/Panoptes/releases/tag/v2.0.0
[1.0.0]: https://github.com/doug445/Panoptes/releases/tag/v1.0.0
