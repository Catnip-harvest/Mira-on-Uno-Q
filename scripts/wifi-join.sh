#!/bin/bash
# Mira — join Wi-Fi using a PSK supplied out-of-band in /tmp/psk.
# The secret is never in this file, in argv, or in shell history.
# SSID also comes from a file: an SSID with spaces cannot survive being passed
# as argv through `adb shell` (the space splits it into two args).
# Usage:  printf %s '<ssid>' > /tmp/ssid; printf %s '<psk>' > /tmp/psk
#         bash wifi-join.sh; rm -f /tmp/psk /tmp/ssid
set -u
SSID="${1:-}"
if [ -z "$SSID" ] && [ -s /tmp/ssid ]; then SSID=$(cat /tmp/ssid); fi
if [ -z "$SSID" ]; then echo "FATAL: no SSID (arg or /tmp/ssid)"; exit 1; fi
CON='mira-wifi'

if [ ! -s /tmp/psk ]; then echo "FATAL: /tmp/psk missing or empty"; exit 1; fi
PSK=$(cat /tmp/psk)

nmcli radio wifi on
nmcli connection delete "$CON"  2>/dev/null >/dev/null
nmcli connection delete "$SSID" 2>/dev/null >/dev/null

echo "=== creating profile for: $SSID (psk length ${#PSK}) ==="
nmcli connection add type wifi con-name "$CON" ifname wlan0 ssid "$SSID" \
  -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" >/dev/null
unset PSK

echo "=== activating ==="
if nmcli connection up "$CON"; then echo "ACTIVATED"; else echo "ACTIVATION FAILED"; fi

sleep 4
echo
echo "=== link ==="
nmcli -f GENERAL.STATE,GENERAL.CONNECTION device show wlan0
ip -brief addr show wlan0
nmcli -f IN-USE,SSID,CHAN,FREQ,SIGNAL,RATE device wifi list --rescan no 2>/dev/null | awk 'NR==1 || /^\*/'

echo
echo "=== routing / dns ==="
ip route | head -4
getent hosts deb.debian.org || echo "DNS FAILED"

echo
echo "=== clock (matters for TLS + latency HUD) ==="
date
timedatectl 2>/dev/null | grep -iE 'system clock|ntp|time zone'

echo
echo "=== handshake verdict ==="
journalctl -u NetworkManager -n 25 --no-pager 2>/dev/null \
  | grep -iE '4way|handshake|no-secrets|activation successful|state change: (config|ip-config|activated)' | tail -8
