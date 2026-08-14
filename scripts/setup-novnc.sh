#!/bin/bash
# Mira — expose the board's Xorg :0 desktop as browser-based noVNC.
#
# SECURITY: both services bind to 127.0.0.1 ONLY. Nothing is published to the
# Wi-Fi LAN. "Phong 04" looks like a shared building AP, and an unauthenticated
# VNC desktop on a shared network is not acceptable. Access is via
# `adb forward` over the USB cable, or an SSH -L tunnel. Do not add -listen.
set -u
sec() { echo; echo "===== $1 ====="; }

XAUTH=$(ls /var/run/lightdm/root/:0 2>/dev/null | head -1)
if [ -z "${XAUTH:-}" ]; then
  echo "WARN: no lightdm Xauthority at /var/run/lightdm/root/:0"
  XAUTH=/var/run/lightdm/root/:0
fi

sec "1. WRITE UNITS"
cat > /etc/systemd/system/mira-x11vnc.service <<EOF
[Unit]
Description=Mira - x11vnc on Xorg :0 (localhost only)
After=display-manager.service
Wants=display-manager.service

[Service]
Type=simple
# -localhost + -nopw: unauthenticated, but unreachable except via a tunnel.
ExecStart=/usr/bin/x11vnc -display :0 -auth $XAUTH -localhost -nopw \\
          -forever -shared -noxdamage -repeat -rfbport 5900 -quiet
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mira-novnc.service <<'EOF'
[Unit]
Description=Mira - noVNC web client bridging to x11vnc (localhost only)
After=mira-x11vnc.service
Requires=mira-x11vnc.service

[Service]
Type=simple
ExecStart=/usr/bin/websockify --web=/usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
echo "units written (xauth: $XAUTH)"

sec "2. ENABLE + START"
systemctl daemon-reload
systemctl enable --now mira-x11vnc.service
systemctl enable --now mira-novnc.service
sleep 3

sec "3. STATUS"
systemctl is-active mira-x11vnc.service mira-novnc.service

sec "4. LISTENING (must be 127.0.0.1, never 0.0.0.0)"
ss -tlnp | grep -E '5900|6080' || echo "NOTHING LISTENING - see logs below"

sec "5. LOGS IF UNHEALTHY"
if ! systemctl is-active --quiet mira-x11vnc.service; then
  journalctl -u mira-x11vnc.service -n 25 --no-pager
fi
if ! systemctl is-active --quiet mira-novnc.service; then
  journalctl -u mira-novnc.service -n 25 --no-pager
fi

sec "6. WHAT IS ON THE DESKTOP"
ps -eo comm --sort=-rss | grep -iE 'lightdm|xfce|gnome|lxde|lxqt|openbox|weston|mutter|xfwm|panel' | sort -u || echo "(no desktop shell detected - likely just the greeter)"

sec "DONE"
