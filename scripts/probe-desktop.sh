#!/bin/bash
# Mira — is there actually a desktop to log into, and can we log in? Read-only.
sec() { echo; echo "===== $1 ====="; }

sec "AVAILABLE X SESSIONS"
ls -1 /usr/share/xsessions/ 2>/dev/null || echo "NONE — no desktop environment installed"
for f in /usr/share/xsessions/*.desktop; do
  [ -e "$f" ] || continue
  printf '%s -> ' "$(basename "$f")"
  grep -m1 '^Exec=' "$f"
done

sec "DESKTOP PACKAGES PRESENT"
dpkg -l 2>/dev/null | awk '$1=="ii" && ($2 ~ /xfce4$|^lxde|^lxqt|task-.*-desktop|gnome-shell|^kde-plasma|openbox|fluxbox|^i3$/) {print $2, $3}' \
  || true
echo "(empty means no full DE)"

sec "ACCOUNT LOGIN STATE (can we get past the greeter?)"
for u in root arduino; do
  s=$(awk -F: -v U="$u" '$1==U{print $2}' /etc/shadow 2>/dev/null)
  case "$s" in
    '')   echo "$u: no entry";;
    '*')  echo "$u: LOCKED (* = no password login possible)";;
    '!'*) echo "$u: LOCKED (! prefix)";;
    *)    echo "$u: has a usable password hash (${s:0:3}...)";;
  esac
done

sec "LIGHTDM AUTOLOGIN CONFIG"
grep -rnE 'autologin|^\[Seat' /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf 2>/dev/null \
  || echo "no autologin configured"
getent group autologin >/dev/null 2>&1 && echo "autologin group exists" || echo "no autologin group"

sec "GREETER / DM STATUS"
systemctl is-active lightdm
loginctl list-sessions --no-legend 2>/dev/null || echo "(no sessions)"

sec "SCREEN GEOMETRY (what noVNC will show)"
DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 xdpyinfo 2>/dev/null | grep -E 'dimensions|depth of root' \
  || echo "xdpyinfo unavailable"

sec "DONE"
