#!/bin/bash
# Mira — bring the radio up and list reachable APs. Read-only, connects to nothing.
echo "=== radio on ==="
nmcli radio wifi on
echo "=== rescan (takes a few seconds) ==="
nmcli device wifi rescan 2>/dev/null || echo "(rescan returned nonzero, continuing)"
sleep 5
echo "=== visible access points ==="
nmcli -f SSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list
echo
echo "=== 5 GHz only (channel > 14) ==="
nmcli -t -f SSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list \
  | awk -F: '$2+0 > 14 {printf "%-28s ch%-4s %-10s sig=%-4s %s\n", $1, $2, $3, $4, $5}'
echo
echo "=== existing saved connections ==="
nmcli -f NAME,TYPE,DEVICE connection show
echo
echo "=== wlan0 state ==="
nmcli device status
