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
# proton-setup.sh — install the official Proton VPN Linux client from Proton's
# own repository: the desktop app, the official CLI (`protonvpn`) and the
# AppIndicator pieces the app's tray icon needs.
#
# No distribution packages Proton VPN. Proton runs an APT and an RPM
# repository and publishes the app on Flathub. This tool adds the repository
# with Proton's signing key pinned by fingerprint — on APT it also verifies
# the signed InRelease, the Packages index and the release package hash
# before anything is installed — then installs the packages.
#
# Idempotent: every step checks the current state first and changes nothing
# that is already right. A second run reports "unchanged" for each step and
# exits 0 having touched nothing.
#
# Signing in is the one thing it cannot do for you. Afterwards, either open
# the app and sign in, or run `protonvpn signin <username>`; both share one
# session. proton-fallback and warp-tray then drive the tunnel.
#
# Usage:
#   sudo ./proton-setup.sh              repository + app + CLI + tray dependencies
#        ./proton-setup.sh --check      report what is present, change nothing (exit 1 if short)
#        ./proton-setup.sh --dry-run    print every step, change nothing
#   sudo ./proton-setup.sh --yes        do not ask before running the package manager
#   sudo ./proton-setup.sh --no-tray    skip the AppIndicator packages
#   sudo ./proton-setup.sh --no-cli     skip the official CLI
#   sudo ./proton-setup.sh --flatpak    install the Flathub build (com.protonvpn.www) instead
#   sudo ./proton-setup.sh --uninstall  remove the client, the CLI and the repository
#
# Supported: Debian/Ubuntu family (Mint, Pop!_OS, LMDE included) and Fedora
# natively; the Arch family through an AUR helper already on the machine (yay,
# paru or pamac — makepkg refuses root, so it runs as the invoking user);
# anything with Flatpak through Flathub (no CLI in that build).

set -uo pipefail
LC_ALL=C

usage() { sed -n '/^# proton-setup\.sh —/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \?//'; }

# ------------------------------------------------------------------ constants
# Proton's package-signing keys, pinned. Both were read from
# repo.protonvpn.com on 2026-10-27 and the APT one verified the live InRelease.
DEB_KEY_URL=https://repo.protonvpn.com/debian/public_key.asc
DEB_KEY_FPR=84B0D3492C76C9C6F5873C18EDA3E22630349F1C
DEB_REPO=https://repo.protonvpn.com/debian
DEB_KEYRING=/usr/share/keyrings/protonvpn-stable-archive-keyring.gpg   # what protonvpn-stable-release ships
DEB_SOURCES=/etc/apt/sources.list.d/protonvpn-stable.sources
# Proton signs EACH Fedora release's repository with its own key, so the pin
# has to be per release. The uid says which: "Proton Technologies AG
# (Fedora NN) <opensource@proton.me>". All four read from
# repo.protonvpn.com and verified over a valid TLS chain on 2026-10-27.
# An unlisted release fails closed in rpm_bootstrap rather than trusting
# whatever the repository happens to serve.
rpm_key_fpr_for() {
    case "$1" in
        41) echo F20018AD1914638BC3B485F7413E4BA367FCBBBB ;;
        42) echo 55AA81128CFFFF46DF140838BC187A13AD10060B ;;
        43) echo 7BB2808996C47DC9EECDA475F7EB64B08C03490D ;;
        44) echo 6929133BDE1CE1CFA9EDB286D84176F6844830D4 ;;
        *)  echo "" ;;
    esac
}
RPM_KEY_FPR=""
RPM_REPO_FILE=/etc/yum.repos.d/protonvpn-stable.repo
FLATPAK_ID=com.protonvpn.www
AUR_APP=proton-vpn-gtk-app
AUR_CLI=proton-vpn-cli

# Package names per family. The metapackage pulls the app, the daemon and the
# NetworkManager plug-ins; the CLI is separate; the tray bits are what Proton's
# own instructions tell you to add for the indicator icon.
DEB_APP="proton-vpn-gnome-desktop"
DEB_CLI="proton-vpn-cli"
DEB_TRAY="libayatana-appindicator3-1 gir1.2-ayatanaappindicator3-0.1"
RPM_APP="proton-vpn-gnome-desktop"
RPM_CLI="proton-vpn-cli"
RPM_TRAY="libappindicator-gtk3"
ARCH_TRAY="libappindicator-gtk3"

# ------------------------------------------------------------------ arguments
MODE=full; DRY=0; ASSUME_YES=0; TRAY=1; CLI=1; FLATPAK=0
for a in "$@"; do
    case "$a" in
        --check)     MODE=check ;;
        --uninstall) MODE=uninstall ;;
        --dry-run)   DRY=1 ;;
        -y|--yes)    ASSUME_YES=1 ;;
        --no-tray)   TRAY=0 ;;
        --no-cli)    CLI=0 ;;
        --flatpak)   FLATPAK=1 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "proton-setup.sh: unknown option: $a" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[0;33m'; D=$'\e[0;90m'; N=$'\e[0m'
else B=; R=; G=; Y=; D=; N=; fi
say()  { printf '%s%s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
same() { printf '  %s=%s %s %s(unchanged)%s\n' "$D" "$N" "$*" "$D" "$N"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '  %s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
CHANGED=0
run() {  # honour --dry-run for anything that changes the system
    if [ "$DRY" -eq 1 ]; then printf '  %swould:%s %s\n' "$Y" "$N" "$*"; return 0; fi
    CHANGED=1
    "$@"
}
CURL="curl -fsSL --proto =https --tlsv1.2 --max-time 60"

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# ------------------------------------------------------------------ detection
FAMILY=unknown; PRETTY=unknown; DISTRO_ID=unknown; VER_ID=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
    DISTRO_ID="${ID:-unknown}"
    VER_ID="${VERSION_ID:-}"
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
# Proton publishes fedora-NN repositories only; RHEL-likes get Flatpak.
case "$FAMILY:$DISTRO_ID" in
    fedora:fedora) ;;
    fedora:*) [ "$FLATPAK" -eq 1 ] || { FLATPAK=1; FLATPAK_REASON="Proton has no RPM repository for $DISTRO_ID"; } ;;
    suse:*|alpine:*|unknown:*) [ "$FLATPAK" -eq 1 ] || { FLATPAK=1; FLATPAK_REASON="Proton packages nothing for $FAMILY"; } ;;
esac
[ "$FAMILY" = fedora ] && RPM_KEY_FPR=$(rpm_key_fpr_for "$VER_ID")
FLATPAK_REASON="${FLATPAK_REASON:-}"

# The user who will run the app (makepkg and flatpak --user care; root does not).
RUN_USER="${SUDO_USER:-$(id -un)}"
[ "$RUN_USER" = root ] && RUN_USER=""
as_user() {  # as_user CMD... — run as the invoking user when we are root
    if [ "$(id -u)" -eq 0 ] && [ -n "$RUN_USER" ]; then runuser -u "$RUN_USER" -- "$@"; else "$@"; fi
}

# ------------------------------------------------------------------ probes
deb_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
rpm_installed() { rpm -q "$1" >/dev/null 2>&1; }
arch_installed() { pacman -Q "$1" >/dev/null 2>&1; }
flatpak_installed() { command -v flatpak >/dev/null 2>&1 && flatpak info "$FLATPAK_ID" >/dev/null 2>&1; }
app_installed() { command -v protonvpn-app >/dev/null 2>&1 || flatpak_installed; }
cli_installed() { command -v protonvpn >/dev/null 2>&1 && protonvpn --help 2>/dev/null | grep -q 'Proton VPN command-line'; }
pkg_installed() {  # pkg_installed NAME — per family
    case "$FAMILY" in
        debian) deb_installed "$1" ;; fedora) rpm_installed "$1" ;; arch) arch_installed "$1" ;; *) return 1 ;;
    esac
}
missing_of() {  # missing_of "pkg pkg ..." -> the ones not installed
    local p out=""
    for p in $1; do pkg_installed "$p" || out="$out $p"; done
    printf '%s' "${out# }"
}
key_fpr_of() {  # key_fpr_of FILE (armored or binary keyring) -> primary fingerprint
    gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'
}
cli_version() {
    case "$FAMILY" in
        debian) dpkg-query -W -f='${Version}' proton-vpn-cli 2>/dev/null ;;
        fedora) rpm -q --qf '%{VERSION}' proton-vpn-cli 2>/dev/null ;;
        arch)   pacman -Q "$AUR_CLI" 2>/dev/null | awk '{print $2}' ;;
        *)      echo installed ;;
    esac
}
app_version() {
    case "$FAMILY" in
        debian) dpkg-query -W -f='${Version}' proton-vpn-gtk-app 2>/dev/null ;;
        fedora) rpm -q --qf '%{VERSION}' proton-vpn-gtk-app 2>/dev/null ;;
        arch)   pacman -Q "$AUR_APP" 2>/dev/null | awk '{print $2}' ;;
    esac
    flatpak_installed && flatpak info "$FLATPAK_ID" 2>/dev/null | awk -F': *' '/^ *Version/{print "flatpak " $2; exit}'
}

confirm_pm() {  # ask once before the package manager runs
    [ "$ASSUME_YES" -eq 1 ] || [ "$DRY" -eq 1 ] && return 0
    [ "${CONFIRMED:-0}" -eq 1 ] && return 0
    printf 'Run the package manager now? [y/N] '
    local r; read -r r </dev/tty || r=n
    case "$r" in [yY]*) CONFIRMED=1; return 0 ;; *) echo "Nothing installed."; exit 1 ;; esac
}

# ------------------------------------------------------------------ report
report() {
    say "Proton VPN"
    printf '  %-12s %s\n' "system" "$PRETTY ${D}(family=$FAMILY$([ "$FLATPAK" -eq 1 ] && echo ', flatpak path'))${N}"
    local short=0
    case "$FAMILY" in
        debian)
            if [ -f "$DEB_SOURCES" ] && [ -f "$DEB_KEYRING" ]; then
                if [ "$(key_fpr_of "$DEB_KEYRING")" = "$DEB_KEY_FPR" ]; then ok "repository  $DEB_SOURCES (key fingerprint matches)"
                else warn "repository  $DEB_SOURCES — keyring fingerprint does NOT match the pinned key"; fi
            else warn "repository  not configured"; fi ;;
        fedora)
            if [ -f "$RPM_REPO_FILE" ]; then ok "repository  $RPM_REPO_FILE"; else warn "repository  not configured"; fi
            if [ -z "$RPM_KEY_FPR" ]; then warn "signing key no pinned key for Fedora $VER_ID"
            elif rpm -q "gpg-pubkey-$(printf '%s' "$RPM_KEY_FPR" | tail -c 8 | tr 'A-F' 'a-f')" >/dev/null 2>&1; then ok "signing key imported"
            else warn "signing key not imported"; fi ;;
    esac
    if app_installed; then ok "app         $(app_version)"; else warn "app         not installed"; short=1; fi
    if [ "$CLI" -eq 1 ]; then
        if cli_installed; then ok "cli         $(cli_version)"
        elif [ "$FLATPAK" -eq 1 ]; then printf '  %-12s %s\n' "cli" "${D}none in the Flathub build${N}"
        else warn "cli         not installed"; short=1; fi
    fi
    if [ "$TRAY" -eq 1 ] && [ "$FLATPAK" -eq 0 ]; then
        local tray=""
        case "$FAMILY" in debian) tray=$DEB_TRAY ;; fedora) tray=$RPM_TRAY ;; arch) tray=$ARCH_TRAY ;; esac
        local m; m=$(missing_of "$tray")
        if [ -z "$m" ]; then ok "tray deps   present"; else warn "tray deps   missing: $m"; short=1; fi
    fi
    local units; units=$(systemctl list-unit-files 'proton*' --no-legend 2>/dev/null | awk '{print $1"="$2}' | tr '\n' ' ')
    [ -n "$units" ] && printf '  %-12s %s\n' "units" "$units"
    local active; active=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | grep -i proton | tr '\n' ' ')
    printf '  %-12s %s\n' "tunnel" "${active:-not connected}"
    if app_installed; then
        echo
        echo "  Sign in once, in the app or with:  protonvpn signin <username>"
        echo "  Then:  proton-fallback on   (parks WARP, connects Proton VPN)"
    fi
    return $short
}

# ------------------------------------------------------------------ uninstall
do_uninstall() {
    report; echo
    say "This will remove the Proton VPN client, the CLI and Proton's repository."
    if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY" -eq 0 ]; then
        printf 'Continue? [y/N] '; local r; read -r r </dev/tty || r=n
        case "$r" in [yY]*) ;; *) echo "Nothing removed."; exit 1 ;; esac
    fi
    if flatpak_installed; then run $SUDO flatpak uninstall -y "$FLATPAK_ID"; fi
    case "$FAMILY" in
        debian)
            # shellcheck disable=SC2046
            run $SUDO apt-get purge -y proton-vpn-gnome-desktop proton-vpn-gtk-app proton-vpn-cli proton-vpn-daemon \
                $(dpkg-query -W -f='${Package} ' 'python3-proton-*' 2>/dev/null) protonvpn-stable-release
            run $SUDO apt-get autoremove -y
            run $SUDO rm -f "$DEB_SOURCES" "$DEB_KEYRING" /etc/apt/sources.list.d/protonvpn-stable.list ;;
        fedora)
            local dnf=dnf; command -v dnf5 >/dev/null 2>&1 && dnf=dnf5
            run $SUDO "$dnf" remove -y 'proton-vpn-*' 'python3-proton-*' protonvpn-stable-release
            run $SUDO rm -f "$RPM_REPO_FILE" ;;
        arch)
            arch_installed "$AUR_APP" && run $SUDO pacman -Rns --noconfirm "$AUR_APP"
            arch_installed "$AUR_CLI" && run $SUDO pacman -Rns --noconfirm "$AUR_CLI" ;;
    esac
    [ "$CHANGED" -eq 1 ] && ok "removed" || echo "  nothing to remove"
    echo "  Your Proton account and any NetworkManager profiles you imported were left alone."
}

# ------------------------------------------------------------------ apt
# Bootstrap chain, all verified before dpkg sees anything:
#   pinned fingerprint -> public_key.asc -> signed InRelease -> SHA256 of
#   Packages -> SHA256 of protonvpn-stable-release_*.deb -> dpkg -i.
# After that Proton's own release package owns the sources file and keyring,
# so key rotations arrive the way Proton intends.
apt_bootstrap() {
    if deb_installed protonvpn-stable-release; then same "repository package protonvpn-stable-release"; return 0; fi
    say "Adding Proton's APT repository (signature-pinned bootstrap)"
    if [ "$DRY" -eq 1 ]; then
        printf '  %swould:%s fetch and verify %s against %s\n' "$Y" "$N" "$DEB_KEY_URL" "$DEB_KEY_FPR"
        printf '  %swould:%s verify InRelease, Packages and protonvpn-stable-release_*.deb, then dpkg -i it\n' "$Y" "$N"
        return 0
    fi
    command -v gpg >/dev/null 2>&1 || die "gpg is needed to verify Proton's key (apt-get install gnupg)"
    TMP=$(mktemp -d)
    $CURL -o "$TMP/key.asc" "$DEB_KEY_URL" || die "could not fetch $DEB_KEY_URL"
    local fpr; fpr=$(key_fpr_of "$TMP/key.asc")
    [ "$fpr" = "$DEB_KEY_FPR" ] || die "Proton's key fingerprint is $fpr, expected $DEB_KEY_FPR — refusing"
    ok "signing key matches the pinned fingerprint"
    gpg --batch --quiet --no-default-keyring --keyring "$TMP/k.gpg" --import "$TMP/key.asc" 2>/dev/null \
        || die "could not import the key into a scratch keyring"
    $CURL -o "$TMP/InRelease" "$DEB_REPO/dists/stable/InRelease" || die "could not fetch InRelease"
    gpg --batch --quiet --no-default-keyring --keyring "$TMP/k.gpg" --status-file "$TMP/status" \
        --output "$TMP/Release" --decrypt "$TMP/InRelease" >/dev/null 2>&1
    grep -q "^\[GNUPG:\] VALIDSIG $DEB_KEY_FPR" "$TMP/status" || die "InRelease is not signed by the pinned key — refusing"
    ok "InRelease signature verified"
    local want_sha
    want_sha=$(awk '/^SHA256:/{f=1; next} /^[A-Za-z]/{f=0} f && $3=="main/binary-all/Packages"{print $1; exit}' "$TMP/Release")
    [ -n "$want_sha" ] || die "InRelease lists no main/binary-all/Packages"
    $CURL -o "$TMP/Packages" "$DEB_REPO/dists/stable/main/binary-all/Packages" || die "could not fetch Packages"
    [ "$(sha256sum "$TMP/Packages" | cut -c1-64)" = "$want_sha" ] || die "Packages index hash mismatch — refusing"
    # Newest protonvpn-stable-release stanza: "version filename sha256".
    local line ver file sha
    line=$(awk '/^Package: protonvpn-stable-release$/{f=1; v=""; fn=""; s=""} f&&/^Version:/{v=$2} f&&/^Filename:/{fn=$2} f&&/^SHA256:/{s=$2} f&&/^$/{if(v!="")print v, fn, s; f=0} END{if(f&&v!="")print v, fn, s}' "$TMP/Packages" | sort -V | tail -1)
    read -r ver file sha <<<"$line"
    [ -n "$file" ] && [ -n "$sha" ] || die "no protonvpn-stable-release package in the index"
    $CURL -o "$TMP/release.deb" "$DEB_REPO/$file" || die "could not fetch $file"
    [ "$(sha256sum "$TMP/release.deb" | cut -c1-64)" = "$sha" ] || die "release package hash mismatch — refusing"
    ok "protonvpn-stable-release $ver verified"
    confirm_pm
    run $SUDO dpkg -i "$TMP/release.deb" >/dev/null || die "dpkg -i failed"
    ok "$DEB_SOURCES + $DEB_KEYRING installed by Proton's package"
    [ "$(key_fpr_of "$DEB_KEYRING")" = "$DEB_KEY_FPR" ] || die "the installed keyring does not carry the pinned key — remove $DEB_SOURCES and report this"
    NEED_REFRESH=1
}

apt_install() {
    local want="$DEB_APP" m
    [ "$CLI" -eq 1 ] && want="$want $DEB_CLI"
    [ "$TRAY" -eq 1 ] && want="$want $DEB_TRAY"
    command -v gnome-shell >/dev/null 2>&1 && [ "$TRAY" -eq 1 ] && want="$want gnome-shell-extension-appindicator"
    m=$(missing_of "$want")
    if [ -z "$m" ]; then same "packages: $want"; return 0; fi
    say "Installing: $m"
    confirm_pm
    if [ "${NEED_REFRESH:-0}" -eq 1 ] || [ "$DRY" -eq 1 ]; then run $SUDO apt-get update -qq || die "apt-get update failed"; fi
    # shellcheck disable=SC2086
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $m || die "package install failed"
    [ "$DRY" -eq 1 ] || ok "installed"
}

# ------------------------------------------------------------------ dnf
rpm_bootstrap() {
    [ -n "$RPM_KEY_FPR" ] || die "no pinned signing key for Fedora $VER_ID (Proton uses one key per release).
  Verify it yourself, then add it to rpm_key_fpr_for():
    curl -fsSL https://repo.protonvpn.com/fedora-${VER_ID}-stable/public_key.asc | gpg --show-keys
  The uid must read 'Proton Technologies AG (Fedora ${VER_ID}) <opensource@proton.me>'."
    local keyid; keyid=$(printf '%s' "$RPM_KEY_FPR" | tail -c 8 | tr 'A-F' 'a-f')
    local base="https://repo.protonvpn.com/fedora-${VER_ID}-stable"
    if rpm -q "gpg-pubkey-$keyid" >/dev/null 2>&1; then same "signing key gpg-pubkey-$keyid"
    else
        say "Importing Proton's RPM signing key"
        if [ "$DRY" -eq 1 ]; then printf '  %swould:%s fetch %s/public_key.asc, check %s, rpm --import\n' "$Y" "$N" "$base" "$RPM_KEY_FPR"
        else
            [ -n "$TMP" ] || TMP=$(mktemp -d)
            $CURL -o "$TMP/key.asc" "$base/public_key.asc" || die "could not fetch $base/public_key.asc"
            local fpr; fpr=$(key_fpr_of "$TMP/key.asc")
            [ "$fpr" = "$RPM_KEY_FPR" ] || die "Proton's key fingerprint is $fpr, expected $RPM_KEY_FPR — refusing"
            run $SUDO rpm --import "$TMP/key.asc" || die "rpm --import failed"
            ok "key imported"
        fi
    fi
    if rpm_installed protonvpn-stable-release; then same "repository package protonvpn-stable-release"; return 0; fi
    say "Adding Proton's RPM repository (Fedora $VER_ID)"
    if [ "$DRY" -eq 1 ]; then printf '  %swould:%s fetch the newest protonvpn-stable-release rpm from %s, rpm -K it, dnf install it\n' "$Y" "$N" "$base"; return 0; fi
    [ -n "$TMP" ] || TMP=$(mktemp -d)
    local name
    name=$($CURL "$base/protonvpn-stable-release/" 2>/dev/null | grep -oE 'protonvpn-stable-release-[0-9.]+-[0-9]+\.noarch\.rpm' | sort -uV | tail -1)
    [ -n "$name" ] || die "no release package listed at $base/protonvpn-stable-release/ — Proton may not ship Fedora $VER_ID yet (try --flatpak)"
    $CURL -o "$TMP/$name" "$base/protonvpn-stable-release/$name" || die "could not fetch $name"
    rpm -K "$TMP/$name" 2>/dev/null | grep -qiE 'signatures OK|pgp.*OK' || die "$name is not signed by the imported key — refusing"
    ok "$name signature verified"
    confirm_pm
    local dnf=dnf; command -v dnf5 >/dev/null 2>&1 && dnf=dnf5
    run $SUDO "$dnf" install -y "$TMP/$name" >/dev/null || die "could not install $name"
    ok "$RPM_REPO_FILE installed by Proton's package"
}

rpm_install() {
    local want="$RPM_APP" m
    [ "$CLI" -eq 1 ] && want="$want $RPM_CLI"
    [ "$TRAY" -eq 1 ] && want="$want $RPM_TRAY"
    command -v gnome-shell >/dev/null 2>&1 && [ "$TRAY" -eq 1 ] && want="$want gnome-shell-extension-appindicator"
    m=$(missing_of "$want")
    if [ -z "$m" ]; then same "packages: $want"; return 0; fi
    say "Installing: $m"
    confirm_pm
    local dnf=dnf; command -v dnf5 >/dev/null 2>&1 && dnf=dnf5
    # shellcheck disable=SC2086
    run $SUDO "$dnf" install -y $m || die "package install failed"
    [ "$DRY" -eq 1 ] || ok "installed"
}

# ------------------------------------------------------------------ arch (AUR)
aur_install() {
    local helper="" want="" m
    for h in paru yay pamac; do command -v "$h" >/dev/null 2>&1 && { helper=$h; break; }; done
    [ -n "$RUN_USER" ] || [ -z "$helper" ] || warn "running as root with no invoking user — makepkg will refuse; run with sudo from your account"
    if [ "$TRAY" -eq 1 ]; then
        m=$(missing_of "$ARCH_TRAY")
        if [ -z "$m" ]; then same "packages: $ARCH_TRAY"
        else say "Installing: $m"; confirm_pm
             # shellcheck disable=SC2086
             run $SUDO pacman -S --needed --noconfirm $m || die "pacman failed"; fi
    fi
    want="$AUR_APP"; [ "$CLI" -eq 1 ] && want="$want $AUR_CLI"
    m=$(missing_of "$want")
    if [ -z "$m" ]; then same "AUR packages: $want"; return 0; fi
    if [ -z "$helper" ]; then
        warn "no AUR helper (paru, yay or pamac) found — build these yourself: $m"
        warn "or re-run with --flatpak"
        return 1
    fi
    say "Building from the AUR with $helper: $m"
    confirm_pm
    case "$helper" in
        pamac) # shellcheck disable=SC2086
               run as_user pamac build --no-confirm $m || die "pamac build failed" ;;
        *)     # shellcheck disable=SC2086
               run as_user "$helper" -S --needed --noconfirm $m || die "$helper failed" ;;
    esac
    [ "$DRY" -eq 1 ] || ok "installed"
}

# ------------------------------------------------------------------ flatpak
flatpak_install() {
    command -v flatpak >/dev/null 2>&1 || die "flatpak is not installed and Proton packages nothing native here${FLATPAK_REASON:+ ($FLATPAK_REASON)}"
    if flatpak_installed; then same "flatpak $FLATPAK_ID"; return 0; fi
    say "Installing $FLATPAK_ID from Flathub${FLATPAK_REASON:+ ($FLATPAK_REASON)}"
    confirm_pm
    run $SUDO flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || die "could not add Flathub"
    run $SUDO flatpak install -y flathub "$FLATPAK_ID" || die "flatpak install failed"
    [ "$DRY" -eq 1 ] || ok "installed"
    [ "$CLI" -eq 1 ] && warn "the Flathub build has no CLI; proton-fallback will drive the app window instead"
}

# ------------------------------------------------------------------ main
case "$MODE" in
    check)     report; exit $? ;;
    uninstall) do_uninstall; exit 0 ;;
esac

NEED_REFRESH=0
if [ "$FLATPAK" -eq 1 ]; then
    flatpak_install
else
    case "$FAMILY" in
        debian) apt_bootstrap; apt_install ;;
        fedora) rpm_bootstrap; rpm_install ;;
        arch)   aur_install ;;
    esac
fi

echo
report || true
echo
if [ "$DRY" -eq 1 ]; then echo "(--dry-run: nothing was changed)"
elif [ "$CHANGED" -eq 0 ]; then printf '%sNothing changed — already in the desired state.%s\n' "$G" "$N"
else printf '%sDone.%s\n' "$G" "$N"; fi
