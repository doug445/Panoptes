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
# wifi-recover — Wi-Fi recovery + auto-logging for Mid-2012 MBP / BCM4331 + netwatch-suite breakage.
#
# Usage:
#   sudo bash wifi-recover.sh                # diagnose only (default; no system changes)
#   sudo bash wifi-recover.sh --repair       # safe, reversible repairs (recommended first try)
#   sudo bash wifi-recover.sh --reload-modules   # adds aggressive wl/brcmsmac reload (risky on patched wl)
#   sudo bash wifi-recover.sh --bundle       # tar logs into a single file you can carry away
#   sudo bash wifi-recover.sh --help
#
# Logs land on the USB drive this script is run from if writable, else /tmp/wifi-recover-logs/.
# Saved connection PSKs are scrubbed from logs.

set -u
shopt -s nullglob

# -------- arg parsing ----------------------------------------------------
DO_REPAIR=0
DO_MODULES=0
DO_BUNDLE=0
HELP=0
for a in "$@"; do
  case "$a" in
    --repair)         DO_REPAIR=1 ;;
    --reload-modules) DO_REPAIR=1; DO_MODULES=1 ;;
    --bundle)         DO_BUNDLE=1 ;;
    --diagnose|"")    : ;;
    -h|--help)        HELP=1 ;;
    *) echo "unknown arg: $a"; HELP=1 ;;
  esac
done
if [[ $HELP -eq 1 ]]; then
  sed -n '2,12p' "$0"; exit 0
fi

# -------- elevate --------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Re-running under sudo..."
  exec sudo -E bash "$0" "$@"
fi

# -------- pick log dir (USB next to script preferred) -------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -w "$SCRIPT_DIR" ]] && touch "$SCRIPT_DIR/.wr.write-test" 2>/dev/null; then
  rm -f "$SCRIPT_DIR/.wr.write-test"
  LOG_DIR="$SCRIPT_DIR/logs"
else
  LOG_DIR="/tmp/wifi-recover-logs"
fi
mkdir -p "$LOG_DIR"
chmod 0755 "$LOG_DIR" 2>/dev/null || true

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/wifi-recover-$STAMP.log"
SUMMARY="$LOG_DIR/wifi-recover-$STAMP.summary.txt"

# Tee everything (stdout+stderr) to LOG. Keep terminal output too.
exec > >(tee -a "$LOG") 2>&1

# -------- helpers --------------------------------------------------------
banner() {
  echo
  echo "############################################################"
  echo "## $*"
  echo "############################################################"
}
section() { echo; echo "===== $* ====="; }
note()    { echo "-- $*"; }
run() {
  echo "+ $*"
  "$@"
  local rc=$?
  echo "  rc=$rc"
  return $rc
}
# run a command with shell expansion (pipes etc.)
runs() {
  echo "+ sh: $*"
  bash -c "$*"
  local rc=$?
  echo "  rc=$rc"
  return $rc
}
have() { command -v "$1" >/dev/null 2>&1; }

# -------- header ---------------------------------------------------------
banner "wifi-recover  $STAMP   mode=$( ((DO_REPAIR)) && echo REPAIR || echo DIAGNOSE )$( ((DO_MODULES)) && echo +modules )$( ((DO_BUNDLE)) && echo +bundle )"
note "log file:   $LOG"
note "summary:    $SUMMARY"
note "script dir: $SCRIPT_DIR"
note "log dir:    $LOG_DIR"

# -------- system facts ---------------------------------------------------
section "system facts"
run uname -a
run cat /etc/os-release
run uptime
run date

section "battery / power note (MBP 9,2 specific is harmless if missing)"
runs "dmidecode -s system-product-name 2>/dev/null || cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null"

# -------- find Wi-Fi iface -----------------------------------------------
section "wifi interface detection"
IFACE=""
if have nmcli; then
  IFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
fi
if [[ -z "$IFACE" ]] && have iw; then
  IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
fi
if [[ -z "$IFACE" ]]; then
  for d in /sys/class/net/*/wireless; do IFACE="$(basename "$(dirname "$d")")"; break; done
fi
note "wifi iface: ${IFACE:-<none-found>}"

# -------- driver / module / pci ------------------------------------------
section "PCI + driver binding (looking for 14e4:4331 BCM4331)"
run lspci -nnk
runs "lspci -nnk | grep -A3 -iE 'network|wireless|14e4'"

section "loaded modules of interest"
runs "lsmod | grep -Ei '^(wl|brcm|b43|ssb|bcma|cfg80211|mac80211)\\b'"

section "modinfo on broadcom modules (if loaded)"
for m in wl brcmsmac brcmfmac b43 b43legacy; do
  if lsmod | awk '{print $1}' | grep -qx "$m"; then
    run modinfo -F filename "$m"
    run modinfo -F vermagic "$m"
    run modinfo -F srcversion "$m"
  fi
done

section "blacklist files (might be hiding the real driver)"
run ls -la /etc/modprobe.d/
runs "grep -rEn 'blacklist|install (wl|brcmsmac|b43|bcma|ssb)' /etc/modprobe.d/ 2>/dev/null"

# -------- rfkill ---------------------------------------------------------
section "rfkill"
run rfkill list

# -------- link / addr / scan / link state --------------------------------
if [[ -n "$IFACE" ]]; then
  section "link + address ($IFACE)"
  run ip link show "$IFACE"
  run cat /sys/class/net/"$IFACE"/address
  run cat /sys/class/net/"$IFACE"/operstate
  run cat /sys/class/net/"$IFACE"/carrier 2>/dev/null
  run ethtool -P "$IFACE"
  run ethtool -i "$IFACE"

  section "iw / iwconfig ($IFACE)"
  have iw       && run iw dev "$IFACE" info
  have iw       && run iw dev "$IFACE" link
  have iwconfig && run iwconfig "$IFACE"

  section "scan ($IFACE) — top 30 BSSIDs"
  if have iw; then
    run iw dev "$IFACE" scan trigger 2>/dev/null
    sleep 3
    runs "iw dev $IFACE scan 2>/dev/null | awk '/^BSS/||/SSID:/||/signal:/||/freq:/' | head -120"
  fi
  have nmcli && run nmcli -f IN-USE,SSID,BSSID,SIGNAL,SECURITY device wifi list --rescan auto
fi

# -------- IP / route / DNS -----------------------------------------------
section "ip / route / dns"
run ip -br addr
run ip -4 route
run ip -6 route
run cat /etc/resolv.conf
have resolvectl && run resolvectl status

# -------- NM state -------------------------------------------------------
if have nmcli; then
  section "NetworkManager state"
  run nmcli general status
  run nmcli radio
  run nmcli device status
  run nmcli -f NAME,TYPE,AUTOCONNECT,TIMESTAMP-REAL,DEVICE connection show
  if [[ -n "$IFACE" ]]; then
    run nmcli device show "$IFACE"
  fi
fi

# -------- NM config files (the smoking gun usually) ----------------------
section "NetworkManager conf.d (THIS is where mac-randomization.conf lands)"
run ls -la /etc/NetworkManager/conf.d/
for f in /etc/NetworkManager/conf.d/*.conf /etc/NetworkManager/NetworkManager.conf; do
  [[ -f "$f" ]] || continue
  echo "--- $f ---"
  run cat "$f"
done

section "NM system-connections (PSKs scrubbed)"
run ls -la /etc/NetworkManager/system-connections/
for f in /etc/NetworkManager/system-connections/*.nmconnection /etc/NetworkManager/system-connections/*; do
  [[ -f "$f" ]] || continue
  echo "--- $f (sanitized: psk= / password= / wep-key*= redacted) ---"
  runs "sed -E 's/^(psk|password|wep-key[^=]*)=.*/\\1=<REDACTED>/' '$f'"
done

# -------- macchanger system defaults & hooks -----------------------------
section "macchanger system config + hooks"
run cat /etc/default/macchanger 2>/dev/null
run ls -la /etc/network/if-pre-up.d/  2>/dev/null
run ls -la /etc/network/if-post-down.d/ 2>/dev/null

# -------- service status -------------------------------------------------
section "services"
for s in NetworkManager wpa_supplicant systemd-resolved systemd-networkd; do
  echo "--- $s ---"
  run systemctl is-active "$s" 2>/dev/null
  run systemctl is-enabled "$s" 2>/dev/null
done
run systemctl --no-pager --full status NetworkManager
run systemctl --no-pager --full status wpa_supplicant 2>/dev/null

# -------- recent journal / dmesg slices ----------------------------------
section "journal: NetworkManager (last 30 min)"
run journalctl -u NetworkManager --since "30 min ago" --no-pager

section "journal: wpa_supplicant (last 30 min)"
run journalctl -u wpa_supplicant --since "30 min ago" --no-pager

section "journal: kernel/wifi (last 30 min)"
runs "journalctl -k --since '30 min ago' --no-pager | grep -iE 'wlan|wlp|wl[ :]|brcm|b43|cfg80211|mac80211|firmware|ieee80211|nl80211' | tail -200"

section "dmesg: wifi-related"
runs "dmesg --time-format=iso 2>/dev/null | grep -iE 'wlan|wlp|wl[ :]|brcm|b43|cfg80211|mac80211|firmware|ieee80211|nl80211' | tail -200"

# =========================================================================
# DIAGNOSTIC TRIAGE — surface obvious smoking guns to the summary
# =========================================================================
banner "TRIAGE FINDINGS"
: > "$SUMMARY"
flag() { echo "[FLAG] $*" | tee -a "$SUMMARY"; }
ok()   { echo "[ ok ] $*" | tee -a "$SUMMARY"; }

# 1) cloned-mac config drop-in
if [[ -f /etc/NetworkManager/conf.d/mac-randomization.conf ]]; then
  flag "mac-randomization.conf is INSTALLED at /etc/NetworkManager/conf.d/ — this forces wifi.cloned-mac-address=random; BCM4331+wl frequently fails to associate with cloned MACs."
else
  ok "no mac-randomization.conf in conf.d/"
fi

# 2) cloned-mac on saved connections
if have nmcli; then
  while IFS= read -r conn; do
    [[ -z "$conn" ]] && continue
    val=$(nmcli -g 802-11-wireless.cloned-mac-address connection show "$conn" 2>/dev/null)
    if [[ "$val" == "random" || "$val" == "stable" || "$val" =~ ^[0-9a-fA-F:]{17}$ ]]; then
      flag "connection '$conn' has cloned-mac-address=$val"
    fi
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"||$2=="wifi"{print $1}')
fi

# 3) kernel MAC vs permanent MAC mismatch
if [[ -n "$IFACE" ]]; then
  CUR_MAC=$(cat /sys/class/net/"$IFACE"/address 2>/dev/null)
  PERM_MAC=$(ethtool -P "$IFACE" 2>/dev/null | awk '{print $NF}')
  if [[ -n "$PERM_MAC" && "$PERM_MAC" != "00:00:00:00:00:00" && "$CUR_MAC" != "$PERM_MAC" ]]; then
    flag "kernel MAC $CUR_MAC != permanent MAC $PERM_MAC on $IFACE — driver may refuse to associate"
  else
    ok "kernel MAC matches permanent MAC ($CUR_MAC)"
  fi
fi

# 4) rfkill blocks
if rfkill list 2>/dev/null | grep -q "Soft blocked: yes"; then flag "rfkill SOFT block present"; fi
if rfkill list 2>/dev/null | grep -q "Hard blocked: yes"; then flag "rfkill HARD block present (physical switch / acer-wireless / Fn key)"; fi

# 5) NM running?
if have systemctl; then
  if ! systemctl is-active --quiet NetworkManager; then flag "NetworkManager is NOT active"; else ok "NetworkManager active"; fi
fi

# 6) device managed?
if have nmcli && [[ -n "$IFACE" ]]; then
  state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $2}')
  case "$state" in
    unmanaged|unavailable) flag "NM device state for $IFACE is $state" ;;
    *) ok "NM device state for $IFACE: $state" ;;
  esac
fi

# 7) wl module loaded but no bound iface?
if lsmod | awk '{print $1}' | grep -qx wl; then
  if [[ -z "$IFACE" ]]; then flag "wl driver loaded but no Wi-Fi iface present — likely driver crashed or firmware refused"; fi
fi

echo
echo "Triage summary saved to: $SUMMARY"

# =========================================================================
# REPAIR MODE
# =========================================================================
if [[ $DO_REPAIR -eq 1 ]]; then
  banner "REPAIR — applying safe, reversible fixes"

  section "[A] rfkill unblock all"
  run rfkill unblock all
  have nmcli && run nmcli radio wifi on

  section "[B] disable mac-randomization conf.d drop-in (rename, not delete)"
  if [[ -f /etc/NetworkManager/conf.d/mac-randomization.conf ]]; then
    run mv /etc/NetworkManager/conf.d/mac-randomization.conf \
           /etc/NetworkManager/conf.d/mac-randomization.conf.disabled-by-recovery
    note "renamed → mac-randomization.conf.disabled-by-recovery (revert with 'mv' to restore)"
  else
    note "no mac-randomization.conf to disable"
  fi

  section "[C] force cloned-mac-address=permanent on every saved Wi-Fi connection"
  if have nmcli; then
    while IFS= read -r conn; do
      [[ -z "$conn" ]] && continue
      run nmcli connection modify "$conn" \
        802-11-wireless.cloned-mac-address permanent \
        802-11-wireless.mac-address-randomization default
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"||$2=="wifi"{print $1}')
  fi

  section "[D] reset kernel-level MAC to permanent on $IFACE"
  if [[ -n "$IFACE" ]]; then
    PERM_MAC=$(ethtool -P "$IFACE" 2>/dev/null | awk '{print $NF}')
    note "permanent MAC reported by ethtool: ${PERM_MAC:-<unknown>}"
    run ip link set "$IFACE" down
    if [[ -n "$PERM_MAC" && "$PERM_MAC" != "00:00:00:00:00:00" ]]; then
      run ip link set "$IFACE" address "$PERM_MAC"
    fi
    if have macchanger; then
      run macchanger -p "$IFACE" || true
    fi
    run ip link set "$IFACE" up
    sleep 1
    run cat /sys/class/net/"$IFACE"/address
  else
    note "no iface — skipping"
  fi

  section "[E] neutralize macchanger system defaults if hostile"
  if [[ -f /etc/default/macchanger ]]; then
    if grep -qE '^(ENABLE_ON_POST_UP_DOWN|RUN_DAEMON|RANDOMIZE)=true' /etc/default/macchanger; then
      run cp -a /etc/default/macchanger /etc/default/macchanger.bak-$STAMP
      run sed -i -E 's/^(ENABLE_ON_POST_UP_DOWN|RUN_DAEMON|RANDOMIZE)=true/\1=false/' /etc/default/macchanger
      note "neutralized — backup at /etc/default/macchanger.bak-$STAMP"
    fi
  fi

  if [[ $DO_MODULES -eq 1 ]]; then
    section "[F] reload Broadcom driver modules (RISKY — only because --reload-modules was passed)"
    # Note: on Mid-2012 MBP with 'broadcom-sta' DKMS, the driver is 'wl'.
    # Don't unload cfg80211 — it's used by other things.
    for m in wl brcmsmac b43; do
      if lsmod | awk '{print $1}' | grep -qx "$m"; then
        run modprobe -r "$m" || true
      fi
    done
    sleep 2
    # Reload first one that exists
    for m in wl brcmsmac b43; do
      if modinfo "$m" >/dev/null 2>&1; then
        run modprobe "$m" && break
      fi
    done
    sleep 3
  fi

  section "[G] restart wpa_supplicant + NetworkManager"
  run systemctl restart wpa_supplicant 2>/dev/null || true
  run systemctl restart NetworkManager
  sleep 6

  section "[H] ensure NM manages $IFACE"
  if have nmcli && [[ -n "$IFACE" ]]; then
    run nmcli device set "$IFACE" managed yes 2>/dev/null || true
    run nmcli device status
  fi

  section "[I] rescan + try most recent connection"
  if have nmcli; then
    run nmcli device wifi rescan 2>/dev/null || true
    sleep 4
    run nmcli -f IN-USE,SSID,BSSID,SIGNAL,SECURITY device wifi list
    LAST_CONN=$(nmcli -t -f NAME,TYPE,TIMESTAMP-REAL connection show 2>/dev/null \
      | awk -F: '$2=="802-11-wireless"||$2=="wifi"{print $3":"$1}' \
      | sort -t: -k1 -nr | head -1 | cut -d: -f2-)
    if [[ -n "$LAST_CONN" ]]; then
      note "attempting connection: $LAST_CONN"
      run nmcli connection up "$LAST_CONN" || true
    else
      note "no saved Wi-Fi connection to auto-up"
    fi
  fi

  section "[J] verify"
  for i in $(seq 1 15); do
    if [[ -n "$IFACE" ]] && iw dev "$IFACE" link 2>/dev/null | grep -q "^Connected to"; then
      note "associated"
      break
    fi
    sleep 1
  done
  run ip -br addr
  have iw && [[ -n "$IFACE" ]] && run iw dev "$IFACE" link
  run ping -c 3 -W 2 1.1.1.1 || true
  run ping -c 2 -W 2 cloudflare.com || true

  banner "REPAIR DONE"
  echo
  echo "If still broken:"
  echo "  - rerun WITH --reload-modules (but only if patched 'wl' is what you trust):"
  echo "      sudo bash $(basename "$0") --reload-modules"
  echo "  - If router uses MAC filtering/whitelist, the new (permanent) MAC must be re-added there."
  echo "  - Bring the USB back so the log can be read:"
  echo "      $LOG"
fi

# =========================================================================
# BUNDLE
# =========================================================================
if [[ $DO_BUNDLE -eq 1 || $DO_REPAIR -eq 1 || 1 -eq 1 ]]; then
  banner "BUNDLE"
  TAR="$LOG_DIR/wifi-recover-bundle-$STAMP.tar.gz"
  # Snapshot a few relevant configs into a tmpdir, then tar with the log.
  TMP="$(mktemp -d)"
  cp -a /etc/NetworkManager/conf.d "$TMP/conf.d" 2>/dev/null || true
  cp -a /etc/modprobe.d            "$TMP/modprobe.d" 2>/dev/null || true
  [[ -f /etc/default/macchanger ]] && cp -a /etc/default/macchanger "$TMP/macchanger.default" 2>/dev/null || true
  # Sanitize NM connections into the tarball
  mkdir -p "$TMP/system-connections-sanitized"
  for f in /etc/NetworkManager/system-connections/*; do
    [[ -f "$f" ]] || continue
    sed -E 's/^(psk|password|wep-key[^=]*)=.*/\1=<REDACTED>/' "$f" > "$TMP/system-connections-sanitized/$(basename "$f")"
  done
  cp -a "$LOG"     "$TMP/" 2>/dev/null || true
  cp -a "$SUMMARY" "$TMP/" 2>/dev/null || true
  tar -czf "$TAR" -C "$TMP" . 2>/dev/null
  rm -rf "$TMP"
  note "bundle: $TAR"
fi

banner "DONE   log=$LOG   summary=$SUMMARY"
echo
echo "If running on the broken machine and Wi-Fi is still down,"
echo "carry the USB back and share these two paths:"
echo "  $LOG"
echo "  ${TAR:-$SUMMARY}"
