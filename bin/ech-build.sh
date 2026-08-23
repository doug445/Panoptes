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
# ech-build.sh — build a curl that can actually do Encrypted Client Hello, and
# put it somewhere your distribution's updates will never overwrite.
#
# No mainstream distribution ships an ECH-capable curl, because no released
# OpenSSL implements ECH. This builds Stephen Farrell's OpenSSL ECH branch into
# /opt/openssl-ech (static, self-contained, touching nothing else), then builds
# curl against it into /usr/local. /usr/local is not owned by any package
# manager, so "dnf upgrade" and "apt full-upgrade" leave it alone forever.
#
# Usage:
#        ./ech-build.sh              build and install (asks for sudo at install)
#        ./ech-build.sh --check      report what is installed, build nothing
#        ./ech-build.sh --deps       install the build dependencies and exit
#        ./ech-build.sh --curl-only  rebuild curl against an existing /opt/openssl-ech
#        ./ech-build.sh --full       also enable brotli, zstd, GSSAPI, SSH and LDAP
#        ./ech-build.sh --verify     test the installed curl against a live ECH site
#   sudo ./ech-build.sh --uninstall  remove both, hand curl back to the distribution
#        ./ech-build.sh --jobs N     parallel make jobs (default: all cores)
#
# Overrides: OPENSSL_PREFIX CURL_PREFIX BUILD_DIR OPENSSL_BRANCH CURL_REF
#
# After installing, /usr/local/bin/curl shadows /usr/bin/curl in PATH — including
# for sudo, whose secure_path also starts with /usr/local/bin. The ECH build is
# deliberately minimal; /usr/bin/curl stays installed as the escape hatch.

set -uo pipefail
LC_ALL=C

usage() { sed -n '/^# ech-build\.sh —/,/^[^#]/p' "$0" | sed -e '/^[^#]/d' -e 's/^# \?//'; }

OPENSSL_REPO="${OPENSSL_REPO:-https://github.com/sftcd/openssl.git}"
OPENSSL_BRANCH="${OPENSSL_BRANCH:-ECH-draft-13c}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-/opt/openssl-ech}"
CURL_REPO="${CURL_REPO:-https://github.com/curl/curl.git}"
CURL_REF="${CURL_REF:-master}"
CURL_PREFIX="${CURL_PREFIX:-/usr/local}"
ECH_TEST_HOST="${ECH_TEST_HOST:-defo.ie}"

# Under sudo, $HOME is root's. Build in the invoking user's home instead.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    REAL_HOME="$HOME"
fi
BUILD_DIR="${BUILD_DIR:-$REAL_HOME/build}"

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[0;33m'; D=$'\e[0;90m'; N=$'\e[0m'
else B=; R=; G=; Y=; D=; N=; fi

say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

MODE=build; FULL=0; JOBS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check)     MODE=check ;;
        --deps)      MODE=deps ;;
        --verify)    MODE=verify ;;
        --uninstall) MODE=uninstall ;;
        --curl-only) MODE=curl ;;
        --full)      FULL=1 ;;
        --jobs)      shift; [ $# -gt 0 ] || die "--jobs needs a number"; JOBS=$1 ;;
        --jobs=*)    JOBS=${1#--jobs=} ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
[ -n "$JOBS" ] || JOBS=$(nproc 2>/dev/null || echo 2)
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a number, got: $JOBS" ;; esac

# ---------------------------------------------------------------------- status
curl_has_ech() {  # $1 = path to a curl binary
    [ -x "$1" ] && "$1" -V 2>/dev/null | grep -qw ECH
}

report() {
    say "Current state"
    if [ -x "$OPENSSL_PREFIX/bin/openssl" ]; then
        ok "OpenSSL-ECH  $("$OPENSSL_PREFIX/bin/openssl" version 2>/dev/null) ${D}($OPENSSL_PREFIX)${N}"
    else
        warn "OpenSSL-ECH  not installed at $OPENSSL_PREFIX"
    fi
    if curl_has_ech "$CURL_PREFIX/bin/curl"; then
        ok "curl (ECH)   $("$CURL_PREFIX/bin/curl" -V 2>/dev/null | head -1 | cut -d' ' -f1-2) ${D}($CURL_PREFIX/bin/curl)${N}"
    elif [ -x "$CURL_PREFIX/bin/curl" ]; then
        warn "curl at $CURL_PREFIX/bin/curl exists but reports no ECH support"
    else
        warn "curl (ECH)   not installed at $CURL_PREFIX/bin/curl"
    fi
    local first; first=$(command -v curl 2>/dev/null || true)
    if [ -n "$first" ]; then
        if curl_has_ech "$first"; then
            ok "curl in PATH is the ECH build ${D}($first)${N}"
        else
            warn "curl in PATH is $first — no ECH. Is $CURL_PREFIX/bin ahead of /usr/bin?"
        fi
    fi
    [ -x /usr/bin/curl ] && ok "distribution curl still present at /usr/bin/curl ${D}(escape hatch)${N}"
}

verify() {
    local c="$CURL_PREFIX/bin/curl"
    [ -x "$c" ] || die "no curl at $c"
    say "Verifying"
    curl_has_ech "$c" || die "$c does not advertise ECH — the build did not take"
    ok "binary advertises ECH"
    # Resolve libcurl through RUNPATH only. /usr/local/lib must never be added to
    # /etc/ld.so.conf.d — that would hand this libcurl to every program on the box.
    if command -v ldd >/dev/null 2>&1; then
        local lib; lib=$(ldd "$c" 2>/dev/null | awk '/libcurl\.so/{print $3}')
        [ -n "$lib" ] && ok "libcurl resolves to $lib ${D}(via RUNPATH)${N}"
    fi
    if grep -rqs "$CURL_PREFIX/lib" /etc/ld.so.conf.d/ 2>/dev/null; then
        warn "$CURL_PREFIX/lib is in /etc/ld.so.conf.d — remove it. Every binary on"
        warn "this system would then link this libcurl instead of the distribution's."
    fi
    say "Live ECH handshake against $ECH_TEST_HOST"
    # --ech hard refuses to fall back to a cleartext SNI, so success is real.
    if "$c" --ech hard --doh-url https://dns.cloudflare.com/dns-query \
            -fsS -o /dev/null "https://$ECH_TEST_HOST/" 2>/dev/null; then
        ok "ECH handshake succeeded — the SNI was encrypted"
    else
        warn "ECH handshake failed. Check that $ECH_TEST_HOST still publishes an"
        warn "HTTPS RR with an ech= value:  dig +short HTTPS $ECH_TEST_HOST"
        return 1
    fi
}

# ------------------------------------------------------------------------ deps
deps() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$here/panoptes-deps.sh" ]; then
        "$here/panoptes-deps.sh" --group build "$@"
    elif command -v panoptes-deps.sh >/dev/null 2>&1; then
        panoptes-deps.sh --group build "$@"
    else
        warn "panoptes-deps.sh not found; checking by hand"
        local miss=""
        for c in git gcc make perl autoconf automake libtool pkg-config; do
            command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
        done
        for p in zlib libnghttp2 libidn2 libpsl; do
            pkg-config --exists "$p" 2>/dev/null || miss="$miss ${p}-devel"
        done
        [ -z "$miss" ] && { ok "build dependencies present"; return 0; }
        die "missing:$miss"
    fi
}

case "$MODE" in
    check)  report; exit 0 ;;
    verify) report; echo; verify; exit $? ;;
    deps)   deps --yes; exit $? ;;
esac

# ------------------------------------------------------------------- uninstall
if [ "$MODE" = uninstall ]; then
    report
    echo
    say "This will remove:"
    echo "    $OPENSSL_PREFIX  (whole directory)"
    echo "    $CURL_PREFIX/bin/curl, curl-config"
    echo "    $CURL_PREFIX/lib/libcurl.*"
    echo "    $CURL_PREFIX/include/curl/"
    echo "    $CURL_PREFIX/lib/pkgconfig/libcurl.pc"
    echo "  Your distribution's /usr/bin/curl is untouched and becomes the default again."
    printf 'Proceed? [y/N] '
    read -r reply </dev/tty || reply=n
    case "$reply" in [yY]*) ;; *) echo "Nothing removed."; exit 1 ;; esac
    $SUDO rm -rf -- "$OPENSSL_PREFIX"
    $SUDO rm -f -- "$CURL_PREFIX/bin/curl" "$CURL_PREFIX/bin/curl-config" \
                   "$CURL_PREFIX/lib/libcurl.so"* "$CURL_PREFIX/lib/libcurl.a" \
                   "$CURL_PREFIX/lib/pkgconfig/libcurl.pc"
    $SUDO rm -rf -- "$CURL_PREFIX/include/curl"
    $SUDO ldconfig 2>/dev/null || true
    ok "removed"
    command -v curl >/dev/null 2>&1 && ok "curl in PATH is now $(command -v curl)"
    exit 0
fi

# ------------------------------------------------------------------------ build
deps --check || die "build dependencies missing — run: sudo $0 --deps"

mkdir -p "$BUILD_DIR" || die "cannot create $BUILD_DIR"

fetch() {  # $1 = url, $2 = dir, $3 = ref
    if [ -d "$2/.git" ]; then
        say "Updating $(basename "$2")"
        git -C "$2" fetch --quiet --depth 1 origin "$3" || die "fetch failed for $2"
        git -C "$2" checkout --quiet FETCH_HEAD || die "checkout failed for $2"
    else
        say "Cloning $(basename "$2") ($3)"
        git clone --quiet --depth 1 --branch "$3" "$1" "$2" || die "clone failed: $1"
    fi
    ok "$(basename "$2") at $(git -C "$2" rev-parse --short HEAD)"
}

if [ "$MODE" != curl ]; then
    fetch "$OPENSSL_REPO" "$BUILD_DIR/openssl-ech" "$OPENSSL_BRANCH"
    cd "$BUILD_DIR/openssl-ech" || die "cannot enter openssl build dir"
    say "Configuring OpenSSL-ECH -> $OPENSSL_PREFIX"
    # no-shared is deliberate: curl links libcrypto/libssl statically, so this
    # OpenSSL never appears on any other program's library search path. Nothing
    # else on the system can accidentally pick up a development TLS stack.
    ./Configure --prefix="$OPENSSL_PREFIX" --openssldir="$OPENSSL_PREFIX/ssl" \
        enable-ech no-shared no-docs no-tests \
        || die "OpenSSL Configure failed"
    say "Building OpenSSL-ECH (-j$JOBS) — this is the slow part"
    make -j"$JOBS" || die "OpenSSL build failed"
    say "Installing OpenSSL-ECH"
    $SUDO make install_sw || die "OpenSSL install failed"
    ok "$("$OPENSSL_PREFIX/bin/openssl" version 2>/dev/null || echo installed)"
else
    [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "--curl-only, but $OPENSSL_PREFIX is not there"
    ok "reusing $OPENSSL_PREFIX"
fi

fetch "$CURL_REPO" "$BUILD_DIR/curl-ech" "$CURL_REF"
cd "$BUILD_DIR/curl-ech" || die "cannot enter curl build dir"

CONF_ARGS="--prefix=$CURL_PREFIX --with-openssl=$OPENSSL_PREFIX --enable-ech
           --with-nghttp2 --with-libidn2 --with-libpsl --disable-dependency-tracking"

if [ "$FULL" -eq 1 ]; then
    # Close the feature gap against the distribution curl, but only for the
    # libraries actually present — a missing one must not fail the whole build.
    say "--full: probing for optional libraries"
    add() { CONF_ARGS="$CONF_ARGS $1"; ok "enabled ${1#--with-}"; }
    pkg-config --exists libbrotlidec 2>/dev/null && add --with-brotli
    pkg-config --exists libzstd      2>/dev/null && add --with-zstd
    pkg-config --exists libssh2      2>/dev/null && add --with-libssh2
    command -v krb5-config >/dev/null 2>&1       && add --with-gssapi
    [ -f /usr/include/ldap.h ] && CONF_ARGS="$CONF_ARGS --enable-ldap --enable-ldaps" \
        && ok "enabled ldap"
fi

say "Configuring curl -> $CURL_PREFIX"
[ -x ./configure ] || { autoreconf -fi >/dev/null 2>&1 || die "autoreconf failed"; }
# shellcheck disable=SC2086
./configure $CONF_ARGS || die "curl configure failed (see config.log)"

say "Building curl (-j$JOBS)"
make -j"$JOBS" || die "curl build failed"
say "Installing curl"
$SUDO make install || die "curl install failed"

echo
report
echo
verify || true

echo
say "What just changed"
cat <<'NOTES'
  /usr/local/bin/curl now shadows /usr/bin/curl for your shell, for scripts that
  call plain "curl", and for sudo — /etc/sudoers secure_path also starts with
  /usr/local/bin. Package updates cannot touch either prefix.

  This build is deliberately minimal. Compared with a distribution curl it is
  missing HTTP/3, and (unless you passed --full) brotli, zstd, Kerberos/GSSAPI
  and the scp, sftp, smb and ldap protocols. If something breaks on one of
  those, call /usr/bin/curl explicitly — it is still installed.

  Do NOT add /usr/local/lib to /etc/ld.so.conf.d. The new curl finds its libcurl
  through the binary's RUNPATH; putting that directory on the global search path
  would give this libcurl to every program on the system.

  ECH only engages when the HTTPS DNS record is fetched over a secure channel,
  which is why the verification above passes --doh-url. Run "checkdns" for the
  resolver side, and "ech-browsers.sh" to turn ECH on in your browsers.
NOTES
