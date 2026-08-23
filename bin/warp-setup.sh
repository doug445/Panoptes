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
# warp-setup.sh — install, register and activate Cloudflare WARP.
#
# No distribution packages WARP. Cloudflare runs its own repository, so this
# adds it, installs the client, registers the device and connects.
#
# The mode it sets is tunnel_only, deliberately. WARP's other modes proxy DNS
# themselves, which fights every other tool in this suite: harden-dns.sh pins
# DNSSEC and DNS-over-TLS in systemd-resolved, dns-toggle switches the resolver
# underneath it, and checkdns audits the result. tunnel_only carries your
# traffic and leaves name resolution to resolved, so the two stop arguing.
# Pass --mode if you want something else.
#
# Usage:
#   sudo ./warp-setup.sh                repo, package, registration, connect
#   sudo ./warp-setup.sh --install-only add the repo and package, stop there
#        ./warp-setup.sh --register     register this device and connect
#        ./warp-setup.sh --check        report what is present, change nothing
#        ./warp-setup.sh --mode MODE    set the operating mode and exit
#   sudo ./warp-setup.sh --uninstall    remove the client and the repository
#        ./warp-setup.sh --dry-run      print every step, change nothing
#        ./warp-setup.sh --yes          do not ask before registering
#
# Registration contacts Cloudflare and creates a device record on their side,
# so it asks first unless --yes is given.
#
# Supported: Fedora/RHEL family and Debian/Ubuntu family, which is what
# Cloudflare publishes packages for. Arch has an AUR build this cannot drive.

set -uo pipefail
LC_ALL=C

usage() { sed -n '/^# warp-setup\.sh —/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \?//'; }

WARP_MODE="${WARP_MODE:-tunnel_only}"
REPO_RPM=/etc/yum.repos.d/cloudflare-warp.repo
REPO_DEB=/etc/apt/sources.list.d/cloudflare-client.list
KEYRING_DEB=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
PUBKEY=https://pkg.cloudflareclient.com/pubkey.gpg
# Fedora's curl, never /usr/local/bin/curl -- that may be a minimal ECH build.
CURL=/usr/bin/curl

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[0;33m'; D=$'\e[0;90m'; N=$'\e[0m'
else B=; R=; G=; Y=; D=; N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

MODE=full; DRY=0; ASSUME_YES=0; SET_MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --install-only) MODE=install ;;
        --register)     MODE=register ;;
        --check)        MODE=check ;;
        --uninstall)    MODE=uninstall ;;
        --dry-run)      DRY=1 ;;
        -y|--yes)       ASSUME_YES=1 ;;
        --mode)         shift; [ $# -gt 0 ] || die "--mode needs a value"; SET_MODE=$1; MODE=setmode ;;
        --mode=*)       SET_MODE=${1#--mode=}; MODE=setmode ;;
        -h|--help)      usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

case "${SET_MODE:-$WARP_MODE}" in
    warp|doh|warp+doh|dot|warp+dot|proxy|tunnel_only) ;;
    *) die "invalid mode: ${SET_MODE:-$WARP_MODE} (warp, doh, warp+doh, dot, warp+dot, proxy, tunnel_only)" ;;
esac

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
run() {  # honour --dry-run for anything that changes the system
    if [ "$DRY" -eq 1 ]; then printf '  %swould:%s %s\n' "$Y" "$N" "$*"; return 0; fi
    "$@"
}

# ------------------------------------------------------------------ detection
FAMILY=unknown; PRETTY=unknown; CODENAME=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
    CODENAME="${VERSION_CODENAME:-}"
    for c in "${ID:-}" ${ID_LIKE:-}; do
        case "$c" in
            fedora|rhel|centos|rocky|almalinux) FAMILY=fedora; break ;;
            debian|ubuntu|linuxmint|pop|raspbian) FAMILY=debian; break ;;
            arch|archlinux|manjaro|endeavouros) FAMILY=arch; break ;;
            opensuse*|suse|sles) FAMILY=suse; break ;;
            alpine) FAMILY=alpine; break ;;
        esac
    done
fi

warp_installed()  { command -v warp-cli >/dev/null 2>&1; }
warp_registered() { warp-cli --accept-tos registration show >/dev/null 2>&1; }
warp_connected()  { warp-cli --accept-tos status 2>/dev/null | grep -q Connected; }

report() {
    say "Cloudflare WARP"
    printf '  %-12s %s\n' "system" "$PRETTY ${D}(family=$FAMILY)${N}"
    if warp_installed; then
        ok "client installed  $(warp-cli --version 2>/dev/null | head -1)"
    else
        warn "client not installed"
        return 0
    fi
    printf '  %-12s %s\n' "daemon" "$(systemctl is-active warp-svc 2>/dev/null) / $(systemctl is-enabled warp-svc 2>/dev/null)"
    if warp_registered; then ok "device registered"; else warn "not registered — run: $0 --register"; fi
    if warp_connected; then
        ok "connected  $(warp-cli --accept-tos status 2>/dev/null | head -1)"
        printf '  %-12s %s\n' "mode" "$(warp-cli --accept-tos settings 2>/dev/null | sed -n 's/.*Mode: //p' | head -1)"
    else
        warn "not connected"
    fi
}

verify() {
    say "Verifying against Cloudflare"
    local trace
    trace=$($CURL -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    [ -n "$trace" ] || { warn "could not reach the trace endpoint"; return 1; }
    local w; w=$(printf '%s\n' "$trace" | sed -n 's/^warp=//p')
    printf '%s\n' "$trace" | grep -E '^(warp|ip|loc|colo)=' | sed 's/^/    /'
    case "$w" in
        on|plus) ok "traffic is going through WARP" ;;
        *) warn "warp=$w — traffic is NOT in the tunnel" ; return 1 ;;
    esac
}

# ------------------------------------------------------------------ uninstall
if [ "$MODE" = uninstall ]; then
    report; echo
    say "This will remove the WARP client and Cloudflare's repository."
    echo "  Your device registration on Cloudflare's side is NOT deleted."
    echo "  To drop that too, first run:  warp-cli registration delete"
    if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY" -eq 0 ]; then
        printf 'Proceed? [y/N] '
        read -r r </dev/tty || r=n
        case "$r" in [yY]*) ;; *) echo "Nothing removed."; exit 1 ;; esac
    fi
    warp_connected && run warp-cli --accept-tos disconnect >/dev/null 2>&1
    run $SUDO systemctl disable --now warp-svc >/dev/null 2>&1
    case "$FAMILY" in
        fedora) run $SUDO dnf remove -y cloudflare-warp; run $SUDO rm -f "$REPO_RPM" ;;
        debian) run $SUDO apt-get remove -y cloudflare-warp
                run $SUDO rm -f "$REPO_DEB" "$KEYRING_DEB"; run $SUDO apt-get update ;;
        *) warn "cannot uninstall automatically on $FAMILY — remove the package by hand" ;;
    esac
    # The tunnel is gone; drop any DNS the resolver cached through it.
    run resolvectl flush-caches 2>/dev/null
    ok "removed"
    exit 0
fi

[ "$MODE" = check ] && { report; exit 0; }

if [ "$MODE" = setmode ]; then
    warp_installed || die "WARP is not installed"
    say "Setting mode to $SET_MODE"
    run warp-cli --accept-tos mode "$SET_MODE" || die "could not set mode"
    ok "mode is now $SET_MODE"
    exit 0
fi

# -------------------------------------------------------------------- install
install_client() {
    if warp_installed; then ok "client already installed"; return 0; fi
    case "$FAMILY" in
        fedora)
            say "Adding Cloudflare's RPM repository"
            # Written by hand rather than fetched and piped to a shell: the file
            # is four lines, and gpgcheck must be on with Cloudflare's own key.
            if [ "$DRY" -eq 1 ]; then
                printf '  %swould:%s write %s\n' "$Y" "$N" "$REPO_RPM"
            else
                $SUDO tee "$REPO_RPM" >/dev/null <<REPO
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=$PUBKEY
REPO
                ok "$REPO_RPM"
            fi
            say "Installing cloudflare-warp"
            local dnf=dnf
            command -v dnf5 >/dev/null 2>&1 && dnf=dnf5
            run $SUDO "$dnf" install -y cloudflare-warp || die "package install failed"
            ;;
        debian)
            [ -n "$CODENAME" ] || die "cannot determine the release codename from /etc/os-release"
            say "Adding Cloudflare's APT repository ($CODENAME)"
            run $SUDO install -d -m 0755 /usr/share/keyrings
            if [ "$DRY" -eq 1 ]; then
                printf '  %swould:%s fetch %s -> %s\n' "$Y" "$N" "$PUBKEY" "$KEYRING_DEB"
                printf '  %swould:%s write %s\n' "$Y" "$N" "$REPO_DEB"
            else
                $CURL -fsSL "$PUBKEY" | $SUDO gpg --yes --dearmor --output "$KEYRING_DEB" \
                    || die "could not fetch or dearmor Cloudflare's signing key"
                echo "deb [signed-by=$KEYRING_DEB] https://pkg.cloudflareclient.com/ $CODENAME main" \
                    | $SUDO tee "$REPO_DEB" >/dev/null
                ok "$REPO_DEB"
            fi
            run $SUDO apt-get update
            say "Installing cloudflare-warp"
            run $SUDO apt-get install -y cloudflare-warp || die "package install failed"
            ;;
        arch)
            die "Cloudflare publishes no Arch package. Build cloudflare-warp-bin from the AUR, then re-run with --register." ;;
        *)
            die "Cloudflare publishes no package for $FAMILY (Fedora/RHEL and Debian/Ubuntu only)." ;;
    esac
    run $SUDO systemctl enable --now warp-svc
    ok "warp-svc running"
}

register_and_connect() {
    warp_installed || die "WARP is not installed — run this without --register first"
    if warp_registered; then
        ok "device already registered"
    else
        say "Registering this device"
        echo "  This contacts Cloudflare and creates a device record on their side."
        if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY" -eq 0 ]; then
            printf 'Register now? [y/N] '
            read -r r </dev/tty || r=n
            case "$r" in [yY]*) ;; *) echo "Not registered."; exit 1 ;; esac
        fi
        run warp-cli --accept-tos registration new || die "registration failed"
        ok "registered"
    fi

    say "Setting mode to $WARP_MODE"
    run warp-cli --accept-tos mode "$WARP_MODE" || warn "could not set mode $WARP_MODE"

    say "Connecting"
    run warp-cli --accept-tos connect || die "connect failed"
    [ "$DRY" -eq 0 ] && sleep 4

    # Bringing the tunnel up kills DNS lookups in flight over the old path, and
    # resolved caches those failures. Same reason warp-tray flushes.
    run resolvectl flush-caches 2>/dev/null
    run resolvectl reset-server-features 2>/dev/null
}

case "$MODE" in
    install)  install_client; echo; report ;;
    register) register_and_connect; echo; report; echo; verify ;;
    full)     install_client; echo; register_and_connect; echo; report; echo; verify ;;
esac

echo
cat <<'NOTES'
  WARP is now carrying your traffic, and in tunnel_only mode it leaves DNS to
  systemd-resolved -- so harden-dns.sh, dns-toggle and checkdns keep working
  exactly as before.

  Related tools:
    checkdns          resolver, WARP and ECH status in one readout
    warp-tray         tray applet: click to connect or disconnect
    warp-killswitch   tear WARP down and reset the network when it wedges
    netmaster warp    status, on, off, reset
NOTES
