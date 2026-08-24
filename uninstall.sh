#!/usr/bin/env bash
#
# Panoptes — the all-seeing network watch
# https://github.com/doug445/Panoptes
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Removes the tools install.sh placed, and the MAC randomization drop-in if it
# is still the one we shipped. Touches nothing else: no resolver settings are
# reverted, no services are disabled. If you ran harden-dns.sh or
# warp-killswitch, undo those with their own commands first.
#
# Usage:
#   sudo ./uninstall.sh [--dry-run]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NM_SRC="$ROOT/share/nm/mac-randomization.conf"
NM_CONF=/etc/NetworkManager/conf.d/mac-randomization.conf
SYS_DIR=/usr/local/bin
USER_DIR="${HOME}/.local/bin"
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && \
    USER_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/bin"

SYS_TOOLS=(netmaster probesource wifi-recover.sh audit-dns.sh harden-dns.sh warp-killswitch dns-toggle
           panoptes-deps.sh ech-build.sh ech-browsers.sh warp-setup.sh)
USER_TOOLS=(netcheck netwatch nettop checkdns dns-tray dns-status.sh warp-tray)

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

removed=0
for f in "${SYS_TOOLS[@]}"; do
    [ -e "$SYS_DIR/$f" ] || continue
    if [ "$DRY" -eq 1 ]; then echo "  would remove $SYS_DIR/$f"
    else rm -f "$SYS_DIR/$f"; echo "  removed $SYS_DIR/$f"; fi
    removed=$((removed + 1))
done
for f in "${USER_TOOLS[@]}"; do
    [ -e "$USER_DIR/$f" ] || continue
    if [ "$DRY" -eq 1 ]; then echo "  would remove $USER_DIR/$f"
    else rm -f "$USER_DIR/$f"; echo "  removed $USER_DIR/$f"; fi
    removed=$((removed + 1))
done

# The MAC randomization drop-in. Removed only when it is byte-for-byte the file
# we shipped -- if it has been edited, or predates Panoptes, it is somebody
# else's config and we leave it alone and say so. A copy install.sh displaced
# is put back.
if [ -f "$NM_CONF" ]; then
    if [ -f "$NM_SRC" ] && cmp -s "$NM_SRC" "$NM_CONF"; then
        if [ "$DRY" -eq 1 ]; then
            echo "  would remove $NM_CONF"
            if [ -f "$NM_CONF.pre-panoptes" ]; then
                echo "  would restore $NM_CONF.pre-panoptes -> $NM_CONF"
            fi
        elif [ -f "$NM_CONF.pre-panoptes" ]; then
            mv -f "$NM_CONF.pre-panoptes" "$NM_CONF"
            echo "  restored $NM_CONF from .pre-panoptes"
        else
            rm -f "$NM_CONF"
            echo "  removed $NM_CONF"
        fi
        removed=$((removed + 1))
    else
        echo "  left $NM_CONF alone -- it is not the file Panoptes ships"
    fi
fi

[ "$removed" -eq 0 ] && echo "Nothing to remove." || echo ""
echo "Resolver settings and services were left untouched."
echo "NetworkManager was not restarted; any MAC change reverts on next restart."
