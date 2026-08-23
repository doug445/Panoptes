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
# ech-browsers.sh — find every browser on this machine and turn on Encrypted
# Client Hello wherever the engine can do it.
#
# ECH hides the server name from anyone watching your TLS handshakes. It only
# engages when the browser fetches the site's HTTPS DNS record over a secure
# channel, so this enables DNS-over-HTTPS in the same pass. Enabling ECH without
# secure DNS does nothing at all — the pair is not optional.
#
# Firefox-family profiles are configured through user.js, which is re-applied at
# every startup, so the settings survive a preferences reset. Chromium-family
# profiles are configured through the "Local State" JSON, which the browser
# rewrites when it exits — so those browsers must be closed first.
#
# Usage:
#        ./ech-browsers.sh              detect, then apply after confirming
#        ./ech-browsers.sh --yes        apply without asking
#        ./ech-browsers.sh --list       detect and report only, change nothing
#        ./ech-browsers.sh --dry-run    show every change, write nothing
#        ./ech-browsers.sh --revert     undo everything this script set
#        ./ech-browsers.sh --no-doh     ECH prefs only, leave the resolver alone
#        ./ech-browsers.sh --doh-url URL --bootstrap IP
#
# Tor Browser and Mullvad Browser are never touched. They resolve names through
# their proxy circuit on purpose; pointing them at a DoH resolver would send
# your lookups around it. That is a deanonymisation bug, not a hardening step.
#
# Verify afterwards at https://defo.ie/ech-check.php

set -uo pipefail
LC_ALL=C

usage() { sed -n '/^# ech-browsers\.sh —/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \?//'; }

DOH_URL="${DOH_URL:-https://cloudflare-dns.com/dns-query}"
DOH_BOOTSTRAP="${DOH_BOOTSTRAP:-162.159.36.1}"
# Chromium's Cloudflare endpoint is a different hostname from Firefox's.
CHROME_DOH_URL=""
STAMP=$(date +%Y%m%d%H%M%S)
MARK_OPEN="// >>> Panoptes ECH block — managed by ech-browsers.sh"
MARK_CLOSE="// <<< Panoptes ECH block"

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[0;33m'; C=$'\e[0;94m'; D=$'\e[0;90m'; N=$'\e[0m'
else B=; R=; G=; Y=; C=; D=; N=; fi

ok()   { printf '    %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '    %s✗%s %s\n' "$R" "$N" "$*"; }
info() { printf '    %s%s%s\n' "$D" "$*" "$N"; }

MODE=apply; ASSUME_YES=0; DRY=0; NO_DOH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)      MODE=list ;;
        --revert)    MODE=revert ;;
        --dry-run)   DRY=1 ;;
        -y|--yes)    ASSUME_YES=1 ;;
        --no-doh)    NO_DOH=1 ;;
        --doh-url)   shift; [ $# -gt 0 ] || { echo "--doh-url needs a URL" >&2; exit 2; }; DOH_URL=$1 ;;
        --doh-url=*) DOH_URL=${1#--doh-url=} ;;
        --bootstrap) shift; [ $# -gt 0 ] || { echo "--bootstrap needs an IP" >&2; exit 2; }; DOH_BOOTSTRAP=$1 ;;
        --bootstrap=*) DOH_BOOTSTRAP=${1#--bootstrap=} ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "ech-browsers.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$DOH_URL" in
    https://*) ;;
    *) echo "--doh-url must be an https:// URL, got: $DOH_URL" >&2; exit 2 ;;
esac
if [ "$DOH_URL" = "https://cloudflare-dns.com/dns-query" ]; then
    CHROME_DOH_URL="https://chrome.cloudflare-dns.com/dns-query"
else
    CHROME_DOH_URL="$DOH_URL"
fi

command -v python3 >/dev/null 2>&1 || PY_MISSING=1

# Browser profiles live in a person's home directory, so this tool needs no
# privileges at all. Run under sudo it would find root's (empty) home and
# silently configure nothing, which looks exactly like success.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    echo "ech-browsers.sh configures browser profiles in your home directory." >&2
    echo "Run it as yourself, without sudo:  ech-browsers.sh" >&2
    exit 2
fi

# ---------------------------------------------------------------- the browsers
#
# label | engine | profile root, relative to $HOME
#
# A root is only a candidate. It counts as installed when it exists and holds a
# profile — a browser you removed leaves its config directory behind.
#
BROWSERS=$(cat <<'TABLE'
Firefox|gecko|.mozilla/firefox
Firefox (Flatpak)|gecko|.var/app/org.mozilla.firefox/.mozilla/firefox
Firefox (Snap)|gecko|snap/firefox/common/.mozilla/firefox
LibreWolf|gecko|.librewolf
LibreWolf (Flatpak)|gecko|.var/app/io.gitlab.librewolf-community/.librewolf
Waterfox|gecko|.waterfox
Floorp|gecko|.floorp
Floorp (Flatpak)|gecko|.var/app/one.ablaze.floorp/.floorp
Zen|gecko|.zen
Zen (Flatpak)|gecko|.var/app/app.zen_browser.zen/.zen
Chromium|chromium|.config/chromium
Chromium (Flatpak)|chromium|.var/app/org.chromium.Chromium/config/chromium
Ungoogled Chromium (Flatpak)|chromium|.var/app/io.github.ungoogled_software.ungoogled_chromium/config/chromium
Google Chrome|chromium|.config/google-chrome
Google Chrome (Flatpak)|chromium|.var/app/com.google.Chrome/config/google-chrome
Brave|chromium|.config/BraveSoftware/Brave-Browser
Brave (Flatpak)|chromium|.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser
Brave (Snap)|chromium|snap/brave/current/.config/BraveSoftware/Brave-Browser
Vivaldi|chromium|.config/vivaldi
Vivaldi (Flatpak)|chromium|.var/app/com.vivaldi.Vivaldi/config/vivaldi
Microsoft Edge|chromium|.config/microsoft-edge
Opera|chromium|.config/opera
Thorium|chromium|.config/thorium
TABLE
)

# Proxy-routed browsers. Present so the report accounts for them, never edited.
SKIP_ROOTS=$(cat <<'TABLE'
Tor Browser|tor-browser/Browser/TorBrowser/Data/Browser
Tor Browser (Flatpak)|.var/app/org.torproject.torbrowser-launcher/.local/share/torbrowser
Mullvad Browser|.mullvad-browser
Mullvad Browser (Flatpak)|.var/app/net.mullvad.MullvadBrowser/.mullvad-browser
TABLE
)

# ------------------------------------------------------------------- utilities
installed() {  # $1 = profile root. Is the app that owns it actually still here?
    local id
    case "$1" in
        */.var/app/*)
            command -v flatpak >/dev/null 2>&1 || return 1
            id=${1#*/.var/app/}; id=${id%%/*}
            flatpak info "$id" >/dev/null 2>&1 ;;
        */snap/*)
            command -v snap >/dev/null 2>&1 || return 1
            id=${1#*/snap/}; id=${id%%/*}
            snap list "$id" >/dev/null 2>&1 ;;
        *) return 0 ;;   # a native config dir; we cannot tell, so assume it is
    esac
}

gecko_profiles() {  # $1 = root -> one absolute profile path per line
    local root=$1 ini="$1/profiles.ini"
    if [ -r "$ini" ]; then
        awk -v root="$root" '
            /^\[/                 { rel = 1; path = "" }
            /^IsRelative=/        { rel = ($0 ~ /=1$/) }
            /^Path=/              { sub(/^Path=/, ""); path = $0
                                    print (rel ? root "/" path : path) }
        ' "$ini"
    else
        # Some builds ship no profiles.ini until first run; fall back to shape.
        find "$root" -maxdepth 2 -name prefs.js -printf '%h\n' 2>/dev/null
    fi
}

gecko_running() { [ -L "$1/lock" ] || [ -L "$1/.parentlock" ]; }
chromium_running() { [ -e "$1/SingletonLock" ]; }

gecko_version() {
    [ -r "$1/compatibility.ini" ] || return 0
    sed -n 's/^LastVersion=\([0-9.]*\).*/\1/p' "$1/compatibility.ini" | head -1
}
chromium_version() {
    [ -r "$1/Last Version" ] || return 0
    head -1 "$1/Last Version" 2>/dev/null
}

backup() {  # $1 = file
    [ -f "$1" ] || return 0
    [ "$DRY" -eq 1 ] && { info "would back up $(basename "$1")"; return 0; }
    cp -p -- "$1" "$1.panoptes-bak-$STAMP" && info "backed up -> $(basename "$1").panoptes-bak-$STAMP"
}

strip_block() {  # stdin -> stdout, minus any managed block
    awk -v o="$MARK_OPEN" -v c="$MARK_CLOSE" '
        index($0, o) == 1 { s = 1 }
        s == 0            { print }
        index($0, c) == 1 { s = 0 }
    '
}

# ---------------------------------------------------------------------- gecko
gecko_apply() {  # $1 = profile dir
    local prof=$1 uj="$1/user.js" tmp
    if gecko_running "$prof"; then
        warn "running — close it and re-run, or the block lands but is not read until restart"
    fi
    local block
    block="$MARK_OPEN
// placed $(date -Iseconds). Re-running the script replaces this block.
user_pref(\"network.dns.echconfig.enabled\", true);
user_pref(\"network.dns.http3_echconfig.enabled\", true);
user_pref(\"network.dns.upgrade_with_https_rr\", true);
user_pref(\"network.dns.use_https_rr_as_altsvc\", true);"
    if [ "$NO_DOH" -eq 0 ]; then
        # trr.mode 2 = DoH first, system resolver as fallback. Firefox will not
        # use ECH at all with TRR off, so this is what makes the prefs above real.
        block="$block
user_pref(\"network.trr.mode\", 2);
user_pref(\"network.trr.uri\", \"$DOH_URL\");
user_pref(\"network.trr.bootstrapAddress\", \"$DOH_BOOTSTRAP\");"
    fi
    block="$block
$MARK_CLOSE"

    if [ "$DRY" -eq 1 ]; then
        info "would write $(echo "$block" | grep -c user_pref) prefs to $uj"
        return 0
    fi
    backup "$uj"
    tmp=$(mktemp) || { bad "mktemp failed"; return 1; }
    if [ -f "$uj" ]; then strip_block <"$uj" >"$tmp"; fi
    printf '%s\n' "$block" >>"$tmp"
    if mv -- "$tmp" "$uj"; then
        ok "user.js updated"
    else
        rm -f -- "$tmp"; bad "could not write $uj"; return 1
    fi
}

gecko_revert() {
    local prof=$1 uj="$1/user.js" tmp
    [ -f "$uj" ] || { info "no user.js"; return 0; }
    grep -qF "$MARK_OPEN" "$uj" || { info "no managed block"; return 0; }
    [ "$DRY" -eq 1 ] && { info "would remove the managed block from user.js"; return 0; }
    backup "$uj"
    tmp=$(mktemp) || return 1
    strip_block <"$uj" >"$tmp" && mv -- "$tmp" "$uj" && ok "managed block removed"
    info "prefs.js keeps the last values until you reset them in about:config"
}

gecko_state() {  # report what is set now
    local prof=$1 f
    for f in "$prof/user.js" "$prof/prefs.js"; do
        [ -r "$f" ] || continue
        grep -q 'network\.dns\.echconfig\.enabled".*true' "$f" 2>/dev/null && {
            ok "ECH already on in $(basename "$f")"; return 0; }
    done
    return 1
}

# -------------------------------------------------------------------- chromium
chromium_edit() {  # $1 = root, $2 = "apply"|"revert"
    local root=$1 action=$2 ls="$1/Local State"
    if chromium_running "$root"; then
        bad "running — Chromium rewrites Local State on exit and would undo this"
        info "close it completely (check the tray) and run this again"
        return 1
    fi
    if [ -n "${PY_MISSING:-}" ]; then
        bad "python3 is needed to edit Local State safely"
        return 1
    fi
    if [ ! -f "$ls" ]; then
        # Seeding before first launch is legitimate and works.
        [ "$DRY" -eq 1 ] && { info "would create $ls with secure DNS pre-seeded"; return 0; }
        [ "$action" = revert ] && { info "no Local State"; return 0; }
        mkdir -p -- "$root" || return 1
        printf '{}' >"$ls" || return 1
        info "no Local State yet — seeding it for first launch"
    fi
    [ "$DRY" -eq 1 ] && { info "would set dns_over_https.mode=$( [ "$action" = revert ] && echo automatic || echo secure )"; return 0; }
    backup "$ls"
    PANOPTES_LS="$ls" PANOPTES_ACTION="$action" PANOPTES_TPL="$CHROME_DOH_URL" \
    python3 - <<'PY'
import json, os, sys, tempfile
path   = os.environ["PANOPTES_LS"]
action = os.environ["PANOPTES_ACTION"]
tpl    = os.environ["PANOPTES_TPL"]
try:
    with open(path, encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"    could not parse Local State: {exc}", file=sys.stderr)
    sys.exit(1)
if not isinstance(state, dict):
    print("    Local State is not a JSON object", file=sys.stderr)
    sys.exit(1)
doh = state.setdefault("dns_over_https", {})
if action == "revert":
    doh["mode"] = "automatic"
    doh["templates"] = ""
else:
    doh["mode"] = "secure"
    doh["templates"] = tpl
# Write through a temporary file in the same directory so a crash mid-write
# cannot leave the browser with a truncated Local State.
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(state, fh, separators=(",", ":"))
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
print(f"    mode={doh['mode']} templates={doh['templates'] or '(none)'}")
PY
    local rc=$?
    if [ $rc -eq 0 ]; then
        if [ "$action" = revert ]; then ok "secure DNS reverted to automatic"
        else ok "secure DNS set — ECH is on by default in Chromium 117 and later"; fi
    else
        bad "Local State not modified"
    fi
    return $rc
}

# ----------------------------------------------------------------------- sweep
FOUND=0; PLANNED=""
printf '%sBrowsers on this machine%s\n\n' "$B" "$N"

while IFS='|' read -r label engine rel; do
    [ -n "$label" ] || continue
    root="$HOME/$rel"
    [ -d "$root" ] || continue
    if ! installed "$root"; then
        printf '  %s%s%s %s— config left behind, the app is not installed%s\n' \
            "$D" "$label" "$N" "$D" "$N"
        info "$root"
        echo
        continue
    fi

    if [ "$engine" = gecko ]; then
        profiles=$(gecko_profiles "$root")
        [ -n "$profiles" ] || continue
        FOUND=$((FOUND + 1))
        ver=$(gecko_version "$(echo "$profiles" | head -1)")
        printf '  %s%s%s %s(gecko%s)%s\n' "$C" "$label" "$N" "$D" "${ver:+ $ver}" "$N"
        info "$root"
        while read -r prof; do
            [ -d "$prof" ] || continue
            printf '  %s·%s %s\n' "$D" "$N" "$(basename "$prof")"
            gecko_state "$prof" || info "ECH not currently pinned"
            PLANNED="$PLANNED
gecko|$prof|$label"
        done <<<"$profiles"
    else
        [ -f "$root/Local State" ] || [ -d "$root/Default" ] || continue
        FOUND=$((FOUND + 1))
        ver=$(chromium_version "$root")
        printf '  %s%s%s %s(chromium%s)%s\n' "$C" "$label" "$N" "$D" "${ver:+ $ver}" "$N"
        info "$root"
        # Vivaldi and Opera number their own releases (7.x, 120.x), so a low
        # major here means a vendor scheme, not an ancient Chromium. Only judge
        # numbers that are plausibly Chromium's own.
        case "${ver%%.*}" in
            ''|*[!0-9]*) ;;
            *) if [ "${ver%%.*}" -ge 50 ] && [ "${ver%%.*}" -lt 117 ]; then
                   warn "Chromium ${ver%%.*} predates ECH support (needs 117+)"
               fi ;;
        esac
        chromium_running "$root" && warn "currently running"
        PLANNED="$PLANNED
chromium|$root|$label"
    fi
    echo
done <<<"$BROWSERS"

SKIPPED=0
while IFS='|' read -r label rel; do
    [ -n "$label" ] || continue
    [ -d "$HOME/$rel" ] || continue
    SKIPPED=$((SKIPPED + 1))
    printf '  %s%s%s %s— skipped on purpose%s\n' "$Y" "$label" "$N" "$Y" "$N"
    info "resolves through its proxy circuit; DoH here would leak lookups around it"
    echo
done <<<"$SKIP_ROOTS"

if [ "$FOUND" -eq 0 ]; then
    printf '%sNo configurable browser found.%s\n' "$Y" "$N"
    [ "$SKIPPED" -gt 0 ] && printf 'Only proxy-routed browsers are installed, and those are left alone.\n'
    exit 0
fi

[ "$MODE" = list ] && exit 0

# ---------------------------------------------------------------------- action
targets=$(printf '%s\n' "$PLANNED" | grep -cE '^(gecko|chromium)\|')

if [ "$MODE" = revert ]; then
    printf '%sReverting%s in %s profile(s)/browser(s).\n' "$B" "$N" "$targets"
else
    printf '%sPlan%s for %s profile(s)/browser(s):\n' "$B" "$N" "$targets"
    echo "  Firefox family — user.js:"
    echo "      network.dns.echconfig.enabled       true"
    echo "      network.dns.http3_echconfig.enabled true"
    echo "      network.dns.upgrade_with_https_rr   true"
    echo "      network.dns.use_https_rr_as_altsvc  true"
    if [ "$NO_DOH" -eq 0 ]; then
        echo "      network.trr.mode                    2  (DoH first, system fallback)"
        echo "      network.trr.uri                     $DOH_URL"
        echo "      network.trr.bootstrapAddress        $DOH_BOOTSTRAP"
    else
        printf '  %s--no-doh: TRR left alone. Firefox does not use ECH with TRR off,%s\n' "$Y" "$N"
        printf '  %sso this will not actually turn ECH on there.%s\n' "$Y" "$N"
    fi
    echo "  Chromium family — Local State:"
    echo "      dns_over_https.mode                 secure"
    echo "      dns_over_https.templates            $CHROME_DOH_URL"
    echo "      (ECH itself needs no flag from Chromium 117 on)"
fi
echo

if [ "$DRY" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Proceed? [y/N] '
    read -r reply </dev/tty || reply=n
    case "$reply" in [yY]*) ;; *) echo "Nothing changed."; exit 1 ;; esac
    echo
fi

CHANGED=0; FAILED=0
while IFS='|' read -r engine path label; do
    [ -n "$engine" ] || continue
    printf '  %s%s%s %s%s%s\n' "$C" "$label" "$N" "$D" "$(basename "$path")" "$N"
    rc=0
    if [ "$engine" = gecko ]; then
        if [ "$MODE" = revert ]; then gecko_revert "$path" || rc=$?; else gecko_apply "$path" || rc=$?; fi
    else
        if [ "$MODE" = revert ]; then chromium_edit "$path" revert || rc=$?; else chromium_edit "$path" apply || rc=$?; fi
    fi
    if [ "$rc" -eq 0 ]; then CHANGED=$((CHANGED + 1)); else FAILED=$((FAILED + 1)); fi
done <<<"$(printf '%s\n' "$PLANNED" | grep -E '^(gecko|chromium)\|')"

echo
if [ "$DRY" -eq 1 ]; then
    printf '%s--dry-run: nothing was written.%s\n' "$Y" "$N"
    exit 0
fi
printf '%s%d%s done' "$G" "$CHANGED" "$N"
[ "$FAILED" -gt 0 ] && printf ', %s%d skipped or failed%s' "$R" "$FAILED" "$N"
echo
[ "$MODE" = revert ] && exit 0

cat <<NOTES

Restart every browser you just changed, then check one of them at:
    https://defo.ie/ech-check.php

If a Chromium browser shows nothing changed, it was still running when this
ran — it rewrites Local State on exit and overwrote the edit. Quit it fully
(watch for a tray icon) and run this again.

ECH also needs the DNS side to be sane. Run  checkdns  for the resolver and
ECHConfig view, and  ech-build.sh --verify  to confirm the command-line stack.
NOTES
