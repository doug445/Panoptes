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
#
# Unless --no-deps is given, panoptes-deps.sh runs first: it identifies the
# distribution and package manager and offers to install whatever is missing.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin"
SYS_DIR=/usr/local/bin
USER_DIR="${HOME}/.local/bin"

SYS_TOOLS=(netmaster probesource wifi-recover.sh audit-dns.sh harden-dns.sh warp-killswitch dns-toggle
           panoptes-deps.sh ech-build.sh ech-browsers.sh)
USER_TOOLS=(netcheck netwatch nettop checkdns dns-tray dns-status.sh warp-tray)
DNS_SYS=(audit-dns.sh harden-dns.sh dns-toggle)
DNS_USER=(checkdns dns-status.sh dns-tray)
ECH_SYS=(panoptes-deps.sh ech-build.sh ech-browsers.sh)

DRY=0; MODE=all; DEPS=1
for a in "$@"; do
    case "$a" in
        --dry-run)   DRY=1 ;;
        --dns-only)  MODE=dns ;;
        --ech-only)  MODE=ech ;;
        --user)      MODE=user ;;
        --no-deps)   DEPS=0 ;;
        --deps-only) MODE=deps ;;
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
fi

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

echo ""
echo "Done. Nothing was enabled as a service."
echo "Start here:  checkdns   |   sudo audit-dns.sh   |   netcheck"
case ":$PATH:" in
    *":$USER_DIR:"*) ;;
    *) echo ""; echo "Note: $USER_DIR is not on your PATH." ;;
esac
