#!/bin/bash
# Mira — clear the forced-password-change flag that breaks lightdm autologin.
#
# ROOT CAUSE: /etc/shadow has arduino with sp_lstchg=0, i.e. "must change
# password at next login". PAM therefore returns 20 (PAM_AUTHTOK_ERR) during
# the lightdm-autologin service, and lightdm falls back to the greeter.
# Fix = stamp last-change to today and clear inactive/expire. No password set.
set -u
sec() { echo; echo "===== $1 ====="; }

sec "1. SHADOW BEFORE (password field described, never printed)"
PW=$(awk -F: '$1=="arduino"{print $2}' /etc/shadow)
echo "password field length: ${#PW}"
case "$PW" in
  '')   echo "password field: EMPTY (no password set)";;
  '*')  echo "password field: * (locked)";;
  '!'*) echo "password field: ! (locked)";;
  *)    echo "password field: a real hash";;
esac
chage -l arduino

sec "2. CLEAR FORCED CHANGE / EXPIRY"
chage -d "$(date +%F)" arduino
chage -M 99999 arduino
chage -I -1 arduino
chage -E -1 arduino
echo "--- after ---"
chage -l arduino

sec "3. RESTART LIGHTDM"
systemctl restart lightdm
sleep 10

sec "4. AUTOLOGIN VERDICT (from lightdm's own log)"
grep -iE 'lightdm-autologin|Authentication complete|Switching to greeter|running command|user session' \
  /var/log/lightdm/lightdm.log | tail -12

sec "5. IS AN XFCE SESSION ACTUALLY RUNNING?"
loginctl list-sessions --no-legend
ps -eo user,comm | grep -E 'xfce4-session|xfwm4|xfdesktop|xfce4-panel' | sort -u \
  || echo "NO XFCE PROCESSES"

sec "6. RESTART VNC ONTO THE NEW X SERVER"
systemctl restart mira-x11vnc.service
sleep 3
systemctl restart mira-novnc.service
sleep 2
systemctl is-active mira-x11vnc.service mira-novnc.service
ss -tlnp | grep -E '5900|6080' || echo "NOT LISTENING"

sec "7. MEMORY AFTER DESKTOP LOGIN"
free -h

sec "DONE"
