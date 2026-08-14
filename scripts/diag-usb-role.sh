#!/bin/bash
# Mira — why does the board see no USB devices? Is the port host or device?
# Read-only diagnosis. Run: ssh mira-wifi bash -s < this-file
sec() { echo; echo "===== $1 ====="; }

sec "1. USB-C PORT ROLES (the key question)"
for p in /sys/class/typec/port*; do
  [ -e "$p" ] || continue
  echo "--- $(basename "$p")"
  for f in data_role power_role power_operation_mode port_type vconn_source orientation; do
    [ -r "$p/$f" ] && printf '  %-22s %s\n' "$f:" "$(cat "$p/$f" 2>/dev/null)"
  done
done
[ -e /sys/class/typec/port0 ] || echo "NO /sys/class/typec — no Type-C port manager exposed"

sec "2. USB ROLE SWITCH (host vs device)"
for r in /sys/class/usb_role/*; do
  [ -e "$r" ] || continue
  echo "$(basename "$r"): $(cat "$r/role" 2>/dev/null)"
done
[ -e /sys/class/usb_role ] || echo "NO /sys/class/usb_role"

sec "3. CONTROLLER MODE (dwc3 / chipidea)"
for d in /sys/kernel/debug/usb/*/mode /sys/bus/platform/drivers/dwc3/*/mode; do
  [ -r "$d" ] && echo "$d = $(cat "$d" 2>/dev/null)"
done
ls -d /sys/bus/platform/devices/*usb* 2>/dev/null
cat /sys/bus/platform/devices/*.usb/dr_mode 2>/dev/null || echo "(no dr_mode attribute)"

sec "4. GADGET STILL BOUND? (if bound, the port is in DEVICE mode)"
for g in /sys/kernel/config/usb_gadget/*; do
  [ -e "$g" ] || continue
  echo "$(basename "$g") UDC='$(cat "$g/UDC" 2>/dev/null)'"
  ls "$g/functions" 2>/dev/null | sed 's/^/  function: /'
done

sec "5. HOST CONTROLLERS PRESENT"
ls -1 /sys/bus/usb/devices/ 2>/dev/null
echo "--- xhci/ehci drivers loaded ---"
lsmod 2>/dev/null | grep -iE 'xhci|ehci|dwc3|phy' || echo "(lsmod empty or modules built in)"

sec "6. KERNEL MESSAGES ABOUT USB / TYPEC / ROLE"
dmesg 2>/dev/null | grep -iE 'typec|dwc3|role|otg|xhci|usb .*(new|disconnect)|vbus' | tail -30 \
  || echo "dmesg unreadable"

sec "7. UVC / USB AUDIO DRIVERS AVAILABLE AT ALL?"
for m in uvcvideo snd_usb_audio; do
  if lsmod 2>/dev/null | grep -q "^$m"; then echo "$m: loaded"
  elif modinfo "$m" >/dev/null 2>&1; then echo "$m: available, NOT loaded (no device yet)"
  else echo "$m: NOT AVAILABLE in this kernel"; fi
done

sec "8. CAN WE FORCE HOST MODE? (candidate writable knobs)"
for f in /sys/class/typec/port0/port_type /sys/class/usb_role/*/role; do
  [ -w "$f" ] && echo "WRITABLE: $f (current: $(cat "$f" 2>/dev/null))"
done
echo "(nothing listed = role cannot be forced from sysfs on this image)"

sec "DONE"
