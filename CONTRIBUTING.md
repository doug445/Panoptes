# Contributing to Panoptes

Bug reports and patches are welcome. Because these tools rewrite resolver
configuration, firewall state and live network devices on a running machine,
the bar for a useful report is higher than usual: **"DNS broke" is rarely enough
to act on.** The commands below collect what actually is.

Every command block is written to be pasted in one go.

---

## Golden rule for testing

**Never test a writing tool against a machine you need on the network.** There
is no loopback harness here — the surface is a live resolver stack, not a file.
Use a VM, a spare box, or a machine you can walk over to and fix from a console.

Know which half of the suite you are in:

- **Read-only, safe anywhere:** `audit-dns.sh`, `checkdns`, `dns-status.sh`,
  `netcheck`, `nettop`, `probesource`, and `wifi-recover.sh` without `--repair`.
- **Writes:** `harden-dns.sh`, `dns-toggle`, `warp-killswitch`, `netmaster`, and
  `wifi-recover.sh --repair`.

`harden-dns.sh --dry-run` prints the whole plan and changes nothing. Use it
before the real run, every time.

`wifi-recover.sh --reload-modules` reloads drivers. On a patched `wl` that can
take the adapter down until reboot. Do not reach for it on a remote machine.

---

## Reporting a problem

### 1. The diagnostic bundle

Run this and attach the output file. It is read-only — it collects state and
changes nothing:

```bash
OUT="panoptes-diag-$(date +%Y%m%d-%H%M%S).txt" && { \
  echo "=== os ==="; cat /etc/os-release; \
  echo "=== kernel ==="; uname -a; \
  echo "=== panoptes commit ==="; git rev-parse --short HEAD 2>/dev/null || echo "run this from your Panoptes checkout to capture the commit"; \
  echo "=== installed tools ==="; ls -la /usr/local/bin ~/.local/bin 2>/dev/null | grep -E 'audit-dns|checkdns|dns-|harden-dns|netcheck|netmaster|nettop|netwatch|probesource|warp-|wifi-recover'; \
  echo "=== dependencies ==="; for c in bash resolvectl nmcli ip python3 arp-scan whois tcpdump tshark p0f conntrack ipset dig firewall-cmd warp-cli notify-send; do printf '%-14s %s\n' "$c" "$(command -v "$c" || echo MISSING)"; done; \
  echo "=== resolved status ==="; resolvectl status 2>&1; \
  echo "=== resolved.conf ==="; grep -vE '^\s*#|^\s*$' /etc/systemd/resolved.conf 2>/dev/null; \
  echo "=== resolv.conf ==="; ls -la /etc/resolv.conf; lsattr /etc/resolv.conf 2>&1; \
  echo "=== NetworkManager dns backend ==="; grep -rEn '^\s*(dns|rc-manager)\s*=' /etc/NetworkManager/ 2>/dev/null; \
  echo "=== links ==="; ip -br addr; \
  echo "=== routes ==="; ip route; \
  echo "=== firewalld ==="; firewall-cmd --state 2>&1; firewall-cmd --list-all 2>&1; \
  echo "=== nftables tables ==="; sudo nft list tables 2>&1; \
  echo "=== warp ==="; warp-cli --accept-tos status 2>&1; \
  echo "=== netwatch unit ==="; systemctl --user is-active netwatch 2>&1; systemctl is-active netwatch 2>&1; \
} > "$OUT" 2>&1 && echo "wrote $OUT"
```

**Read it before you attach it.** It contains your addresses, routes and Wi-Fi
state. See [`SECURITY.md`](SECURITY.md) for what to redact — the same guidance
applies to ordinary bug reports, not just vulnerabilities.

### 2. Which tool, and exactly what you ran

Paste the full command line including flags, and the output verbatim. "I ran
harden-dns" and "I ran `sudo DNSSEC_MODE=allow-downgrade ./bin/harden-dns.sh`"
are different reports; the second one is actionable.

`harden-dns.sh` takes policy from the environment — `PRIMARY_DNS`,
`FALLBACK_DNS`, `DOMAINS`, `DNSSEC_MODE`, `DOT_MODE`. If you set any of them,
say so. A default-policy bug and an override bug have different causes.

### 3. If DNS is the problem

Attach the audit rather than describing it. Run it as root or the VPN configs
are unreadable and the interesting half is missing:

```bash
sudo ./bin/audit-dns.sh
```

It prints only DNS-related lines out of WireGuard and OpenVPN configs, not the
files themselves, so it will not expose your keys.

### 4. If `probesource` is the problem

Say which tactic, and whether you reached it from the journal, the `netwatch`
log, the `ss` table or by typing an address. The input path matters more than
the tactic — most of the interesting failures are in what got parsed out of a
log, not in the lookup itself.

Do not attach a `pcap`, `tshark` or `p0f` capture without reading it first.

### 5. If the machine lost connectivity

If WARP is involved, get out first and report afterwards:

```bash
sudo warp-killswitch down && warp-killswitch state
```

Then say what `state` printed, and whether DNS came back on `up`.

---

## Reproducing before you report

### Run the CI lint checks

Exactly what `.github/workflows/lint.yml` runs — all three gates — so you find
failures before the PR does:

```bash
fail=0; bash_files=(); py_files=()
for f in bin/* install.sh uninstall.sh; do
  [ -f "$f" ] || continue
  if head -1 "$f" | grep -q bash;   then bash_files+=("$f"); fi
  if head -1 "$f" | grep -q python; then py_files+=("$f"); fi
done
for f in "${bash_files[@]}"; do bash -n "$f" || { echo "SYNTAX FAIL: $f"; fail=1; }; done
shellcheck -S warning "${bash_files[@]}" || fail=1
for f in "${py_files[@]}"; do python3 -B -m py_compile "$f" || fail=1; done
ruff check --isolated --no-cache "${py_files[@]}" || fail=1
for f in bin/* install.sh uninstall.sh; do
  [ -f "$f" ] || continue
  grep -q 'SPDX-License-Identifier: MIT' "$f" || { echo "MISSING LICENSE: $f"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "lint clean — matches CI"
```

The file-selection loops are written as explicit `if/then` accumulators, not
`grep -q X && ...`, for the reason documented at the top of `lint.yml`: the
short form makes a command substitution inherit the exit status of the *last*
iteration, which fails the whole step whenever the alphabetically-last file in
`bin/` is not of the type being selected. Keep the long form.

The block above collects into arrays where `lint.yml` builds a space-joined
string and disables `SC2086` — same files, same gates. Arrays also survive being
pasted into `zsh`, which does not word-split an unquoted `$var`; the string form
selects nothing at all there and reports success.

### Dry-run the writing tools

```bash
sudo ./bin/harden-dns.sh --dry-run
sudo ./install.sh --dry-run
./bin/wifi-recover.sh            # diagnose-only is the default
```

---

## Patches

- **Bash and Python only.** Every bash tool must pass `bash -n` and
  `shellcheck -S warning`; every Python tool must pass `py_compile` and
  `ruff check --isolated` under the **full default ruleset**. CI fails on any
  warning in either.
- **Every tool carries the SPDX MIT header**, immediately after the shebang.
  These scripts get copied onto other machines and pulled out of the repo
  individually, so a bare "see LICENSE" would leave a standalone copy with no
  terms attached. Copy the block verbatim from any existing tool — CI has a
  dedicated `license` job that fails the build if one is missing.
- **Deliberate word splitting carries its reason.** Where a file list expands
  into `tar` arguments or a tactic-id list into `run_set`, the line gets an
  inline `shellcheck disable=SC2046` stating why. Do not quote it into something
  that no longer works, and do not add a blanket disable at the top of a file.
- **Idempotence is a feature, not a side effect.** `harden-dns.sh` re-run in the
  desired state must change nothing and say so. If your patch makes a second run
  rewrite a file, it is not finished.
- **Read-only tools stay read-only.** If you need to write something to answer a
  question, the answer is a new tool or a flag, not a quiet write inside
  `audit-dns.sh`.
- **Restore what you locked.** Anything touching the `chattr +i` immutability
  lock around `resolved.conf` or `resolv.conf` must restore the prior state on
  every exit path, including the failure ones. `dns-toggle` is the reference.
- **Do not hardcode a new resolver.** `dns-toggle` and `dns-status.sh` are
  admittedly hardcoded to one pair, and that is documented. New policy belongs
  in the environment, the way `harden-dns.sh` takes it.
- **Match the surrounding style.** Existing tools use `set -euo pipefail`,
  explicit section banners, and `--dry-run` on anything that writes. Keep that.
- **State what you tested.** Name the distro and whether it was a VM or real
  hardware. If a path is untested, say so in the PR. Documenting an unverified
  failure mode as though you had observed it is worse than documenting nothing.

## Security issues

Do not open a public issue. See [`SECURITY.md`](SECURITY.md).
