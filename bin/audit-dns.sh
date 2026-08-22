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
# DNS audit — distro-agnostic snapshot for Fedora / Fedora Asahi / Mint / Manjaro.
# Read-only: prints what controls DNS on this box and where pushed-DNS could leak in.
# Run as root for full visibility (WireGuard/OpenVPN configs are usually 600).

set -u
LC_ALL=C

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
hr()   { printf -- '----------------------------------------\n'; }
have() { command -v "$1" >/dev/null 2>&1; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

# --- 0. host / distro -----------------------------------------------------
bold "host"
note "$(uname -n) — $(uname -srm)"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  note "${PRETTY_NAME:-$NAME $VERSION_ID} (id=${ID:-?}${ID_LIKE:+, like=$ID_LIKE})"
fi
[ "$(id -u)" -eq 0 ] || warn "not root — VPN configs in /etc/wireguard, /etc/openvpn/* may be unreadable"
hr

# --- 1. resolver in use ---------------------------------------------------
bold "resolver"
resolver="unknown"
if have systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  resolver="systemd-resolved"
fi
for svc in dnsmasq unbound bind9 named pdns-recursor; do
  if have systemctl && systemctl is-active --quiet "$svc" 2>/dev/null; then
    resolver="${resolver}+${svc}"
  fi
done
note "active: $resolver"

if [ -L /etc/resolv.conf ]; then
  note "/etc/resolv.conf -> $(readlink -f /etc/resolv.conf)"
elif [ -e /etc/resolv.conf ]; then
  note "/etc/resolv.conf is a regular file (managed manually or by resolvconf/openresolv)"
fi
note "nameservers in /etc/resolv.conf:"
grep -E '^\s*nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/    /' || true
hr

# --- 2. upstream DNS (what's actually being queried) ----------------------
bold "upstream DNS"
if have resolvectl; then
  resolvectl status 2>/dev/null | grep -E 'Current DNS Server|DNS Servers|Fallback DNS|DNSOverTLS|DNSSEC|resolv.conf mode' | sed 's/^/  /'
else
  note "resolvectl not available — see /etc/resolv.conf above"
fi
hr

# --- 3. NetworkManager: is DHCP-pushed DNS being honored? -----------------
bold "NetworkManager DNS handling"
if have nmcli && systemctl is-active --quiet NetworkManager 2>/dev/null; then
  note "NM is active"
  # Global / drop-in config
  for f in /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE '^\s*(dns|systemd-resolved|rc-manager|ipv[46]\.ignore-auto-dns)\s*=' "$f" 2>/dev/null; then
      note "  $f:"
      grep -E '^\s*(dns|systemd-resolved|rc-manager|ipv[46]\.ignore-auto-dns)\s*=' "$f" | sed 's/^/      /'
    fi
  done
  # Per-connection ignore-auto-dns
  if nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -qv '^$'; then
    note "  per-connection ipv4.ignore-auto-dns / ipv6.ignore-auto-dns:"
    while IFS=: read -r name _; do
      [ -z "$name" ] && continue
      # nmcli can return multiple lines for profiles with several address blocks; normalize.
      v4=$(nmcli -g ipv4.ignore-auto-dns connection show "$name" 2>/dev/null | tr '\n' ',' | sed 's/,*$//;s/,,*/,/g')
      v6=$(nmcli -g ipv6.ignore-auto-dns connection show "$name" 2>/dev/null | tr '\n' ',' | sed 's/,*$//;s/,,*/,/g')
      printf '      %-30s v4=%-12s v6=%s\n' "$name" "${v4:-?}" "${v6:-?}"
    done < <(nmcli -t -f NAME,TYPE connection show)
  fi
else
  note "NetworkManager not active"
fi
hr

# --- 4. systemd-networkd ---------------------------------------------------
bold "systemd-networkd DNS handling"
if have systemctl && systemctl is-active --quiet systemd-networkd 2>/dev/null; then
  note "networkd is active"
  for f in /etc/systemd/network/*.network /run/systemd/network/*.network; do
    [ -f "$f" ] || continue
    if grep -qE '^\s*(UseDNS|DNS)\s*=' "$f" 2>/dev/null; then
      note "  $f:"
      grep -E '^\s*(UseDNS|DNS)\s*=' "$f" | sed 's/^/      /'
    fi
  done
else
  note "systemd-networkd not active"
fi
hr

# --- 5. dhclient -----------------------------------------------------------
bold "dhclient (ISC) DNS handling"
if have dhclient || [ -e /etc/dhcp/dhclient.conf ] || \
   ( for _f in /etc/dhcp/dhclient.d/*.sh; do [ -e "$_f" ] && exit 0; done; exit 1 ); then
  any_override=0
  for f in /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.d/*.sh; do
    [ -f "$f" ] || continue
    # Only match active (non-comment) supersede/prepend directives that touch DNS.
    matches=$(grep -nE '^\s*(supersede|prepend)\s+(domain-name-servers|domain-search|domain-name)\b' "$f" 2>/dev/null || true)
    if [ -n "$matches" ]; then
      any_override=1
      note "  $f:"
      printf '%s\n' "$matches" | sed 's/^/      /'
    fi
  done
  if [ "$any_override" -eq 0 ]; then
    warn "no active supersede/prepend for domain-name-servers — dhclient (if invoked) will accept pushed DNS"
  fi
else
  note "no dhclient files present"
fi
hr

# --- 6. systemd-resolved upstream config + lock ---------------------------
bold "/etc/systemd/resolved.conf"
if [ -e /etc/systemd/resolved.conf ]; then
  attrs=$(lsattr /etc/systemd/resolved.conf 2>/dev/null | awk '{print $1}')
  if echo "$attrs" | grep -q i; then
    ok "immutable bit set ($attrs)"
  else
    warn "no immutable bit ($attrs) — file is freely writable by root"
  fi
  note "active settings:"
  grep -E '^\s*(DNS|FallbackDNS|Domains|DNSOverTLS|DNSSEC)\s*=' /etc/systemd/resolved.conf | sed 's/^/    /'
  for d in /etc/systemd/resolved.conf.d/*.conf /run/systemd/resolved.conf.d/*.conf; do
    [ -f "$d" ] || continue
    note "drop-in $d:"
    grep -E '^\s*[A-Z]' "$d" | sed 's/^/    /'
  done
else
  note "no /etc/systemd/resolved.conf (systemd-resolved likely not installed)"
fi
hr

# --- 7. VPN clients that can push DNS -------------------------------------
bold "VPN clients (potential DNS pushers)"

# OpenVPN
if [ -d /etc/openvpn ]; then
  note "OpenVPN configs under /etc/openvpn:"
  found=0
  while IFS= read -r f; do
    found=1
    pulldns=$(grep -nE '^\s*(up|down)\s+.*update-(systemd-)?resolv|^\s*pull-filter|^\s*dhcp-option\s+DNS' "$f" 2>/dev/null || true)
    if [ -n "$pulldns" ]; then
      note "  $f:"
      printf '%s\n' "$pulldns" | sed 's/^/      /'
    else
      note "  $f: no DNS-related directives found"
    fi
  done < <(find /etc/openvpn -maxdepth 3 -type f \( -name '*.conf' -o -name '*.ovpn' \) 2>/dev/null)
  [ "$found" -eq 0 ] && note "  (no .conf or .ovpn files)"
  for u in $(systemctl list-units --no-legend --plain --type=service 2>/dev/null | awk '/openvpn/{print $1}'); do
    state=$(systemctl is-active "$u" 2>/dev/null)
    note "  unit $u: $state"
  done
fi

# WireGuard
if [ -d /etc/wireguard ] || have wg; then
  note "WireGuard:"
  if [ -d /etc/wireguard ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      dns=$(grep -nE '^\s*(DNS|PostUp|PreUp|PostDown|PreDown)\s*=' "$f" 2>/dev/null || true)
      if [ -n "$dns" ]; then
        note "  $f:"
        printf '%s\n' "$dns" | sed 's/^/      /'
      fi
    done < <(find /etc/wireguard -maxdepth 2 -type f -name '*.conf' 2>/dev/null)
  fi
  if have wg && [ "$(id -u)" -eq 0 ]; then
    active=$(wg show interfaces 2>/dev/null)
    [ -n "$active" ] && note "  active interfaces: $active"
  fi
fi

# Tailscale, Mullvad
for svc in tailscaled mullvad-daemon; do
  if have systemctl && systemctl is-active --quiet "$svc" 2>/dev/null; then
    note "$svc is active (manages its own DNS path)"
  fi
done
hr

# --- 8. recent writes to DNS-relevant files (sanity) ----------------------
bold "recent mtimes on DNS-relevant files"
for f in /etc/resolv.conf /etc/systemd/resolved.conf /etc/nsswitch.conf /etc/dhcp/dhclient.conf; do
  [ -e "$f" ] && stat -c '  %y  %N' "$f"
done
hr

bold "done"
