#!/bin/bash
# Mira — stop the desktop blanking, then enumerate the newly attached USB hardware.
# Run over Wi-Fi:  ssh mira-wifi bash -s < this-file
sec() { echo; echo "===== $1 ====="; }

export DISPLAY=:0
export XAUTHORITY=/var/run/lightdm/root/:0

sec "1. SERVICE STATE AFTER REBOOT"
for s in ssh mira-x11vnc mira-novnc lightdm; do
  printf '%-14s ' "$s"; systemctl is-active "$s.service"
done
ss -tlnp 2>/dev/null | grep -E '5900|6080' || echo "VNC PORTS NOT LISTENING"

sec "2. KILL SCREEN BLANKING (this is why it went black)"
xset s off      2>/dev/null && echo "screensaver off"
xset s noblank  2>/dev/null && echo "noblank set"
xset -dpms      2>/dev/null && echo "dpms disabled"
xset q 2>/dev/null | grep -A2 -iE 'screen saver|dpms' | head -8

sec "3. MAKE IT PERSIST ACROSS REBOOTS"
install -d -m 755 -o arduino -g arduino /home/arduino/.config/autostart
cat > /home/arduino/.config/autostart/mira-nodpms.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Mira - disable screen blanking
Comment=A blanked X screen shows as a black VNC session. Keep it awake.
Exec=sh -c "xset s off; xset s noblank; xset -dpms"
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
chown arduino:arduino /home/arduino/.config/autostart/mira-nodpms.desktop
echo "wrote autostart entry"

# Screen lockers also present as a black/locked VNC view.
for u in light-locker xfce4-screensaver xscreensaver; do
  if command -v "$u" >/dev/null 2>&1; then
    pkill -x "$u" 2>/dev/null && echo "killed running $u"
    echo "$u is installed - masking its autostart"
    for d in /etc/xdg/autostart/$u.desktop; do
      [ -e "$d" ] && cp "$d" "/home/arduino/.config/autostart/$(basename "$d")" \
        && echo 'Hidden=true' >> "/home/arduino/.config/autostart/$(basename "$d")" \
        && chown arduino:arduino "/home/arduino/.config/autostart/$(basename "$d")"
    done
  fi
done
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null \
  && echo "xfce power manager dpms disabled" || true

sec "4. USB DEVICES NOW ATTACHED"
lsusb

sec "5. VIDEO DEVICES"
ls -l /dev/video* 2>/dev/null || echo "no /dev/video*"
v4l2-ctl --list-devices 2>/dev/null

sec "6. WHICH VIDEO NODES ACTUALLY CAPTURE"
for d in /dev/video*; do
  [ -e "$d" ] || continue
  if v4l2-ctl -d "$d" --all 2>/dev/null | grep -q 'Video Capture'; then
    echo "--- $d : CAPTURE CAPABLE"
    v4l2-ctl -d "$d" --info 2>/dev/null | grep -E 'Card type|Bus info|Driver name'
    v4l2-ctl -d "$d" --list-formats-ext 2>/dev/null | grep -E '\[[0-9]\]|Size: Discrete' | head -12
  else
    echo "--- $d : not a capture node (codec/metadata)"
  fi
done

sec "7. AUDIO — DID THE WEBCAM MIC APPEAR?"
cat /proc/asound/cards
echo "--- capture ---"
arecord -l

sec "8. UDEV ATTRIBUTES FOR PINNING (build order step 2)"
for d in /dev/video* /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$d" ] || continue
  echo "--- $d"
  udevadm info -q property -n "$d" 2>/dev/null \
    | grep -E '^(ID_VENDOR_ID|ID_MODEL_ID|ID_SERIAL_SHORT|ID_MODEL|ID_V4L_CAPABILITIES)=' | sort -u
done

sec "9. POWER / THERMAL SANITY (hub-powered now)"
uptime
grep -iE 'under.?voltage|brownout|thermal|throttl' /var/log/kern.log 2>/dev/null | tail -5 \
  || dmesg 2>/dev/null | grep -iE 'under.?voltage|thermal|throttl' | tail -5 || echo "(no undervoltage/thermal messages)"
free -h

sec "DONE"
