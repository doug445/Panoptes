#!/usr/bin/env bash
#
# Panoptes — the all-seeing network watch
# https://github.com/doug445/Panoptes
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Removes the tools install.sh placed. Touches nothing else: no resolver
# settings are reverted, no services are disabled. If you ran harden-dns.sh or
# warp-killswitch, undo those with their own commands first.
#
# Usage:
#   sudo ./uninstall.sh [--dry-run]

set -euo pipefail

SYS_DIR=/usr/local/bin
USER_DIR="${HOME}/.local/bin"
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && \
    USER_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.local/bin"

SYS_TOOLS=(netmaster probesource wifi-recover.sh audit-dns.sh harden-dns.sh warp-killswitch dns-toggle)
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

[ "$removed" -eq 0 ] && echo "Nothing to remove." || echo ""
echo "Resolver settings and services were left untouched."
