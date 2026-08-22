#!/usr/bin/env bash
#
# Panoptes — the all-seeing network watch
# https://github.com/doug445/Panoptes
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# harden-dns.sh — defense-in-depth DNS hardening for NetworkManager + systemd-resolved.
# Idempotent: re-runs do nothing if everything is already in the desired state.
# Targets: Linux Mint, Fedora, Fedora Asahi, Manjaro (anything using NM + resolved).
#
# Usage:
#   sudo ./harden-dns.sh [--dry-run] [--no-lock] [--skip-nm] [--skip-resolved]
#
# Override policy via env: PRIMARY_DNS, FALLBACK_DNS, DOMAINS, DNSSEC_MODE, DOT_MODE.

set -euo pipefail
LC_ALL=C

PRIMARY_DNS="${PRIMARY_DNS:-94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com}"
FALLBACK_DNS="${FALLBACK_DNS:-9.9.9.9#dns.quad9.net 1.1.1.1#cloudflare-dns.com}"
DOMAINS="${DOMAINS:-~.}"
DNSSEC_MODE="${DNSSEC_MODE:-yes}"
DOT_MODE="${DOT_MODE:-yes}"

DO_LOCK=1; DRY_RUN=0; SKIP_RESOLVED=0; SKIP_NM=0
for arg in "$@"; do
  case "$arg" in
    --no-lock)       DO_LOCK=0 ;;
    --dry-run|-n)    DRY_RUN=1 ;;
    --skip-nm)       SKIP_NM=1 ;;
    --skip-resolved) SKIP_RESOLVED=1 ;;
    -h|--help) sed -n '/^# harden-dns\.sh —/,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  ✓ %s\n' "$*"; }
say() { printf '  • %s\n' "$*"; }
warn(){ printf '  ! %s\n' "$*" >&2; }
do_or_say(){ if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] || { warn "must run as root (use sudo)"; exit 1; }

# 1. NetworkManager hardening -------------------------------------------------
if [ "$SKIP_NM" -eq 0 ]; then
  bold "NetworkManager"
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    DROPIN=/etc/NetworkManager/conf.d/00-resolved-dns.conf
    desired=$(mktemp)
    cat > "$desired" <<'EOF'
# Managed by harden-dns.sh: route DNS through systemd-resolved and
# ignore DHCP-pushed DNS for newly created connections.
[main]
dns=systemd-resolved
systemd-resolved=true
rc-manager=symlink

[connection]
ipv4.ignore-auto-dns=true
ipv6.ignore-auto-dns=true
EOF
    if [ -f "$DROPIN" ] && cmp -s "$desired" "$DROPIN"; then
      ok "drop-in already in desired state: $DROPIN"
    else
      say "writing $DROPIN"
      [ -f "$DROPIN" ] && do_or_say cp -a "$DROPIN" "$DROPIN.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      do_or_say install -m 0644 "$desired" "$DROPIN"
      do_or_say nmcli general reload conf
    fi
    rm -f "$desired"

    say "retrofitting per-connection ignore-auto-dns:"
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      name=$(nmcli -g connection.id connection show "$u" 2>/dev/null)
      [ -z "$name" ] && name="$u"
      v4=$(nmcli -g ipv4.ignore-auto-dns connection show "$u" 2>/dev/null | tr '\n' ',' | sed 's/,*$//;s/,,*/,/g')
      v6=$(nmcli -g ipv6.ignore-auto-dns connection show "$u" 2>/dev/null | tr '\n' ',' | sed 's/,*$//;s/,,*/,/g')
      if [ "$v4" = "yes" ] && [ "$v6" = "yes" ]; then
        ok "  $name: already yes/yes"
      else
        do_or_say nmcli connection modify "$u" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
        [ "$DRY_RUN" -eq 0 ] && say "  $name: set yes/yes (was v4=$v4 v6=$v6)"
      fi
    done < <(nmcli -t -f UUID connection show)
  else
    warn "NetworkManager not active — skipping NM hardening"
  fi
fi

# 2. systemd-resolved + lock --------------------------------------------------
if [ "$SKIP_RESOLVED" -eq 0 ]; then
  bold "systemd-resolved"
  CONF=/etc/systemd/resolved.conf
  if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved not active — skipping resolved.conf changes"
  elif [ ! -e "$CONF" ]; then
    warn "$CONF does not exist — skipping"
  else
    desired=$(mktemp)
    cat > "$desired" <<EOF
[Resolve]
DNS=$PRIMARY_DNS
FallbackDNS=$FALLBACK_DNS
Domains=$DOMAINS
DNSSEC=$DNSSEC_MODE
DNSOverTLS=$DOT_MODE
MulticastDNS=no
LLMNR=no
EOF
    was_immutable=0
    if lsattr "$CONF" 2>/dev/null | awk '{print $1}' | grep -q i; then was_immutable=1; fi

    if cmp -s "$desired" "$CONF"; then
      ok "resolved.conf already in desired state"
    else
      say "updating $CONF"
      [ "$was_immutable" -eq 1 ] && do_or_say chattr -i "$CONF"
      do_or_say cp -a "$CONF" "$CONF.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      do_or_say install -m 0644 "$desired" "$CONF"
      do_or_say systemctl restart systemd-resolved
    fi
    rm -f "$desired"

    if [ "$DO_LOCK" -eq 1 ]; then
      if lsattr "$CONF" 2>/dev/null | awk '{print $1}' | grep -q i; then
        ok "immutable bit already set"
      else
        do_or_say chattr +i "$CONF"
      fi
    elif [ "$was_immutable" -eq 1 ]; then
      say "re-applying immutable bit (use chattr -i manually to fully unlock)"
      do_or_say chattr +i "$CONF"
    fi
  fi
fi

bold "done"
