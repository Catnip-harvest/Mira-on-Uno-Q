#!/bin/bash
# Mira — laptop-side bring-up check. Run on the Ubuntu 22.04 install.
#
# WHAT IT DOES
#   Reports what is actually present (ROS 2, LeRobot, arm, camera), then writes
#   udev rules pinning the SO-101 servo bus and the camera BY SERIAL NUMBER.
#
# WHY UDEV PINNING MATTERS
#   /dev/ttyUSB0 and /dev/video2 are assigned in probe order. Plug the camera in
#   before the arm one morning and they swap. On demo day that reads as "the
#   robot is broken". Pinning by serial makes the names stable forever.
#
# READ-ONLY BY DEFAULT. Pass --write-udev to actually install the rules.
#   bash laptop-bringup.sh              # report only
#   sudo bash laptop-bringup.sh --write-udev
set -u
WRITE_UDEV=0
[ "${1:-}" = "--write-udev" ] && WRITE_UDEV=1

sec() { echo; echo "===== $1 ====="; }

sec "1. OS"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
echo "kernel: $(uname -r)   arch: $(uname -m)"

sec "2. ROS 2"
if [ -n "${ROS_DISTRO:-}" ]; then
  echo "ROS_DISTRO=$ROS_DISTRO (already sourced)"
else
  for d in /opt/ros/*; do
    [ -d "$d" ] && echo "found: $d  -> source $d/setup.bash"
  done
  [ -d /opt/ros ] || echo "NO /opt/ros — ROS 2 not installed here"
fi
command -v ros2 >/dev/null && ros2 --version 2>/dev/null

sec "3. ROSBRIDGE (how the board talks ROS without installing ROS)"
if [ -n "${ROS_DISTRO:-}" ] && [ -d "/opt/ros/$ROS_DISTRO/share/rosbridge_server" ]; then
  echo "rosbridge_server: present"
  echo "  launch with: ros2 launch rosbridge_server rosbridge_websocket_launch.xml"
else
  echo "rosbridge_server: NOT found"
  echo "  install: sudo apt install -y ros-\${ROS_DISTRO}-rosbridge-suite"
fi

sec "4. LEROBOT"
python3 - <<'PY' 2>/dev/null || echo "lerobot not importable in this python"
import importlib.util as u
for name in ("lerobot", "feetech_servo_sdk", "scservo_sdk", "dynamixel_sdk"):
    spec = u.find_spec(name)
    print(f"  {name:20s} {'OK  ' + (spec.origin or '') if spec else 'missing'}")
PY
command -v conda >/dev/null && echo "conda envs:" && conda env list 2>/dev/null | head -6

sec "5. SERIAL DEVICES (the SO-101 bus is one of these)"
if [ -d /dev/serial/by-id ]; then
  ls -l /dev/serial/by-id/ | sed 's/^/  /'
else
  echo "  no /dev/serial/by-id — is the arm plugged in and powered?"
fi
for d in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$d" ] || continue
  echo "--- $d"
  udevadm info -q property -n "$d" 2>/dev/null \
    | grep -E '^(ID_VENDOR_ID|ID_MODEL_ID|ID_SERIAL_SHORT|ID_VENDOR|ID_MODEL)=' | sed 's/^/    /'
done

sec "6. CAMERAS"
command -v v4l2-ctl >/dev/null || echo "  v4l2-ctl missing: sudo apt install -y v4l-utils"
v4l2-ctl --list-devices 2>/dev/null | sed 's/^/  /'
for d in /dev/video*; do
  [ -e "$d" ] || continue
  v4l2-ctl -d "$d" --all 2>/dev/null | grep -q 'Video Capture' || continue
  echo "--- $d (capture)"
  udevadm info -q property -n "$d" 2>/dev/null \
    | grep -E '^(ID_VENDOR_ID|ID_MODEL_ID|ID_SERIAL_SHORT|ID_MODEL)=' | sed 's/^/    /'
done

sec "7. AUDIO CAPTURE (webcam mic / Rapoo headset)"
arecord -l 2>/dev/null | sed 's/^/  /' || echo "  arecord missing"
echo "  pin by CARD= name, never by index"

sec "8. PERMISSIONS"
if id -nG "$USER" | grep -qw dialout; then
  echo "  $USER is in dialout — good"
else
  echo "  $USER NOT in dialout. Fix:  sudo usermod -aG dialout $USER   (log out/in after)"
fi

sec "9. UDEV RULES"
RULE=/etc/udev/rules.d/99-mira.rules
ARM_SERIAL=""
CAM_SERIAL=""
for d in /dev/ttyUSB* /dev/ttyACM*; do
  [ -e "$d" ] || continue
  s=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p')
  [ -n "$s" ] && { ARM_SERIAL="$s"; break; }
done
for d in /dev/video*; do
  [ -e "$d" ] || continue
  v4l2-ctl -d "$d" --all 2>/dev/null | grep -q 'Video Capture' || continue
  s=$(udevadm info -q property -n "$d" 2>/dev/null | sed -n 's/^ID_SERIAL_SHORT=//p')
  [ -n "$s" ] && { CAM_SERIAL="$s"; break; }
done

echo "  arm serial:    ${ARM_SERIAL:-<none found>}"
echo "  camera serial: ${CAM_SERIAL:-<none found>}"

if [ -z "$ARM_SERIAL" ] && [ -z "$CAM_SERIAL" ]; then
  echo "  Nothing to pin yet — plug in the arm and camera, then re-run."
elif [ "$WRITE_UDEV" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "  --write-udev needs root"; exit 1; }
  {
    echo "# Mira — stable device names. Generated $(date -Is)"
    [ -n "$ARM_SERIAL" ] && \
      echo "SUBSYSTEM==\"tty\", ATTRS{serial}==\"$ARM_SERIAL\", SYMLINK+=\"mira_arm_bus\", MODE=\"0660\", GROUP=\"dialout\""
    [ -n "$CAM_SERIAL" ] && \
      echo "SUBSYSTEM==\"video4linux\", ATTRS{serial}==\"$CAM_SERIAL\", ATTR{index}==\"0\", SYMLINK+=\"mira_cam\", MODE=\"0660\", GROUP=\"video\""
  } > "$RULE"
  cat "$RULE" | sed 's/^/    /'
  udevadm control --reload-rules && udevadm trigger
  sleep 2
  echo "  --- resulting symlinks ---"
  ls -l /dev/mira_* 2>/dev/null | sed 's/^/    /' || echo "    none yet (replug the device)"
else
  echo "  (report only — re-run with: sudo bash $0 --write-udev)"
fi

sec "10. CAMERA STABILITY — do this before any data collection"
cat <<'NOTE'
  Autofocus hunting silently ruins learned-policy input: the same scene looks
  different frame to frame. Lock focus, exposure and white balance:

    v4l2-ctl -d /dev/mira_cam --set-ctrl=focus_automatic_continuous=0
    v4l2-ctl -d /dev/mira_cam --set-ctrl=focus_absolute=<value>
    v4l2-ctl -d /dev/mira_cam --set-ctrl=auto_exposure=1
    v4l2-ctl -d /dev/mira_cam --set-ctrl=exposure_time_absolute=<value>
    v4l2-ctl -d /dev/mira_cam --set-ctrl=white_balance_automatic=0

  List what your camera actually supports first:
    v4l2-ctl -d /dev/mira_cam --list-ctrls
NOTE

sec "DONE"
