#!/usr/bin/env bash
#
# Panoptes — the all-seeing network watch
# https://github.com/doug445/Panoptes
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Installs the Panoptes tools. System tools go to /usr/local/bin (root needed),
# user tools and tray applets to ~/.local/bin (no root needed).
#
# Usage:
#   sudo ./install.sh              everything
#   sudo ./install.sh --dns-only   only the DNS tools
#   sudo ./install.sh --ech-only   only the ECH tools
#        ./install.sh --user       only the user tools, no root required
#        ./install.sh --dry-run    print what would happen, change nothing
#        ./install.sh --no-deps    skip the package-dependency check
#        ./install.sh --deps-only  only resolve dependencies, install no tools
#        ./install.sh --with-optional  also install the optional requirements
#   sudo ./install.sh --no-mac-random   skip the Wi-Fi MAC randomization drop-in
#   sudo ./install.sh --no-proton       skip installing the Proton VPN client
#   sudo ./install.sh --no-endpoint     skip OpenSnitch, osquery and the persistence watch
#   sudo ./install.sh --no-helpers      skip the kill-switch service and sudoers rules
#
# Unless --no-deps is given, panoptes-deps.sh runs first: it identifies the
# distribution and package manager and offers to install whatever is missing.
# A full install then runs proton-setup.sh, which adds Proton's signed
# repository and installs the Proton VPN app and CLI (the fallback tunnel
# proton-fallback and warp-tray drive). It asks before touching the package
# manager; --no-proton leaves it out. It then runs endpoint-setup.sh, which
# installs OpenSnitch (outbound application firewall) and osquery with the
# persistence pack and watch — the Linux counterpart of the macOS suite's
# objective-see component; --no-endpoint leaves it out.
#
# A full install also wires the privileged helpers the trays depend on: a
# sudoers rule letting the invoking user run dns-toggle without a password, and,
# when Cloudflare WARP is installed, `warp-killswitch install` (watchdog
# service, crash purge, sleep hook, NetworkManager guard, pinned sudoers rule).
# All of it is idempotent; --no-helpers leaves it out.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/bin"
ICON_SRC="$ROOT/share/icons"
NM_SRC="$ROOT/share/nm/mac-randomization.conf"
SYS_DIR=/usr/local/bin
USER_DIR="${HOME}/.local/bin"
ICON_DIR="${HOME}/.local/share/icons"
NM_DIR=/etc/NetworkManager/conf.d

SYS_TOOLS=(netmaster probesource wifi-recover.sh audit-dns.sh harden-dns.sh warp-killswitch dns-toggle
           panoptes-deps.sh ech-build.sh ech-browsers.sh warp-setup.sh proton-setup.sh
           endpoint-setup.sh persistwatch)
USER_TOOLS=(netcheck netwatch nettop checkdns dns-tray dns-status.sh warp-tray proton-fallback persistcheck)
DNS_SYS=(audit-dns.sh harden-dns.sh dns-toggle)
DNS_USER=(checkdns dns-status.sh dns-tray)
ECH_SYS=(panoptes-deps.sh ech-build.sh ech-browsers.sh)

DRY=0; MODE=all; DEPS=1; MACRAND=1; PROTON=1; HELPERS=1; ENDPOINT=1; WITH_OPT=0
for a in "$@"; do
    case "$a" in
        --dry-run)   DRY=1 ;;
        --dns-only)  MODE=dns ;;
        --ech-only)  MODE=ech ;;
        --user)      MODE=user ;;
        --no-deps)   DEPS=0 ;;
        --deps-only) MODE=deps ;;
        --with-optional) WITH_OPT=1 ;;
        --no-mac-random) MACRAND=0 ;;
        --no-proton) PROTON=0 ;;
        --no-endpoint) ENDPOINT=0 ;;
        --no-helpers) HELPERS=0 ;;
        -h|--help)   sed -n '/^# Installs the Panoptes tools/,/^[^#]/p' "$0" \
                         | sed -e '/^[^#]/d' -e 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    dns)  sys=("${DNS_SYS[@]}");  usr=("${DNS_USER[@]}") ;;
    ech)  sys=("${ECH_SYS[@]}");  usr=(checkdns) ;;
    user) sys=();                 usr=("${USER_TOOLS[@]}") ;;
    deps) sys=();                 usr=() ;;
    all)  sys=("${SYS_TOOLS[@]}"); usr=("${USER_TOOLS[@]}") ;;
esac

# Dependencies first: there is no point installing a tool whose commands are
# absent. The bootstrapper detects the distribution itself and asks before
# touching the package manager.
if [ "$DEPS" -eq 1 ] || [ "$MODE" = deps ]; then
    if [ -x "$SRC/panoptes-deps.sh" ]; then
        deps_args=()
        [ "$DRY" -eq 1 ] && deps_args+=(--dry-run)
        [ "$WITH_OPT" -eq 1 ] && deps_args+=(--with-optional)
        case "$MODE" in
            dns)  deps_args+=(--group dns --group core) ;;
            ech)  deps_args+=(--group build --group dns) ;;
            user) deps_args+=(--group core --group tray) ;;
        esac
        "$SRC/panoptes-deps.sh" "${deps_args[@]+"${deps_args[@]}"}" || \
            echo "  (continuing anyway — tools degrade when a command is missing)"
        echo ""
    else
        echo "panoptes-deps.sh not found in bin/; skipping the dependency check" >&2
    fi
fi
[ "$MODE" = deps ] && exit 0

if [ "${#sys[@]}" -gt 0 ] && [ "$(id -u)" -ne 0 ] && [ "$DRY" -eq 0 ]; then
    echo "System tools need root. Re-run with sudo, or use --user for the rest." >&2
    exit 1
fi

# When run under sudo, ~ is root's; install user tools for the invoking user.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    USER_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/bin"
    ICON_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/share/icons"
fi

# Prints "<iface>:<driver>" for the first Wi-Fi adapter whose driver cannot
# associate with a cloned MAC, else returns 1.
#
# The test is the driver, not the vendor. Broadcom's proprietary wl and the
# in-tree b43 / b43legacy / brcmsmac -- Intel Macs, older Broadcom laptops --
# take the MAC from the chip and fail to associate once NetworkManager clones
# it. brcmfmac is deliberately absent: the Apple Silicon parts it drives
# (BCM4377/4387), and the Broadcom SDIO parts on single-board machines, handle
# cloned MACs correctly. So does every non-Broadcom driver.
cloned_mac_blocked_wifi() {
    local d drv
    for d in /sys/class/net/*; do
        [ -e "$d/phy80211" ] || continue
        [ -L "$d/device/driver" ] || continue
        drv="$(readlink -f "$d/device/driver")"; drv="${drv##*/}"
        case "$drv" in
            wl|b43|b43legacy|brcmsmac) echo "${d##*/}:$drv"; return 0 ;;
        esac
    done
    return 1
}

put() {  # $1 = file, $2 = destination dir, $3 = owner spec or empty
    local f=$1 d=$2 own=${3:-}
    if [ ! -f "$SRC/$f" ]; then echo "  missing from bin/: $f" >&2; return 1; fi
    if [ "$DRY" -eq 1 ]; then echo "  would install $f -> $d/$f"; return 0; fi
    install -d "$d"
    install -m 0755 "$SRC/$f" "$d/$f"
    [ -n "$own" ] && chown "$own" "$d/$f"
    echo "  $d/$f"
}

if [ "${#sys[@]}" -gt 0 ]; then
    echo "System tools -> $SYS_DIR"
    for f in "${sys[@]}"; do put "$f" "$SYS_DIR"; done
fi

if [ "${#usr[@]}" -gt 0 ]; then
    echo "User tools -> $USER_DIR"
    own=""
    [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && own="$SUDO_USER:$SUDO_USER"
    [ "$DRY" -eq 0 ] && install -d ${own:+-o "${own%%:*}" -g "${own##*:}"} "$USER_DIR"
    for f in "${usr[@]}"; do put "$f" "$USER_DIR" "$own"; done
fi

# The tray applets load their icons by absolute path from ~/.local/share/icons.
# Without these the trays start but show nothing, which looks like a crash.
case "$MODE" in
    all|user|dns)
        echo "Tray icons -> $ICON_DIR"
        own=""
        [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && own="$SUDO_USER:$SUDO_USER"
        for f in "$ICON_SRC"/*.svg; do
            [ -f "$f" ] || continue
            if [ "$DRY" -eq 1 ]; then
                echo "  would install $(basename "$f") -> $ICON_DIR/"
                continue
            fi
            install -d ${own:+-o "${own%%:*}" -g "${own##*:}"} "$ICON_DIR"
            install -m 0644 ${own:+-o "${own%%:*}" -g "${own##*:}"} "$f" "$ICON_DIR/"
            echo "  $ICON_DIR/$(basename "$f")"
        done ;;
esac

# ── Wi-Fi MAC randomization ──────────────────────────────────────────────
#
# A NetworkManager drop-in, not a tool: it makes the Wi-Fi MAC change per scan
# and per connection so an access point cannot recognize this machine across
# visits. Full install only; skip with --no-mac-random.
#
# NetworkManager is deliberately NOT restarted. A restart tears down every
# connection mid-install, and on a box whose default route belongs to a VPN's
# adopted tunnel that can strand the route table. The drop-in takes effect on
# the next NetworkManager restart or reboot.
#
# Declined outright when a Wi-Fi driver cannot cope with a cloned MAC: wl, b43,
# b43legacy and brcmsmac, as used by Intel Macs and older Broadcom laptops.
# NetworkManager sets the cloned MAC, association fails, and the machine is
# left with no Wi-Fi at all. bin/wifi-recover.sh exists to dig out of precisely
# that hole -- better not to fall in. Apple Silicon Broadcom (brcmfmac,
# BCM4377/4387) is fine and is not skipped.
if [ "$MODE" = all ] && [ "$MACRAND" -eq 1 ]; then
    echo ""
    echo "Wi-Fi MAC randomization -> $NM_DIR/mac-randomization.conf"
    bad=""
    if bad="$(cloned_mac_blocked_wifi)"; then
        echo "  declined: ${bad%%:*} uses the ${bad##*:} driver."
        echo "  MAC randomization is not supported on Broadcom cards in Intel Macs"
        echo "  and older Broadcom laptops -- the card will fail to associate with a"
        echo "  cloned MAC and you will be left with no Wi-Fi. Nothing was written."
        echo "  Override by hand if you know your card is fine:"
        echo "    sudo install -m 0644 share/nm/mac-randomization.conf $NM_DIR/"
    elif [ ! -f "$NM_SRC" ]; then
        echo "  missing from share/nm/: mac-randomization.conf" >&2
    elif [ "$DRY" -eq 1 ]; then
        echo "  would install mac-randomization.conf -> $NM_DIR/"
    elif cmp -s "$NM_SRC" "$NM_DIR/mac-randomization.conf"; then
        echo "  already configured, unchanged"
    else
        install -d "$NM_DIR"
        if [ -f "$NM_DIR/mac-randomization.conf" ]; then
            # Not a .conf suffix: NetworkManager reads only *.conf from conf.d,
            # so the saved copy cannot take effect by accident.
            cp -p "$NM_DIR/mac-randomization.conf" \
                  "$NM_DIR/mac-randomization.conf.pre-panoptes"
            echo "  saved yours -> $NM_DIR/mac-randomization.conf.pre-panoptes"
        fi
        install -m 0644 "$NM_SRC" "$NM_DIR/mac-randomization.conf"
        echo "  $NM_DIR/mac-randomization.conf"
        echo "  NetworkManager was NOT restarted -- that would drop this connection."
        echo "  Active on next reboot, or now with:"
        echo "    sudo systemctl restart NetworkManager"
    fi
fi

# ── Proton VPN client ────────────────────────────────────────────────────
#
# The fallback tunnel. proton-setup.sh adds Proton's repository with the
# signing key pinned by fingerprint, installs the app, the official CLI and
# the AppIndicator pieces the app's tray icon needs, and is idempotent: on a
# machine that already has them it reports "unchanged" and exits. It asks
# before touching the package manager unless the deps step was skipped with
# --no-deps, in which case it is skipped too (same consent model).
if [ "$MODE" = all ] && [ "$PROTON" -eq 1 ] && [ "$DEPS" -eq 1 ]; then
    echo ""
    if [ -x "$SRC/proton-setup.sh" ]; then
        proton_args=()
        [ "$DRY" -eq 1 ] && proton_args+=(--dry-run)
        "$SRC/proton-setup.sh" "${proton_args[@]+"${proton_args[@]}"}" || \
            echo "  (Proton VPN not installed — proton-fallback and the tray's ProtonVPN items stay inert until it is)"
    else
        echo "proton-setup.sh not found in bin/; skipping the Proton VPN client" >&2
    fi
fi

# ── Endpoint: OpenSnitch + osquery persistence pack + persistwatch ───────
#
# The Linux counterpart of the macOS suite's objective-see component. Same
# consent model as the Proton step: asks before the package manager runs,
# skipped with --no-deps. Runs after the tools are in place because it writes
# a unit for /usr/local/bin/persistwatch.
if [ "$MODE" = all ] && [ "$ENDPOINT" -eq 1 ] && [ "$DEPS" -eq 1 ]; then
    echo ""
    if [ -x "$SRC/endpoint-setup.sh" ]; then
        endpoint_args=()
        [ "$DRY" -eq 1 ] && endpoint_args+=(--dry-run)
        "$SRC/endpoint-setup.sh" "${endpoint_args[@]+"${endpoint_args[@]}"}" || \
            echo "  (endpoint component incomplete — persistcheck and persistwatch need osquery; see above)"
    else
        echo "endpoint-setup.sh not found in bin/; skipping the endpoint component" >&2
    fi
fi

# ── Privileged helpers: sudoers for the trays, the kill-switch service ────
if [ "$MODE" = all ] && [ "$HELPERS" -eq 1 ]; then
    echo ""
    echo "Privileged helpers"
    tray_user="${SUDO_USER:-}"; [ "$tray_user" = root ] && tray_user=""
    if [ -n "$tray_user" ]; then
        # dns-toggle takes no arguments, so the rule is already as narrow as it gets.
        rule="$tray_user ALL=(root) NOPASSWD: $SYS_DIR/dns-toggle"
        sudoers_file=/etc/sudoers.d/panoptes-dns-toggle
        if [ "$DRY" -eq 1 ]; then
            echo "  would write $sudoers_file: $rule"
        elif [ -f "$sudoers_file" ] && [ "$(tail -n 1 "$sudoers_file")" = "$rule" ]; then
            echo "  = $sudoers_file (unchanged)"
        else
            tmp=$(mktemp)
            printf '# Installed by Panoptes install.sh: dns-tray flips the resolver without a password.\n%s\n' "$rule" > "$tmp"
            if visudo -cf "$tmp" >/dev/null 2>&1; then
                install -m 0440 "$tmp" "$sudoers_file" && echo "  + $sudoers_file"
            else
                echo "  ! sudoers rule failed visudo -c; not installed" >&2
            fi
            rm -f "$tmp"
        fi
    else
        echo "  (no invoking user known — run with sudo from your account to get the tray sudoers rules)"
    fi
    if command -v warp-cli >/dev/null 2>&1 && [ -x "$SYS_DIR/warp-killswitch" ]; then
        if [ "$DRY" -eq 1 ]; then
            echo "  would run: $SYS_DIR/warp-killswitch install${tray_user:+ --user $tray_user}"
        else
            # shellcheck disable=SC2086
            "$SYS_DIR/warp-killswitch" install ${tray_user:+--user "$tray_user"} | sed 's/^/  /'
        fi
    else
        echo "  Cloudflare WARP is not installed: kill-switch service skipped (warp-setup.sh installs both)"
    fi
fi

echo ""
svc=""
[ "$MODE" = all ] && [ "$HELPERS" -eq 1 ] && command -v warp-cli >/dev/null 2>&1 && svc="warp-watchdog"
[ "$MODE" = all ] && [ "$ENDPOINT" -eq 1 ] && [ "$DEPS" -eq 1 ] && svc="${svc:+$svc, }opensnitch, osqueryd, persistwatch"
if [ -n "$svc" ]; then echo "Done. Services enabled: $svc."
else echo "Done. Nothing was enabled as a service."; fi
echo "Start here:  checkdns   |   sudo audit-dns.sh   |   netcheck"
# Under sudo $PATH is root's secure_path, which says nothing about the invoking
# user's shell; only check when we are actually that user.
if [ -z "${SUDO_USER:-}" ]; then
    case ":$PATH:" in
        *":$USER_DIR:"*) ;;
        *) echo ""; echo "Note: $USER_DIR is not on your PATH." ;;
    esac
fi
