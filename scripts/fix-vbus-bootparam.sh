#!/bin/bash
# Mira — make the UNO Q actually power its USB port.
#
# WHY: dmesg shows "usb_vbus: disabling" ~33s into boot. The kernel switches off
# regulators nothing has claimed. The boot options already carry
# clk_ignore_unused and pd_ignore_unused but NOT regulator_ignore_unused, so the
# USB VBUS rail gets turned off and no device can ever enumerate.
#
# Also removes the boot counter from the 7.0.0 entry: that kernel has now proven
# it boots and brings up Wi-Fi, so it should stop being treated as on-trial.
# 6.16 stays installed as an escape hatch.
#
# Run:  ssh mira-wifi bash -s < scripts/fix-vbus-bootparam.sh
set -u
E=/boot/efi/loader/entries
CLEAN="85adc26bc84c4bb7b58a46921435ad66-7.0.0-g122c2c22d838.conf"

echo "=== entries before ==="
ls -1 "$E"

echo
echo "=== 1. drop the boot counter from 7.0.0 ==="
F=$(ls "$E" | grep '7\.0\.0' | head -1)
if [ -z "$F" ]; then echo "FATAL: no 7.0.0 entry found"; exit 1; fi
if [ "$F" != "$CLEAN" ]; then
  mv "$E/$F" "$E/$CLEAN" && echo "  $F -> $CLEAN"
else
  echo "  already clean"
fi

echo
echo "=== 2. add regulator_ignore_unused ==="
if grep -q 'regulator_ignore_unused' "$E/$CLEAN"; then
  echo "  already present"
else
  sed -i 's/^\(options .*\)$/\1 regulator_ignore_unused/' "$E/$CLEAN" && echo "  added"
fi
grep '^options' "$E/$CLEAN"

echo
echo "=== 3. escape hatch check ==="
if [ -f "$E/85adc26bc84c4bb7b58a46921435ad66-6.16.0-geffa8626771a.conf" ]; then
  echo "  OK: 6.16 entry still present"
else
  echo "  WARNING: 6.16 fallback missing"
fi

echo
echo "=== 4. re-enable normal boot blessing ==="
systemctl unmask systemd-bless-boot.service 2>&1 | tail -1

sync; sync
echo
echo "DONE. Power-cycle the board, then tell Claude."
