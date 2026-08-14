#!/bin/bash
# Mira — UNO Q first-contact discovery (brief §7)
# Run ON THE BOARD. Writes ./mira-discovery.txt. Read-only, safe.
#   bash discover.sh && cat mira-discovery.txt

OUT="/tmp/mira-discovery.txt"
exec > >(tee "$OUT") 2>&1

sec() { echo; echo "===== $1 ====="; }

sec "IDENTITY + RESOURCES"
cat /etc/os-release
uname -a
echo "nproc: $(nproc)"
free -h
df -h /

sec "GRAPHICS STACK"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}"
ls /run/user/*/wayland-* 2>/dev/null || echo "no wayland sockets"
pgrep -a "weston|wayfire|Xorg" || echo "no compositor running (headless)"

sec "USB DEVICES"
lsusb

sec "VIDEO DEVICES"
v4l2-ctl --list-devices 2>/dev/null || echo "v4l2-ctl MISSING (apt install v4l-utils)"

sec "AUDIO CAPTURE"
arecord -l 2>/dev/null || echo "arecord MISSING (apt install alsa-utils)"

sec "AUDIO PLAYBACK"
aplay -l 2>/dev/null || echo "aplay MISSING"

sec "ALSA CARDS (pin by CARD= name, never index)"
cat /proc/asound/cards 2>/dev/null || echo "no /proc/asound"

sec "STABLE DEVICE PATHS (source of udev rules)"
ls -l /dev/serial/by-id/ 2>/dev/null || echo "no /dev/serial/by-id"
ls -l /dev/v4l/by-id/   2>/dev/null || echo "no /dev/v4l/by-id"

sec "UDEV ATTRS — SERVO BUS CANDIDATES"
for d in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$d" ] || continue
  echo "--- $d"
  udevadm info -a -n "$d" 2>/dev/null | grep -m4 -E 'ATTRS\{(serial|idVendor|idProduct)\}'
done

sec "UDEV ATTRS — VIDEO CANDIDATES"
for d in /dev/video*; do
  [ -e "$d" ] || continue
  echo "--- $d"
  udevadm info -a -n "$d" 2>/dev/null | grep -m4 -E 'ATTRS\{(serial|idVendor|idProduct)\}'
done

sec "PYTHON"
python3 -V
pip3 list 2>/dev/null | head -40

sec "PYTHON MODULES WE NEED"
for m in serial onnxruntime websockets numpy; do
  python3 -c "import $m; print('$m OK', getattr($m,'__version__','?'))" 2>/dev/null \
    || echo "$m MISSING"
done

sec "NETWORK"
ip -brief addr

sec "WIFI TOOLING (path to SSH)"
which nmcli || echo "nmcli MISSING"
nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null || echo "nmcli device query failed"
which wpa_supplicant || echo "wpa_supplicant MISSING"
iw dev 2>/dev/null || echo "iw MISSING / no wireless dev"

sec "SSH SERVER"
which sshd || echo "sshd MISSING"
for u in ssh sshd; do
  printf '%s: ' "$u"
  systemctl is-active "$u" 2>/dev/null || echo "inactive/absent"
done
ls /etc/ssh/sshd_config 2>/dev/null || echo "no sshd_config"

sec "USB GADGET CONFIG (why no RNDIS)"
ls /sys/kernel/config/usb_gadget/ 2>/dev/null || echo "no configfs gadget dir"
cat /sys/kernel/config/usb_gadget/*/UDC 2>/dev/null

sec "DONE"
echo "Wrote $OUT — paste this back into Claude Code."
