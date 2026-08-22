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
#        ./install.sh --user       only the user tools, no root required
#        ./install.sh --dry-run    print what would happen, change nothing

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin"
SYS_DIR=/usr/local/bin
USER_DIR="${HOME}/.local/bin"

SYS_TOOLS=(netmaster probesource wifi-recover.sh audit-dns.sh harden-dns.sh warp-killswitch dns-toggle)
USER_TOOLS=(netcheck netwatch nettop checkdns dns-tray dns-status.sh warp-tray)
DNS_SYS=(audit-dns.sh harden-dns.sh dns-toggle)
DNS_USER=(checkdns dns-status.sh dns-tray)

DRY=0; MODE=all
for a in "$@"; do
    case "$a" in
        --dry-run)  DRY=1 ;;
        --dns-only) MODE=dns ;;
        --user)     MODE=user ;;
        -h|--help)  sed -n '11,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    dns)  sys=("${DNS_SYS[@]}");  usr=("${DNS_USER[@]}") ;;
    user) sys=();                 usr=("${USER_TOOLS[@]}") ;;
    all)  sys=("${SYS_TOOLS[@]}"); usr=("${USER_TOOLS[@]}") ;;
esac

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
