#!/bin/bash
# Mira — fix clock, then install browser-based GUI (noVNC) + core deps.
# Idempotent. Debian packages preferred over pip to sidestep PEP 668.
set -u
sec() { echo; echo "===== $1 ====="; }

sec "0. DISK BEFORE"
df -h / | tail -1

sec "1. CLOCK (TLS + latency HUD depend on this)"
echo "before: $(date -u)"
timedatectl set-ntp true 2>/dev/null || true
systemctl restart systemd-timesyncd 2>/dev/null || true
for i in $(seq 1 20); do
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then break; fi
  sleep 2
done
echo "after:  $(date -u)"
timedatectl | grep -iE 'system clock|ntp'
# Hard fallback if timesyncd could not reach a server.
if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  echo "timesyncd did not sync; trying one-shot HTTP date fallback"
  H=$(curl -sI --max-time 10 http://deb.debian.org 2>/dev/null | grep -i '^date:' | cut -d' ' -f2-)
  if [ -n "${H:-}" ]; then date -s "$H" >/dev/null && echo "set from HTTP header: $(date -u)"; fi
fi

sec "2. APT UPDATE"
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3

sec "3. INSTALL"
# x11vnc      - export the running Xorg :0
# novnc       - browser VNC client (no Windows software needed)
# websockify  - bridges noVNC to x11vnc
# python3-*   - Debian-packaged, avoids PEP 668 entirely
# v4l-utils   - v4l2-ctl, needed to lock camera focus/exposure later
# usbutils    - working lsusb
apt-get install -y --no-install-recommends \
  x11vnc novnc websockify \
  python3-pip python3-venv python3-serial python3-numpy \
  v4l-utils usbutils

sec "4. VERIFY"
for b in x11vnc websockify v4l2-ctl lsusb pip3; do
  printf '%-12s ' "$b"; command -v "$b" || echo MISSING
done
python3 -c 'import serial, numpy; print("pyserial", serial.__version__, "| numpy", numpy.__version__)' 2>&1
ls -d /usr/share/novnc 2>/dev/null || echo "novnc web root NOT at /usr/share/novnc"

sec "5. DISK AFTER"
df -h / | tail -1

sec "DONE"
