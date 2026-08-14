#!/bin/bash
# Mira — make regulator_ignore_unused survive boot-entry regeneration.
#
# PROBLEM
#   We added regulator_ignore_unused to the 7.0.0 loader entry by editing the
#   generated .conf. Something later re-ran kernel-install, which rebuilt every
#   entry from Debian's template and silently discarded the edit. Result:
#   "usb_vbus: disabling" at boot, usb_vbus state=disabled, and no 5 V on the
#   USB-C port -- so no attached device can power up at all.
#
# FIX
#   Debian's 90-loaderentry.install reads /etc/kernel/cmdline when it exists and
#   uses it verbatim for the options line. Writing it there means every future
#   regeneration keeps our parameter.
#
# Run:  ssh mira-wifi bash /tmp/fix-vbus-durable.sh
set -u
E=/boot/efi/loader/entries
PARAM=regulator_ignore_unused

echo "=== 1. BUILD THE DESIRED CMDLINE ==="
# Start from what is actually booted, minus initrd= (kernel-install adds that).
BASE=$(tr ' ' '\n' < /proc/cmdline | grep -v '^initrd=' | grep -v "^$PARAM$" | tr '\n' ' ')
BASE=$(echo "$BASE" | sed 's/[[:space:]]*$//')
NEW="$BASE $PARAM"
echo "  $NEW"

echo
echo "=== 2. PERSIST IT FOR ALL FUTURE REGENERATIONS ==="
printf '%s\n' "$NEW" > /etc/kernel/cmdline
echo "  wrote /etc/kernel/cmdline:"
sed 's/^/    /' /etc/kernel/cmdline

echo
echo "=== 3. APPLY TO THE ENTRIES THAT EXIST NOW ==="
for f in "$E"/*.conf; do
  if grep -q "$PARAM" "$f"; then
    echo "  $(basename "$f"): already has it"
  else
    sed -i "s|^\(options .*\)$|\1 $PARAM|" "$f"
    echo "  $(basename "$f"): added"
  fi
done

echo
echo "=== 4. VERIFY ==="
grep -H '^options' "$E"/*.conf | sed 's|.*/||' | sed 's/^/  /'

echo
echo "=== 5. SANITY: fallback kernel still present? ==="
test -f "$E/85adc26bc84c4bb7b58a46921435ad66-6.16.0-geffa8626771a.conf" \
  && echo "  OK: 6.16 fallback entry intact" || echo "  WARNING: fallback missing"

sync; sync
echo
echo "DONE — power-cycle the board, then tell Claude."
echo "After reboot, /proc/cmdline must contain $PARAM and usb_vbus must read 'enabled'."
