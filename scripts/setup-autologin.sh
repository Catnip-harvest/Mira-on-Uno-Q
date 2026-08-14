#!/bin/bash
# Mira — autologin the `arduino` user into XFCE so the desktop is actually usable.
#
# WHY: root is locked (* in shadow) and `arduino` has NO /etc/shadow entry, so
# nobody can authenticate at the lightdm greeter. Without this, noVNC shows a
# login screen that cannot be passed.
#
# SECURITY TRADEOFF: the desktop auto-unlocks. Acceptable here only because
# x11vnc/noVNC bind to 127.0.0.1 and are reachable solely over the USB tunnel.
#
# TO UNDO:  rm /etc/lightdm/lightdm.conf.d/50-mira-autologin.conf && systemctl restart lightdm
set -u
sec() { echo; echo "===== $1 ====="; }

sec "1. AUTOLOGIN CONFIG"
install -d -m 755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-mira-autologin.conf <<'EOF'
[Seat:*]
autologin-user=arduino
autologin-user-timeout=0
autologin-session=xfce
EOF
cat /etc/lightdm/lightdm.conf.d/50-mira-autologin.conf

sec "2. AUTOLOGIN GROUP (Debian lightdm expects it to exist)"
getent group autologin >/dev/null || groupadd -r autologin
gpasswd -a arduino autologin
getent group nopasswdlogin >/dev/null || groupadd -r nopasswdlogin
gpasswd -a arduino nopasswdlogin

sec "3. HOME DIRECTORY SANITY"
getent passwd arduino
if [ ! -d /home/arduino ]; then
  echo "/home/arduino missing — creating it (XFCE needs a writable home)"
  install -d -m 755 -o arduino -g arduino /home/arduino
fi
ls -ld /home/arduino

sec "4. RESTART LIGHTDM (this kills Xorg, so x11vnc must restart after)"
systemctl restart lightdm
sleep 8

sec "5. DID A REAL SESSION START?"
loginctl list-sessions --no-legend
echo "--- seat0 session detail ---"
loginctl show-seat seat0 2>/dev/null | grep -iE 'ActiveSession|Sessions' || true
ps -eo user,comm | grep -E 'xfce4-session|xfwm4|xfdesktop' | sort -u || echo "NO XFCE PROCESSES YET"

sec "6. RESTART VNC ONTO THE NEW X SERVER"
systemctl restart mira-x11vnc.service
sleep 3
systemctl restart mira-novnc.service
sleep 2
systemctl is-active mira-x11vnc.service mira-novnc.service
ss -tlnp | grep -E '5900|6080' || echo "NOT LISTENING"

sec "7. GEOMETRY"
DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 xdpyinfo 2>/dev/null | grep -E 'dimensions' \
  || echo "xdpyinfo failed (auth path may have changed)"

sec "8. LOGS IF x11vnc UNHEALTHY"
systemctl is-active --quiet mira-x11vnc.service || journalctl -u mira-x11vnc -n 20 --no-pager

sec "DONE"
