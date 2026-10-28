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
# endpoint-setup.sh — the endpoint component: an outbound application firewall
# and a persistence watch, the Linux counterparts of LuLu, KnockKnock and
# BlockBlock on the macOS suite.
#
#   OpenSnitch  blocks outbound connections you have not approved, per
#               application, with a prompt. Distribution packages on the
#               Debian, Fedora and Arch families. This tool seeds "allow"
#               rules for the suite's own daemons and probes — systemd-resolved,
#               NetworkManager, warp-svc, the kill-switch's raw-IP pings and
#               portal checks — so the watchdog is never left waiting on a
#               dialog, and makes the prompt UI start with the desktop.
#   osquery     exposes the operating system as tables. This tool installs it
#               from osquery's own repository with the signing key pinned by
#               fingerprint, and ships a persistence pack: systemd units in
#               admin paths, cron, autostart entries, kernel modules,
#               authorized keys, sudoers, SUID binaries, ld.so.preload and
#               listening ports, processes whose binary was deleted, and the
#               hashes of the shell and dispatcher hook files. `persistcheck`
#               lists all of it on demand (KnockKnock); `persistwatch`, a root
#               service, raises a desktop notification when a row appears
#               (BlockBlock).
#
# Idempotent: every file is compared before it is written and every service
# checked before it is enabled; a re-run reports "unchanged" and exits 0 with
# nothing touched. Your own osquery.conf and OpenSnitch rules are never
# overwritten: the suite's files carry a marker and only those are managed.
#
# Usage:
#   sudo ./endpoint-setup.sh              OpenSnitch + osquery + pack + services
#        ./endpoint-setup.sh --check      report what is present, change nothing (exit 1 if short)
#        ./endpoint-setup.sh --dry-run    print every step, change nothing
#   sudo ./endpoint-setup.sh --yes        do not ask before running the package manager
#   sudo ./endpoint-setup.sh --no-opensnitch | --no-osquery
#   sudo ./endpoint-setup.sh --uninstall  remove the suite's rules, pack, config and
#                                         service; disable what it enabled; leave the
#                                         packages (add --purge to remove them too)
#
# Supported, on x86_64 and aarch64 alike: Debian/Ubuntu family (both from
# packages), Arch family (both in extra), Fedora and openSUSE (osquery from its
# repository, OpenSnitch from upstream's signed release, since neither
# distribution packages it). Elsewhere it says what to install by hand.

set -uo pipefail
LC_ALL=C

usage() { sed -n '/^# endpoint-setup\.sh —/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \?//'; }

# ------------------------------------------------------------------ constants
# osquery's package-signing key: one key for both the APT and the RPM
# repository, read from pkg.osquery.io on 2026-10-27, and it verified the live
# APT InRelease.
OSQ_KEY_FPR=1484120AC4E9F8A1A577AEEE97A80C63C9D8B80B
OSQ_DEB_KEY_URL=https://pkg.osquery.io/deb/pubkey.gpg
OSQ_DEB_KEYRING=/etc/apt/keyrings/osquery.asc
OSQ_DEB_LIST=/etc/apt/sources.list.d/osquery.list
OSQ_RPM_KEY_URL=https://pkg.osquery.io/rpm/GPG
OSQ_RPM_KEYFILE=/etc/pki/rpm-gpg/RPM-GPG-KEY-osquery
OSQ_RPM_REPO=/etc/yum.repos.d/osquery-s3-rpm.repo
OSQ_CONF=/etc/osquery/osquery.conf
OSQ_CONF_COPY=/etc/osquery/.osquery.conf.panoptes    # what we last wrote; differs => yours
OSQ_PACK=/etc/osquery/packs/panoptes-persistence.conf
OSQ_LOG_DIR=/var/log/osquery
OSN_RULES=/etc/opensnitchd/rules
# OpenSnitch's maintainer signs each GitHub release's readme.txt, which lists
# SHA-512 sums for every package (deb and rpm, x86_64 and aarch64). Fedora and
# openSUSE package neither OpenSnitch nor its UI, so there the packages come
# from that release: pinned key -> signed readme -> checksum -> package manager.
OSN_KEY_FPR=F34016AC014BAAF8C90AC730141D0D4E9FF44A67     # Gustavo Iñiguez Goya, read 2026-10-27
OSN_RELEASES=https://github.com/evilsocket/opensnitch/releases
OSN_API=https://api.github.com/repos/evilsocket/opensnitch/releases/latest
OSN_UI_AUTOSTART=/etc/xdg/autostart/opensnitch_ui.desktop
PW_BIN=/usr/local/bin/persistwatch
PW_UNIT=/etc/systemd/system/persistwatch.service
MARK="panoptes-managed"

# ------------------------------------------------------------------ arguments
MODE=full; DRY=0; ASSUME_YES=0; OSN=1; OSQ=1; PURGE=0
for a in "$@"; do
    case "$a" in
        --check)         MODE=check ;;
        --uninstall)     MODE=uninstall ;;
        --dry-run)       DRY=1 ;;
        -y|--yes)        ASSUME_YES=1 ;;
        --no-opensnitch) OSN=0 ;;
        --no-osquery)    OSQ=0 ;;
        --purge)         PURGE=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "endpoint-setup.sh: unknown option: $a" >&2; exit 2 ;;
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
run() {
    if [ "$DRY" -eq 1 ]; then printf '  %swould:%s %s\n' "$Y" "$N" "$*"; return 0; fi
    CHANGED=1
    "$@"
}
CURL="curl -fsSL --proto =https --tlsv1.2 --max-time 60"
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# put_file PATH MODE  (content on stdin): byte-compared, so re-runs are silent.
put_file() {
    local path=$1 mode=$2 tmp
    tmp=$(mktemp) || return 1
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; same "$path"; return 0; fi
    if [ "$DRY" -eq 1 ]; then printf '  %swould:%s write %s\n' "$Y" "$N" "$path"; rm -f "$tmp"; return 0; fi
    $SUDO install -D -m "$mode" "$tmp" "$path" && { ok "$path"; CHANGED=1; }
    rm -f "$tmp"
}

# ------------------------------------------------------------------ detection
FAMILY=unknown; PRETTY=unknown; DISTRO_ID=unknown
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"; DISTRO_ID="${ID:-unknown}"
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
RUN_USER="${SUDO_USER:-$(id -un)}"; [ "$RUN_USER" = root ] && RUN_USER=""
as_user() { if [ "$(id -u)" -eq 0 ] && [ -n "$RUN_USER" ]; then runuser -u "$RUN_USER" -- "$@"; else "$@"; fi; }

deb_installed()  { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
rpm_installed()  { rpm -q "$1" >/dev/null 2>&1; }
arch_installed() { pacman -Q "$1" >/dev/null 2>&1; }
pkg_installed() { case "$FAMILY" in debian) deb_installed "$1" ;; fedora|suse) rpm_installed "$1" ;; arch) arch_installed "$1" ;; *) return 1 ;; esac; }
missing_of() { local p out=""; for p in $1; do pkg_installed "$p" || out="$out $p"; done; printf '%s' "${out# }"; }
key_fpr_of() { gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'; }
have_opensnitch() { command -v opensnitchd >/dev/null 2>&1; }
have_osquery()    { command -v osqueryi >/dev/null 2>&1 || command -v osqueryd >/dev/null 2>&1; }
unit_state() { printf '%s/%s' "$(systemctl is-active "$1" 2>/dev/null)" "$(systemctl is-enabled "$1" 2>/dev/null)"; }

# Where each piece comes from. Arch ships both in extra. Debian/Ubuntu ship
# OpenSnitch for amd64 and arm64. Fedora and openSUSE package neither, so
# OpenSnitch comes from upstream's signed GitHub release there (see
# install_opensnitch_upstream) and osquery from osquery's own RPM repository,
# which serves x86_64 and aarch64 and works for dnf and zypper alike.
case "$FAMILY" in
    debian) OSN_PKGS="opensnitch python3-opensnitch-ui"; OSQ_PKGS="osquery"; OSN_SOURCE=distro ;;
    fedora) OSN_PKGS="opensnitch opensnitch-ui";         OSQ_PKGS="osquery"; OSN_SOURCE=upstream ;;
    suse)   OSN_PKGS="opensnitch opensnitch-ui";         OSQ_PKGS="osquery"; OSN_SOURCE=upstream ;;
    arch)   OSN_PKGS="opensnitch";                        OSQ_PKGS="osquery"; OSN_SOURCE=distro ;;
    *)      OSN_PKGS=""; OSQ_PKGS=""; OSN_SOURCE=none ;;
esac
ARCH=$(uname -m)   # x86_64 | aarch64 (Asahi, Raspberry Pi, Ampere) | ...
case "$ARCH" in x86_64) DEB_ARCH=amd64 ;; aarch64) DEB_ARCH=arm64 ;; armv7l) DEB_ARCH=armhf ;; *) DEB_ARCH=$ARCH ;; esac

confirm_pm() {
    [ "$ASSUME_YES" -eq 1 ] || [ "$DRY" -eq 1 ] && return 0
    [ "${CONFIRMED:-0}" -eq 1 ] && return 0
    printf 'Run the package manager now? [y/N] '
    local r; read -r r </dev/tty || r=n
    case "$r" in [yY]*) CONFIRMED=1; return 0 ;; *) echo "Nothing installed."; exit 1 ;; esac
}
pm_cmd() {  # the family's non-interactive install command, as an array in PM_CMD
    local dnf=dnf; command -v dnf5 >/dev/null 2>&1 && dnf=dnf5
    case "$FAMILY" in
        debian) PM_CMD=(env DEBIAN_FRONTEND=noninteractive apt-get install -y) ;;
        fedora) PM_CMD=("$dnf" install -y) ;;
        suse)   PM_CMD=(zypper --non-interactive --gpg-auto-import-keys install) ;;
        arch)   PM_CMD=(pacman -S --needed --noconfirm) ;;
        *)      PM_CMD=(false) ;;
    esac
}
pm_install() {  # pm_install "pkg pkg" | pm_install --files /path/a.rpm ...
    local -a pkgs; local files=0
    if [ "$1" = --files ]; then shift; pkgs=("$@"); files=1
    else
        local m; m=$(missing_of "$1")
        if [ -z "$m" ]; then same "packages: $1"; return 0; fi
        read -r -a pkgs <<<"$m"
    fi
    say "Installing: ${pkgs[*]##*/}"; confirm_pm
    if [ "$FAMILY" = debian ] && [ "${NEED_REFRESH:-0}" -eq 1 ]; then run $SUDO apt-get update -qq || die "apt-get update failed"; NEED_REFRESH=0; fi
    [ "$FAMILY" = suse ] && [ "${NEED_REFRESH:-0}" -eq 1 ] && { run $SUDO zypper --non-interactive --gpg-auto-import-keys refresh >/dev/null || die "zypper refresh failed"; NEED_REFRESH=0; }
    pm_cmd
    # --files are only ever passed after their SHA-512 matched a signed checksum
    # list; upstream does not sign the RPMs themselves, so a hardened
    # localpkg_gpgcheck=1 would refuse them. Scoped to this one transaction.
    [ "$FAMILY" = fedora ] && [ "$files" -eq 1 ] && PM_CMD+=(--setopt=localpkg_gpgcheck=0)
    run $SUDO "${PM_CMD[@]}" "${pkgs[@]}" || die "package install failed"
    [ "$DRY" -eq 1 ] || ok "installed"
}

# ------------------------------------------------------------------ OpenSnitch
# Rules the suite needs so its own daemons and probes are never blocked or
# left waiting on a dialog. "always", by process path, destination-pinned
# where the process is a general tool (ping, curl). Each file carries the
# marker in its name; nothing else in the rules directory is ours.
osn_rule() {  # osn_rule NAME JSON-OPERATOR
    put_file "$OSN_RULES/000-$MARK-$1.json" 0644 <<RULE
{
    "created": "2026-10-27T00:00:00Z",
    "updated": "2026-10-27T00:00:00Z",
    "name": "000-$MARK-$1",
    "enabled": true,
    "precedence": true,
    "action": "allow",
    "duration": "always",
    "operator": $2
}
RULE
}
simple_op() { printf '{"type": "simple", "sensitive": false, "operand": "process.path", "data": "%s", "list": []}' "$1"; }
list_op() {   # list_op PROCESS-PATH OPERAND REGEXP
    printf '{"type": "list", "operand": "list", "sensitive": false, "data": "", "list": [
        {"type": "simple", "sensitive": false, "operand": "process.path", "data": "%s", "list": []},
        {"type": "regexp", "sensitive": false, "operand": "%s", "data": "%s", "list": []}
    ]}' "$1" "$2" "$3"
}
seed_opensnitch_rules() {
    say "OpenSnitch rules for the suite's own traffic"
    osn_rule systemd-resolved "$(simple_op /usr/lib/systemd/systemd-resolved)"
    osn_rule networkmanager   "$(simple_op /usr/sbin/NetworkManager)"
    command -v warp-svc >/dev/null 2>&1 && osn_rule warp-svc "$(simple_op "$(command -v warp-svc)")"
    # the kill-switch's raw-IP probes and portal checks (root, from the watchdog)
    osn_rule watchdog-ping "$(list_op "$(command -v ping || echo /usr/bin/ping)" dest.ip '^(1\\.1\\.1\\.1|8\\.8\\.8\\.8|9\\.9\\.9\\.9)$')"
    osn_rule watchdog-curl "$(list_op /usr/bin/curl dest.host '^(detectportal\\.firefox\\.com|connectivitycheck\\.gstatic\\.com|www\\.cloudflare\\.com)$')"
}
# OpenSnitch from upstream's signed release, for distributions that do not
# package it. Only ever installs; an installed OpenSnitch is left as it is.
install_opensnitch_upstream() {
    if have_opensnitch && pkg_installed "${OSN_PKGS%% *}"; then same "OpenSnitch (upstream release)"; return 0; fi
    say "OpenSnitch from upstream's signed release (no $FAMILY package exists)"
    if [ "$DRY" -eq 1 ]; then
        printf '  %swould:%s fetch the latest release, verify readme.txt.asc against %s, check SHA-512, install the %s packages\n' "$Y" "$N" "$OSN_KEY_FPR" "$ARCH"
        return 0
    fi
    command -v gpg >/dev/null 2>&1 || die "gpg is needed to verify the release signature"
    TMP=${TMP:-$(mktemp -d)}
    local tag ver base
    tag=$($CURL "$OSN_API" | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')
    [ -n "$tag" ] || die "could not read the latest release tag from GitHub"
    ver=${tag#v}; base="$OSN_RELEASES/download/$tag"
    $CURL -o "$TMP/osn_key.asc" "$base/gustavo_iniguez_goia.asc" || die "could not fetch the maintainer key from the release"
    local fpr; fpr=$(key_fpr_of "$TMP/osn_key.asc")
    [ "$fpr" = "$OSN_KEY_FPR" ] || die "release key fingerprint is $fpr, expected $OSN_KEY_FPR — refusing"
    gpg --batch --quiet --no-default-keyring --keyring "$TMP/osn.gpg" --import "$TMP/osn_key.asc" 2>/dev/null || die "could not import the key"
    $CURL -o "$TMP/readme.txt.asc" "$base/readme.txt.asc" || die "could not fetch readme.txt.asc"
    gpg --batch --quiet --no-default-keyring --keyring "$TMP/osn.gpg" --status-file "$TMP/status" \
        --output "$TMP/readme.txt" --decrypt "$TMP/readme.txt.asc" >/dev/null 2>&1
    grep -qE "^\[GNUPG:\] VALIDSIG .* $OSN_KEY_FPR\$" "$TMP/status" || die "readme.txt.asc is not signed by the pinned key — refusing"
    ok "release $tag: signature verified"
    local -a names files=()
    local rpm_arch=$ARCH; [ "$ARCH" = armv7l ] && rpm_arch=armv7hnl
    case "$FAMILY" in
        debian) names=("opensnitch_${ver}-1_${DEB_ARCH}.deb" "python3-opensnitch-ui_${ver}-1_all.deb") ;;
        *)      names=("opensnitch-${ver}-1.${rpm_arch}.rpm" "opensnitch-ui-${ver}-1.noarch.rpm") ;;
    esac
    local n want got
    for n in "${names[@]}"; do
        want=$(awk -v f="$n" 'length($1)==128 && $2 ~ ("(^|/)" f "$") {print $1; exit}' "$TMP/readme.txt")
        [ -n "$want" ] || die "no SHA-512 for $n in the signed readme (no $ARCH build in this release?)"
        $CURL -o "$TMP/$n" "$base/$n" || die "could not fetch $n"
        got=$(sha512sum "$TMP/$n" | cut -c1-128)
        [ "$got" = "$want" ] || die "$n: checksum mismatch — refusing"
        files+=("$TMP/$n")
    done
    ok "${#names[@]} package(s) match the signed checksums"
    pm_install --files "${files[@]}"
}

install_opensnitch() {
    # Debian family without a candidate (an old release, or a port without it) falls back to upstream.
    if [ "$OSN_SOURCE" = distro ] && [ "$FAMILY" = debian ] && ! deb_installed opensnitch \
        && apt-cache policy opensnitch 2>/dev/null | grep -q 'Candidate: (none)'; then OSN_SOURCE=upstream; fi
    case "$OSN_SOURCE" in
        distro)   pm_install "$OSN_PKGS" ;;
        upstream) install_opensnitch_upstream || return 1 ;;
        *)        warn "OpenSnitch: no package known for $FAMILY — see $OSN_RELEASES"; return 1 ;;
    esac
    [ "$DRY" -eq 1 ] && [ ! -d "$OSN_RULES" ] && { printf '  %swould:%s seed rules under %s\n' "$Y" "$N" "$OSN_RULES"; }
    run $SUDO install -d -m 0755 "$OSN_RULES" >/dev/null 2>&1
    seed_opensnitch_rules
    if [ "$(unit_state opensnitch)" = "active/enabled" ]; then same "opensnitch.service enabled and running"
    else run $SUDO systemctl enable --now opensnitch >/dev/null 2>&1 && ok "opensnitch.service enabled and started" || warn "could not enable opensnitch.service"; fi
    # The prompt UI must run in the session or the daemon falls back to its
    # default action. Ubuntu's package ships no autostart entry; upstream's does.
    if [ -n "$RUN_USER" ] && [ ! -f "$OSN_UI_AUTOSTART" ]; then
        local home; home=$(getent passwd "$RUN_USER" | cut -d: -f6)
        local f="$home/.config/autostart/opensnitch_ui.desktop"
        local content
        content=$(printf '[Desktop Entry]\nType=Application\nName=OpenSnitch\nComment=Outbound application firewall prompts (Panoptes endpoint component)\nExec=opensnitch-ui\nIcon=opensnitch-ui\nTerminal=false\nX-GNOME-Autostart-enabled=true\n')
        if [ -f "$f" ] && [ "$(cat "$f")" = "$content" ]; then same "$f"
        elif [ "$DRY" -eq 1 ]; then printf '  %swould:%s write %s\n' "$Y" "$N" "$f"
        else as_user install -d -m 0755 "$home/.config/autostart"
             printf '%s\n' "$content" | as_user tee "$f" >/dev/null && { ok "$f"; CHANGED=1; }
        fi
        # Start it now for this session if it is not running. Under sudo the
        # user's DISPLAY is gone (env_reset), so find the session's X display
        # and bus the way the kill-switch's notifier does.
        if [ "$DRY" -eq 0 ] && ! pgrep -u "$RUN_USER" -f opensnitch-ui >/dev/null 2>&1; then
            local uid disp sock
            uid=$(id -u "$RUN_USER" 2>/dev/null)
            disp="${DISPLAY:-}"
            if [ -z "$disp" ]; then
                for sock in /tmp/.X11-unix/X*; do [ -S "$sock" ] && { disp=":${sock##*/X}"; break; }; done
            fi
            if [ -n "$disp" ] && [ -S "/run/user/$uid/bus" ]; then
                as_user env DISPLAY="$disp" XDG_RUNTIME_DIR="/run/user/$uid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                    sh -c 'setsid -f opensnitch-ui >/dev/null 2>&1' && ok "opensnitch-ui started for $RUN_USER on $disp"
            else
                warn "no graphical session found for $RUN_USER — opensnitch-ui starts at next login"
            fi
        fi
    fi
    return 0
}

# ------------------------------------------------------------------ osquery
osq_repo_debian() {
    local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo "$DEB_ARCH")
    if [ -f "$OSQ_DEB_KEYRING" ] && [ "$(key_fpr_of "$OSQ_DEB_KEYRING")" = "$OSQ_KEY_FPR" ]; then same "$OSQ_DEB_KEYRING (fingerprint matches)"
    else
        say "Adding osquery's APT repository (key pinned)"
        if [ "$DRY" -eq 1 ]; then printf '  %swould:%s fetch %s, verify %s, install to %s\n' "$Y" "$N" "$OSQ_DEB_KEY_URL" "$OSQ_KEY_FPR" "$OSQ_DEB_KEYRING"
        else
            TMP=${TMP:-$(mktemp -d)}
            $CURL -o "$TMP/osq.asc" "$OSQ_DEB_KEY_URL" || die "could not fetch $OSQ_DEB_KEY_URL"
            local fpr; fpr=$(key_fpr_of "$TMP/osq.asc")
            [ "$fpr" = "$OSQ_KEY_FPR" ] || die "osquery's key fingerprint is $fpr, expected $OSQ_KEY_FPR — refusing"
            run $SUDO install -D -m 0644 "$TMP/osq.asc" "$OSQ_DEB_KEYRING" && ok "$OSQ_DEB_KEYRING"
        fi
    fi
    put_file "$OSQ_DEB_LIST" 0644 <<LIST
# Installed by Panoptes endpoint-setup.sh. Key pinned to $OSQ_KEY_FPR.
deb [arch=$arch signed-by=$OSQ_DEB_KEYRING] https://pkg.osquery.io/deb deb main
LIST
    [ "$CHANGED" -eq 1 ] && NEED_REFRESH=1
    return 0
}
osq_repo_fedora() {
    local keyid; keyid=$(printf '%s' "$OSQ_KEY_FPR" | tail -c 8 | tr 'A-F' 'a-f')
    if [ -f "$OSQ_RPM_KEYFILE" ] && [ "$(key_fpr_of "$OSQ_RPM_KEYFILE")" = "$OSQ_KEY_FPR" ] && rpm -q "gpg-pubkey-$keyid" >/dev/null 2>&1; then
        same "osquery signing key imported"
    else
        say "Importing osquery's RPM signing key (pinned)"
        if [ "$DRY" -eq 1 ]; then printf '  %swould:%s fetch %s, verify %s, rpm --import\n' "$Y" "$N" "$OSQ_RPM_KEY_URL" "$OSQ_KEY_FPR"
        else
            TMP=${TMP:-$(mktemp -d)}
            $CURL -o "$TMP/osq.gpg" "$OSQ_RPM_KEY_URL" || die "could not fetch $OSQ_RPM_KEY_URL"
            local fpr; fpr=$(key_fpr_of "$TMP/osq.gpg")
            [ "$fpr" = "$OSQ_KEY_FPR" ] || die "osquery's key fingerprint is $fpr, expected $OSQ_KEY_FPR — refusing"
            run $SUDO install -D -m 0644 "$TMP/osq.gpg" "$OSQ_RPM_KEYFILE"
            run $SUDO rpm --import "$OSQ_RPM_KEYFILE" || die "rpm --import failed"
            ok "key imported"
        fi
    fi
    put_file "$OSQ_RPM_REPO" 0644 <<REPO
# Installed by Panoptes endpoint-setup.sh (osquery's own repo file, key pinned to $OSQ_KEY_FPR).
[osquery-s3-rpm-repo]
name=osquery RPM repository - \$basearch
baseurl=https://pkg.osquerypackages.com/rpm/\$basearch/
enabled=1
gpgkey=file://$OSQ_RPM_KEYFILE
gpgcheck=1
REPO
}

# The persistence pack. Differential by default: osqueryd logs a row the first
# time it sees it and again when it disappears, which is exactly what
# persistwatch turns into a notification.
write_osquery_pack() {
    put_file "$OSQ_PACK" 0644 <<'PACK'
{
  "platform": "linux",
  "queries": {
    "systemd_units_admin": {
      "query": "SELECT id, description, fragment_path, active_state, sub_state FROM systemd_units WHERE fragment_path LIKE '/etc/systemd/%' OR fragment_path LIKE '/usr/local/%' OR fragment_path LIKE '/home/%' OR fragment_path LIKE '/root/%' OR fragment_path LIKE '/run/%';",
      "interval": 300, "description": "systemd units outside the distribution's own directories"
    },
    "crontab": {
      "query": "SELECT event, minute, hour, day_of_month, month, day_of_week, command, path FROM crontab;",
      "interval": 300, "description": "every cron entry, system and per-user"
    },
    "startup_items": {
      "query": "SELECT name, path, args, source, status, username FROM startup_items WHERE type = 'Startup Item';",
      "interval": 300, "description": "XDG autostart entries and init.d scripts (osquery also lists every systemd unit and mount under this table; those are covered by systemd_units_admin)"
    },
    "kernel_modules": {
      "query": "SELECT name, size, used_by, status FROM kernel_modules;",
      "interval": 300, "description": "loaded kernel modules"
    },
    "authorized_keys": {
      "query": "SELECT u.username, u.directory, k.algorithm, k.key_file, k.options, k.comment FROM users u JOIN authorized_keys k USING (uid);",
      "interval": 300, "description": "SSH keys that can log in"
    },
    "sudoers": {
      "query": "SELECT source, header, rule_details FROM sudoers;",
      "interval": 300, "description": "every sudoers rule, including sudoers.d"
    },
    "suid_bin": {
      "query": "SELECT path, username, groupname, permissions FROM suid_bin;",
      "interval": 600, "description": "setuid and setgid binaries"
    },
    "listening_ports": {
      "query": "SELECT lp.pid, lp.port, lp.protocol, lp.address, p.name, p.path, p.cmdline FROM listening_ports lp JOIN processes p USING (pid) WHERE lp.port != 0 AND lp.address NOT IN ('127.0.0.1', '::1');",
      "interval": 300, "description": "network-exposed listeners and the process behind each"
    },
    "deleted_binaries": {
      "query": "SELECT p.pid, p.name, p.path, p.cmdline, p.uid FROM processes p LEFT JOIN file f ON f.path = p.path WHERE p.on_disk = 0 AND p.path != '' AND f.path IS NULL;",
      "interval": 300, "description": "running processes whose executable is gone from disk (a binary merely replaced by an upgrade still exists at its path and is not listed)"
    },
    "hook_files": {
      "query": "SELECT f.path, f.mtime, h.sha256 FROM file f JOIN hash h USING (path) WHERE f.path IN ('/etc/profile', '/etc/bash.bashrc', '/etc/bashrc', '/etc/zsh/zshrc', '/etc/zshrc', '/etc/ld.so.preload', '/etc/rc.local', '/etc/environment');",
      "interval": 600, "description": "system shell and loader hook files, by hash"
    },
    "hook_dirs": {
      "query": "SELECT f.path, f.mtime, h.sha256 FROM file f JOIN hash h USING (path) WHERE f.directory IN ('/etc/profile.d', '/etc/cron.d', '/etc/udev/rules.d', '/etc/sudoers.d', '/etc/NetworkManager/dispatcher.d', '/etc/systemd/system-sleep', '/etc/xdg/autostart', '/etc/apt/sources.list.d', '/etc/yum.repos.d', '/etc/apt/keyrings', '/etc/ld.so.conf.d');",
      "interval": 600, "description": "drop-in directories that run code or add trust, by hash"
    },
    "user_hooks": {
      "query": "SELECT f.path, f.mtime, h.sha256 FROM file f JOIN hash h USING (path) WHERE f.path LIKE '/home/%/.bashrc' OR f.path LIKE '/home/%/.bash_profile' OR f.path LIKE '/home/%/.profile' OR f.path LIKE '/home/%/.zshrc' OR f.path LIKE '/home/%/.zshenv' OR f.path LIKE '/home/%/.config/autostart/%' OR f.path LIKE '/home/%/.config/systemd/user/%' OR f.path LIKE '/root/.bashrc' OR f.path LIKE '/root/.profile';",
      "interval": 600, "description": "per-user shell, autostart and user-unit hooks, by hash"
    },
    "users": {
      "query": "SELECT uid, gid, username, shell, directory FROM users WHERE uid = 0 OR uid >= 1000;",
      "interval": 600, "description": "root and human accounts"
    }
  }
}
PACK
}
# Only runtime options go in the config: logger_plugin and logger_path are
# CLI-only flags (osqueryi warns if they are set here), and the suite wants
# their defaults anyway — the filesystem logger under /var/log/osquery.
write_osquery_conf() {
    local content
    content=$(cat <<CONF
{
  "_comment": "$MARK: written by Panoptes endpoint-setup.sh; a copy is kept at $OSQ_CONF_COPY so a hand-edited file is left alone",
  "options": {
    "schedule_splay_percent": "10"
  },
  "packs": {
    "panoptes-persistence": "$OSQ_PACK"
  }
}
CONF
)
    if [ -f "$OSQ_CONF" ]; then
        if [ -f "$OSQ_CONF_COPY" ] && cmp -s "$OSQ_CONF" "$OSQ_CONF_COPY"; then
            : # ours, last version — put_file below decides whether it changed
        elif [ -f "$OSQ_CONF_COPY" ]; then
            warn "$OSQ_CONF was edited since Panoptes wrote it — leaving it alone. Make sure it still loads the pack:"
            warn "  \"packs\": { \"panoptes-persistence\": \"$OSQ_PACK\" }"
            return 0
        else
            warn "$OSQ_CONF exists and is not Panoptes' — leaving it alone. Add the pack to it:"
            warn "  \"packs\": { \"panoptes-persistence\": \"$OSQ_PACK\" }"
            return 0
        fi
    fi
    printf '%s\n' "$content" | put_file "$OSQ_CONF" 0644
    printf '%s\n' "$content" | put_file "$OSQ_CONF_COPY" 0644 >/dev/null
}
install_osquery() {
    case "$FAMILY" in
        debian)      osq_repo_debian; pm_install "$OSQ_PKGS" ;;
        fedora|suse) osq_repo_fedora; [ "$FAMILY" = suse ] && [ "$CHANGED" -eq 1 ] && NEED_REFRESH=1; pm_install "$OSQ_PKGS" ;;
        arch)        pm_install "$OSQ_PKGS" ;;
        *)           warn "osquery: no package known for $FAMILY — see https://osquery.io/downloads"; return 1 ;;
    esac
    [ "$DRY" -eq 0 ] && ! have_osquery && { warn "osquery did not install"; return 1; }
    say "osquery persistence pack"
    run $SUDO install -d -m 0755 /etc/osquery/packs "$OSQ_LOG_DIR" >/dev/null 2>&1
    write_osquery_pack
    write_osquery_conf
    if [ "$(unit_state osqueryd)" = "active/enabled" ]; then same "osqueryd.service enabled and running"
    else run $SUDO systemctl enable --now osqueryd >/dev/null 2>&1 && ok "osqueryd.service enabled and started" || warn "could not enable osqueryd.service"; fi
    # persistwatch: the BlockBlock half — notify on new rows from the pack.
    if [ -x "$PW_BIN" ]; then
        put_file "$PW_UNIT" 0644 <<UNIT
[Unit]
Description=Panoptes persistence watch (osquery results -> desktop notifications)
Documentation=file:$PW_BIN
After=osqueryd.service
Wants=osqueryd.service

[Service]
Type=simple
ExecStart=$PW_BIN
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
UNIT
        [ "$DRY" -eq 0 ] && $SUDO systemctl daemon-reload >/dev/null 2>&1
        if [ "$(unit_state persistwatch)" = "active/enabled" ]; then same "persistwatch.service enabled and running"
        else run $SUDO systemctl enable --now persistwatch >/dev/null 2>&1 && ok "persistwatch.service enabled and started" || warn "could not enable persistwatch.service"; fi
    else
        warn "$PW_BIN is not installed (run Panoptes install.sh); persistwatch.service not written"
    fi
    return 0
}

# ------------------------------------------------------------------ report
report() {
    say "Endpoint component"
    printf '  %-14s %s\n' "system" "$PRETTY ${D}(id=$DISTRO_ID family=$FAMILY arch=$ARCH)${N}"
    local short=0 n
    if [ "$OSN" -eq 1 ]; then
        if have_opensnitch; then
            ok "OpenSnitch    $(opensnitchd -version 2>/dev/null | head -1 || echo installed)   service $(unit_state opensnitch)"
            n=$(find "$OSN_RULES" -maxdepth 1 -name "000-$MARK-*.json" 2>/dev/null | wc -l)
            printf '  %-14s %s\n' "rules" "$n suite rule(s) in $OSN_RULES"
            if [ -n "$RUN_USER" ]; then
                as_user pgrep -u "$RUN_USER" -f opensnitch-ui >/dev/null 2>&1 && ok "opensnitch-ui running for $RUN_USER" || warn "opensnitch-ui not running for $RUN_USER — prompts fall back to the daemon's default action (allow)"
            fi
        else warn "OpenSnitch    not installed"; short=1; fi
    fi
    if [ "$OSQ" -eq 1 ]; then
        if have_osquery; then
            ok "osquery       $(osqueryi --version 2>/dev/null | awk '{print $NF}')   osqueryd $(unit_state osqueryd)"
            [ -f "$OSQ_PACK" ] && ok "pack          $OSQ_PACK" || { warn "pack          missing"; short=1; }
            if [ -f "$OSQ_CONF" ]; then
                if [ -f "$OSQ_CONF_COPY" ] && cmp -s "$OSQ_CONF" "$OSQ_CONF_COPY"; then ok "config        $OSQ_CONF (Panoptes)"
                elif grep -q "panoptes-persistence" "$OSQ_CONF" 2>/dev/null; then ok "config        $OSQ_CONF (yours, loads the pack)"
                else warn "config        $OSQ_CONF (yours) does not load the pack"; short=1; fi
            else warn "config        missing"; short=1; fi
            printf '  %-14s %s\n' "persistwatch" "$(unit_state persistwatch)"
            [ -f "$OSQ_LOG_DIR/osqueryd.results.log" ] && printf '  %-14s %s rows logged\n' "results" "$(wc -l < "$OSQ_LOG_DIR/osqueryd.results.log" 2>/dev/null || echo '?')"
        else warn "osquery       not installed"; short=1; fi
    fi
    echo
    echo "  On demand:  persistcheck          (what is persistent now, and what changed since last time)"
    echo "  Live:       persistwatch.service  (a notification when a new row appears)"
    echo "  OpenSnitch will ask about the suite's own probes (nmap, arp-scan, tcpdump…) once each; allow them."
    return $short
}

# ------------------------------------------------------------------ uninstall
do_uninstall() {
    report; echo
    say "Removing the suite's endpoint pieces${PURGE:+}$([ "$PURGE" -eq 1 ] && echo ' and the packages')"
    if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY" -eq 0 ]; then
        printf 'Continue? [y/N] '; local r; read -r r </dev/tty || r=n
        case "$r" in [yY]*) ;; *) echo "Nothing removed."; exit 1 ;; esac
    fi
    run $SUDO systemctl disable --now persistwatch >/dev/null 2>&1
    local f
    for f in "$PW_UNIT" "$OSQ_PACK" "$OSN_RULES"/000-"$MARK"-*.json; do
        [ -e "$f" ] || continue
        run $SUDO rm -f "$f" && [ "$DRY" -eq 0 ] && echo "  - $f"
    done
    if [ -f "$OSQ_CONF" ] && [ -f "$OSQ_CONF_COPY" ] && cmp -s "$OSQ_CONF" "$OSQ_CONF_COPY"; then
        run $SUDO rm -f "$OSQ_CONF" "$OSQ_CONF_COPY" && [ "$DRY" -eq 0 ] && echo "  - $OSQ_CONF (Panoptes')"
    else
        [ -f "$OSQ_CONF" ] && echo "  left $OSQ_CONF alone — it is not the file Panoptes wrote"
        run $SUDO rm -f "$OSQ_CONF_COPY"
    fi
    [ "$DRY" -eq 0 ] && $SUDO systemctl daemon-reload >/dev/null 2>&1
    if [ "$PURGE" -eq 1 ]; then
        run $SUDO systemctl disable --now osqueryd opensnitch >/dev/null 2>&1
        local -a pk; read -r -a pk <<<"$OSN_PKGS $OSQ_PKGS"
        local dnf=dnf; command -v dnf5 >/dev/null 2>&1 && dnf=dnf5
        case "$FAMILY" in
            debian) run $SUDO apt-get purge -y "${pk[@]}"; run $SUDO rm -f "$OSQ_DEB_LIST" "$OSQ_DEB_KEYRING" ;;
            fedora) run $SUDO "$dnf" remove -y "${pk[@]}"; run $SUDO rm -f "$OSQ_RPM_REPO" "$OSQ_RPM_KEYFILE" ;;
            suse)   run $SUDO zypper --non-interactive remove "${pk[@]}"; run $SUDO rm -f "$OSQ_RPM_REPO" "$OSQ_RPM_KEYFILE" ;;
            arch)   run $SUDO pacman -Rns --noconfirm "${pk[@]}" ;;
        esac
    else
        echo "  OpenSnitch and osquery themselves were left installed and running (their own rules and"
        echo "  logs are yours). Re-run with --purge to remove the packages and osquery's repository."
    fi
    local home
    [ -n "$RUN_USER" ] && home=$(getent passwd "$RUN_USER" | cut -d: -f6) && [ -f "$home/.config/autostart/opensnitch_ui.desktop" ] \
        && grep -q 'Panoptes endpoint component' "$home/.config/autostart/opensnitch_ui.desktop" \
        && run as_user rm -f "$home/.config/autostart/opensnitch_ui.desktop"
    echo "Done."
}

# ------------------------------------------------------------------ main
case "$MODE" in
    check)     report; exit $? ;;
    uninstall) do_uninstall; exit 0 ;;
esac
NEED_REFRESH=0
[ "$OSN" -eq 1 ] && install_opensnitch
[ "$OSQ" -eq 1 ] && install_osquery
echo; report || true; echo
if [ "$DRY" -eq 1 ]; then echo "(--dry-run: nothing was changed)"
elif [ "$CHANGED" -eq 0 ]; then printf '%sNothing changed — already in the desired state.%s\n' "$G" "$N"
else printf '%sDone.%s\n' "$G" "$N"; fi
