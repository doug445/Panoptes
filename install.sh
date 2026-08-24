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
#   sudo ./install.sh --no-mac-random   skip the Wi-Fi MAC randomization drop-in
#
# Unless --no-deps is given, panoptes-deps.sh runs first: it identifies the
# distribution and package manager and offers to install whatever is missing.

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
           panoptes-deps.sh ech-build.sh ech-browsers.sh warp-setup.sh)
USER_TOOLS=(netcheck netwatch nettop checkdns dns-tray dns-status.sh warp-tray)
DNS_SYS=(audit-dns.sh harden-dns.sh dns-toggle)
DNS_USER=(checkdns dns-status.sh dns-tray)
ECH_SYS=(panoptes-deps.sh ech-build.sh ech-browsers.sh)

DRY=0; MODE=all; DEPS=1; MACRAND=1
for a in "$@"; do
    case "$a" in
        --dry-run)   DRY=1 ;;
        --dns-only)  MODE=dns ;;
        --ech-only)  MODE=ech ;;
        --user)      MODE=user ;;
        --no-deps)   DEPS=0 ;;
        --deps-only) MODE=deps ;;
        --no-mac-random) MACRAND=0 ;;
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
    all|user)
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

echo ""
echo "Done. Nothing was enabled as a service."
echo "Start here:  checkdns   |   sudo audit-dns.sh   |   netcheck"
case ":$PATH:" in
    *":$USER_DIR:"*) ;;
    *) echo ""; echo "Note: $USER_DIR is not on your PATH." ;;
esac
