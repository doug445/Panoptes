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
# panoptes-deps.sh — identify the distribution and package manager, then install
# everything the Panoptes tools need and this machine is missing.
#
# Detection is by /etc/os-release ID and ID_LIKE, never by "which binary exists".
# (A Fedora box can ship /usr/bin/pacman — it is the arcade game, not the Arch
# package manager. Probing for binaries would happily reformat your assumptions.)
#
# Usage:
#   sudo ./panoptes-deps.sh                install everything missing, after asking
#   sudo ./panoptes-deps.sh --yes          same, no confirmation
#        ./panoptes-deps.sh --check        report only, change nothing, exit 1 if short
#        ./panoptes-deps.sh --print        print the install command and exit
#   sudo ./panoptes-deps.sh --group build  only one group (repeatable)
#        ./panoptes-deps.sh --list         show the full requirement table
#        ./panoptes-deps.sh --dry-run      resolve and report, run no package manager
#
# Groups: core dns firewall investigate tray build warp
# Optional requirements are skipped unless --with-optional is given.

set -uo pipefail
LC_ALL=C

usage() { sed -n '/^# panoptes-deps\.sh —/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \?//'; }

# ---------------------------------------------------------------- requirements
#
# id | probe | group | optional | fedora | debian | arch | suse | alpine
#
# probe:  cmd:NAME       the command must be in PATH
#         pc:NAME        pkg-config must resolve NAME (development headers)
#         py:MODULE      python3 must import MODULE
#         file:PATH      PATH must exist
#
# "-" means the distribution does not package it under any name we know.
#
REQUIREMENTS=$(cat <<'TABLE'
ip|cmd:ip|core|no|iproute|iproute2|iproute2|iproute2|iproute2
ss|cmd:ss|core|no|iproute|iproute2|iproute2|iproute2|iproute2
nmcli|cmd:nmcli|core|no|NetworkManager|network-manager|networkmanager|NetworkManager|networkmanager
dig|cmd:dig|dns|no|bind-utils|bind9-dnsutils|bind|bind-utils|bind-tools
host|cmd:host|dns|no|bind-utils|bind9-host|bind|bind-utils|bind-tools
resolvectl|cmd:resolvectl|dns|no|systemd-resolved|systemd-resolved|systemd-resolvconf|systemd-network|-
curl|cmd:curl|core|no|curl|curl|curl|curl|curl
whois|cmd:whois|core|no|whois|whois|whois|whois|whois
awk|cmd:awk|core|no|gawk|gawk|gawk|gawk|gawk
iw|cmd:iw|core|no|iw|iw|iw|iw|iw
iwconfig|cmd:iwconfig|core|yes|wireless-tools|wireless-tools|wireless_tools|wireless-tools|wireless-tools
ping|cmd:ping|core|no|iputils|iputils-ping|iputils|iputils|iputils
arping|cmd:arping|core|no|iputils|iputils-arping|iputils|iputils|iputils
arp-scan|cmd:arp-scan|core|no|arp-scan|arp-scan|arp-scan|arp-scan|arp-scan
rfkill|cmd:rfkill|core|no|util-linux|rfkill|util-linux|util-linux|util-linux
lspci|cmd:lspci|core|no|pciutils|pciutils|pciutils|pciutils|pciutils
nft|cmd:nft|firewall|no|nftables|nftables|nftables|nftables|nftables
firewall-cmd|cmd:firewall-cmd|firewall|yes|firewalld|firewalld|firewalld|firewalld|-
nmap|cmd:nmap|investigate|no|nmap|nmap|nmap|nmap|nmap
tcpdump|cmd:tcpdump|investigate|no|tcpdump|tcpdump|tcpdump|tcpdump|tcpdump
tshark|cmd:tshark|investigate|yes|wireshark-cli|tshark|wireshark-cli|wireshark|tshark
mtr|cmd:mtr|investigate|no|mtr|mtr-tiny|mtr|mtr|mtr
traceroute|cmd:traceroute|investigate|no|traceroute|traceroute|traceroute|traceroute|-
dialog|cmd:dialog|investigate|no|dialog|dialog|dialog|dialog|dialog
whiptail|cmd:whiptail|investigate|yes|newt|whiptail|libnewt|newt|newt
geoiplookup|cmd:geoiplookup|investigate|yes|-|geoip-bin|-|-|-
python3|cmd:python3|tray|no|python3|python3|python|python3|python3
pygobject|py:gi|tray|no|python3-gobject|python3-gi|python-gobject|python3-gobject|py3-gobject3
gtk3|file:/usr/lib64/girepository-1.0/Gtk-3.0.typelib|tray|no|gtk3|gir1.2-gtk-3.0|gtk3|gtk3|gtk+3.0
xapp|file:/usr/lib64/girepository-1.0/XApp-1.0.typelib|tray|yes|xapps|gir1.2-xapp-1.0|xapp|-|-
notify-send|cmd:notify-send|tray|no|libnotify|libnotify-bin|libnotify|libnotify-tools|libnotify
git|cmd:git|build|no|git|git|git|git|git
gcc|cmd:gcc|build|no|gcc|build-essential|base-devel|gcc|build-base
make|cmd:make|build|no|make|make|make|make|make
perl|cmd:perl|build|no|perl-core|perl|perl|perl|perl
autoconf|cmd:autoconf|build|no|autoconf|autoconf|autoconf|autoconf|autoconf
automake|cmd:automake|build|no|automake|automake|automake|automake|automake
libtool|cmd:libtool|build|no|libtool|libtool|libtool|libtool|libtool
pkg-config|cmd:pkg-config|build|no|pkgconf-pkg-config|pkg-config|pkgconf|pkg-config|pkgconf
zlib-dev|pc:zlib|build|no|zlib-devel|zlib1g-dev|zlib|zlib-devel|zlib-dev
nghttp2-dev|pc:libnghttp2|build|no|libnghttp2-devel|libnghttp2-dev|libnghttp2|libnghttp2-devel|nghttp2-dev
idn2-dev|pc:libidn2|build|no|libidn2-devel|libidn2-dev|libidn2|libidn2-devel|libidn2-dev
psl-dev|pc:libpsl|build|no|libpsl-devel|libpsl-dev|libpsl|libpsl-devel|libpsl-dev
warp-cli|cmd:warp-cli|warp|yes|-|-|-|-|-
TABLE
)

ALL_GROUPS="core dns firewall investigate tray build warp"

# ------------------------------------------------------------------- arguments
CHECK_ONLY=0; ASSUME_YES=0; DRY=0; PRINT_ONLY=0; LIST=0; WITH_OPTIONAL=0
WANT_GROUPS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check)          CHECK_ONLY=1 ;;
        -y|--yes)         ASSUME_YES=1 ;;
        --dry-run)        DRY=1 ;;
        --print)          PRINT_ONLY=1 ;;
        --list)           LIST=1 ;;
        --with-optional)  WITH_OPTIONAL=1 ;;
        --group)
            shift
            [ $# -gt 0 ] || { echo "--group needs a name" >&2; exit 2; }
            case " $ALL_GROUPS " in
                *" $1 "*) WANT_GROUPS="$WANT_GROUPS $1" ;;
                *) echo "unknown group: $1 (have: $ALL_GROUPS)" >&2; exit 2 ;;
            esac ;;
        --group=*)
            g=${1#--group=}
            case " $ALL_GROUPS " in
                *" $g "*) WANT_GROUPS="$WANT_GROUPS $g" ;;
                *) echo "unknown group: $g (have: $ALL_GROUPS)" >&2; exit 2 ;;
            esac ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "panoptes-deps.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$WANT_GROUPS" ] || WANT_GROUPS="$ALL_GROUPS"

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[0;33m'; D=$'\e[0;90m'; N=$'\e[0m'
else B=; R=; G=; Y=; D=; N=; fi

# ------------------------------------------------------------------- detection
FAMILY=unknown; DISTRO_PRETTY=unknown; DISTRO_ID=unknown
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
    for candidate in "${ID:-}" ${ID_LIKE:-}; do
        case "$candidate" in
            fedora|rhel|centos|rocky|almalinux) FAMILY=fedora; break ;;
            debian|ubuntu|linuxmint|pop|raspbian) FAMILY=debian; break ;;
            arch|archlinux|manjaro|endeavouros) FAMILY=arch; break ;;
            opensuse|opensuse-leap|opensuse-tumbleweed|suse|sles) FAMILY=suse; break ;;
            alpine) FAMILY=alpine; break ;;
        esac
    done
fi

# The package manager follows from the family. We only ask the filesystem to
# confirm the binary we already expect — we never let a stray binary pick it.
PM=""; PM_INSTALL=""; PM_REFRESH=""; COLUMN=0
case "$FAMILY" in
    fedora)
        if command -v dnf5 >/dev/null 2>&1; then PM=dnf5
        elif command -v dnf >/dev/null 2>&1; then PM=dnf
        elif command -v yum >/dev/null 2>&1; then PM=yum; fi
        PM_INSTALL="$PM install -y"; COLUMN=5 ;;
    debian)
        command -v apt-get >/dev/null 2>&1 && PM=apt-get
        PM_INSTALL="apt-get install -y --no-install-recommends"
        PM_REFRESH="apt-get update"; COLUMN=6 ;;
    arch)
        command -v pacman >/dev/null 2>&1 && PM=pacman
        PM_INSTALL="pacman -S --needed --noconfirm"; COLUMN=7 ;;
    suse)
        command -v zypper >/dev/null 2>&1 && PM=zypper
        PM_INSTALL="zypper --non-interactive install"; COLUMN=8 ;;
    alpine)
        command -v apk >/dev/null 2>&1 && PM=apk
        PM_INSTALL="apk add"; COLUMN=9 ;;
esac

printf '%sSystem%s\n' "$B" "$N"
printf '  %-14s %s\n' "distribution" "$DISTRO_PRETTY ${D}(id=$DISTRO_ID)${N}"
printf '  %-14s %s\n' "family" "$FAMILY"
if [ -n "$PM" ]; then
    printf '  %-14s %s\n' "package mgr" "$PM"
else
    printf '  %-14s %s\n' "package mgr" "${Y}none recognised${N}"
fi
echo

# -------------------------------------------------------------------- probing
have() {  # $1 = probe spec
    case "$1" in
        cmd:*)  command -v "${1#cmd:}" >/dev/null 2>&1 ;;
        pc:*)   command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "${1#pc:}" ;;
        py:*)   command -v python3 >/dev/null 2>&1 && python3 -c "import ${1#py:}" >/dev/null 2>&1 ;;
        file:*) f=${1#file:}
                # 64-bit distros disagree on lib vs lib64; accept either.
                [ -e "$f" ] || [ -e "${f/lib64/lib}" ] || [ -e "${f/\/lib\//\/lib64\/}" ] ;;
        *) return 1 ;;
    esac
}

if [ "$LIST" -eq 1 ]; then
    printf '%s%-14s %-10s %-9s %s%s\n' "$B" "REQUIREMENT" "GROUP" "OPTIONAL" "PACKAGE HERE" "$N"
    while IFS='|' read -r id probe group opt f d a s al; do
        [ -n "$id" ] || continue
        pkg=$(echo "$id|$probe|$group|$opt|$f|$d|$a|$s|$al" | cut -d'|' -f"${COLUMN:-5}")
        [ "$COLUMN" -eq 0 ] && pkg='?'
        printf '%-14s %-10s %-9s %s\n' "$id" "$group" "$opt" "$pkg"
    done <<<"$REQUIREMENTS"
    exit 0
fi

MISSING_PKGS=""; MISSING_IDS=""; UNPACKAGED=""; SATISFIED=0; SKIPPED_OPT=0
while IFS='|' read -r id probe group opt fed deb arc sus alp; do
    [ -n "$id" ] || continue
    case " $WANT_GROUPS " in *" $group "*) ;; *) continue ;; esac
    if have "$probe"; then SATISFIED=$((SATISFIED + 1)); continue; fi
    if [ "$opt" = yes ] && [ "$WITH_OPTIONAL" -eq 0 ]; then
        SKIPPED_OPT=$((SKIPPED_OPT + 1))
        printf '  %s○%s %-14s %s(optional, not installed)%s\n' "$D" "$N" "$id" "$D" "$N"
        continue
    fi
    case "$FAMILY" in
        fedora) pkg=$fed ;; debian) pkg=$deb ;; arch) pkg=$arc ;;
        suse)   pkg=$sus ;; alpine) pkg=$alp ;; *) pkg='-' ;;
    esac
    if [ "$pkg" = '-' ] || [ -z "$pkg" ]; then
        UNPACKAGED="$UNPACKAGED $id"
        # A few requirements are not in anyone's repositories. Where the suite
        # ships a tool that can install one, say so rather than shrugging.
        case "$id" in
            warp-cli)
                printf '  %s!%s %-14s %sno distro packages WARP — run: warp-setup.sh%s\n' \
                    "$Y" "$N" "$id" "$Y" "$N" ;;
            *)
                printf '  %s!%s %-14s %snot packaged for %s — install it yourself%s\n' \
                    "$Y" "$N" "$id" "$Y" "$FAMILY" "$N" ;;
        esac
        continue
    fi
    MISSING_IDS="$MISSING_IDS $id"
    case " $MISSING_PKGS " in *" $pkg "*) ;; *) MISSING_PKGS="$MISSING_PKGS $pkg" ;; esac
    printf '  %s✗%s %-14s %s\n' "$R" "$N" "$id" "$pkg"
done <<<"$REQUIREMENTS"

echo
printf '%s%d%s requirement(s) already satisfied' "$G" "$SATISFIED" "$N"
[ "$SKIPPED_OPT" -gt 0 ] && printf ', %d optional skipped %s(--with-optional)%s' "$SKIPPED_OPT" "$D" "$N"
echo

if [ -z "$MISSING_PKGS" ]; then
    printf '%sNothing to install.%s\n' "$G" "$N"
    [ -n "$UNPACKAGED" ] && printf '%sStill unavailable:%s%s\n' "$Y" "$N" "$UNPACKAGED"
    exit 0
fi

# shellcheck disable=SC2086
set -- $MISSING_PKGS
printf '%sMissing:%s %d package(s):%s\n' "$B" "$N" "$#" "$MISSING_PKGS"

if [ -z "$PM" ]; then
    printf '%sNo supported package manager on this system.%s\n' "$R" "$N"
    printf 'Install these by hand, then re-run:%s\n' "$MISSING_PKGS"
    exit 1
fi

INSTALL_CMD="$PM_INSTALL$MISSING_PKGS"
printf '%s  %s%s\n' "$D" "$INSTALL_CMD" "$N"

[ "$PRINT_ONLY" -eq 1 ] && { echo "$INSTALL_CMD"; exit 0; }
[ "$CHECK_ONLY" -eq 1 ] && exit 1
[ "$DRY" -eq 1 ] && { echo "(--dry-run: nothing installed)"; exit 0; }

if [ "$(id -u)" -ne 0 ]; then
    printf '%sInstalling packages needs root. Re-run with sudo.%s\n' "$R" "$N"
    exit 1
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Install them now? [y/N] '
    read -r reply </dev/tty || reply=n
    case "$reply" in [yY]*) ;; *) echo "Nothing installed."; exit 1 ;; esac
fi

[ -n "$PM_REFRESH" ] && $PM_REFRESH

if $INSTALL_CMD; then
    printf '%sAll packages installed.%s\n' "$G" "$N"
else
    # One bad package name should not sink the whole batch. Retry individually
    # so the report names exactly what this distribution does not have.
    printf '%sBatch install failed; retrying one at a time.%s\n' "$Y" "$N"
    failed=""
    for pkg in "$@"; do
        if $PM_INSTALL "$pkg" >/dev/null 2>&1; then
            printf '  %s✓%s %s\n' "$G" "$N" "$pkg"
        else
            printf '  %s✗%s %s\n' "$R" "$N" "$pkg"
            failed="$failed $pkg"
        fi
    done
    if [ -n "$failed" ]; then
        printf '%sNot installed:%s%s\n' "$R" "$N" "$failed"
        printf 'These names may differ on %s — check your repositories.\n' "$DISTRO_ID"
        exit 1
    fi
fi

# Re-probe so the exit status reflects reality, not the package manager's opinion.
still=""
while IFS='|' read -r id probe group opt _f _d _a _s _al; do
    [ -n "$id" ] || continue
    case " $MISSING_IDS " in *" $id "*) ;; *) continue ;; esac
    have "$probe" || still="$still $id"
done <<<"$REQUIREMENTS"

if [ -n "$still" ]; then
    printf '%sInstalled, but still not detected:%s%s\n' "$Y" "$N" "$still"
    printf 'A new shell may be needed, or the package splits differently here.\n'
    exit 1
fi
printf '%sEverything Panoptes needs is present.%s\n' "$G" "$N"
