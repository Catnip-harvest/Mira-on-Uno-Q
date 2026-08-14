#!/bin/bash
# Mira — add an STS3215 torque (force) cap to the teleop stack.
#
# WHY
#   teleop.py already caps SPEED (MAX_STEP = 60 counts/tick). It does not cap
#   FORCE. A speed-limited servo can still stall at full torque against a table,
#   a person, or itself -- slowly, and with all 30 kg.cm available. Those are two
#   different protections and only one was present.
#
# REGISTERS (verified against huggingface/lerobot STS_SMS_SERIES_CONTROL_TABLE,
# not guessed):
#   Torque_Limit      48, 2 bytes, RAM     <- what we write
#   Max_Torque_Limit  16, 2 bytes, EEPROM  <- deliberately NOT written
#
#   We write the RAM register on purpose. It resets to the EEPROM value on every
#   power cycle, which means the cap must be re-applied by the software that
#   drives the arm. That is the safe failure direction: no silent persistence,
#   no surprise when someone runs a different script.
#
#   EEPROM writes also need the Lock register (55) cleared first and wear the
#   cell. Not worth it for a value we want re-asserted each run anyway.
#
# Idempotent. Backs up both files before touching them.
set -euo pipefail
D=/home/arduino/teleop
STAMP=$(date +%Y%m%d-%H%M%S)

cd "$D"
cp feetech.py "feetech.py.bak-$STAMP"
cp teleop.py  "teleop.py.bak-$STAMP"
echo "backed up with suffix .bak-$STAMP"

# ---------------------------------------------------------------- feetech.py
python3 - <<'PY'
import re, pathlib
p = pathlib.Path('/home/arduino/teleop/feetech.py')
s = p.read_text()

if 'ADDR_TORQUE_LIMIT' in s:
    print('feetech.py: already patched')
else:
    # register addresses, next to the others
    s = s.replace(
        "ADDR_PRESENT_TEMPERATURE = 63",
        "ADDR_PRESENT_TEMPERATURE = 63\n"
        "ADDR_TORQUE_LIMIT = 48        # RAM, 2 bytes, 0..1000 (0.1% of max torque)\n"
        "ADDR_MAX_TORQUE_LIMIT = 16    # EEPROM, 2 bytes -- we do NOT write this\n"
        "TORQUE_LIMIT_MAX = 1000"
    )
    # write_word: the bus had no way to write a 2-byte register at all
    s = s.replace(
        "    def read_positions(self, ids):",
        "    def write_word(self, servo_id, address, value):\n"
        "        \"\"\"Write a 2-byte register, low byte first (Feetech is little-endian).\"\"\"\n"
        "        value = int(value) & 0xFFFF\n"
        "        self._send(servo_id, INST_WRITE,\n"
        "                   bytes([address, value & 0xFF, (value >> 8) & 0xFF]))\n"
        "        return self._read_status(0) is not None\n"
        "\n"
        "    def set_torque_limit(self, ids, permille):\n"
        "        \"\"\"Cap how hard the servos may push. 0..1000 = 0..100% of rated torque.\n"
        "\n"
        "        Writes the RAM register (48), which resets on power cycle -- so the cap\n"
        "        must be re-applied by whatever drives the arm. That is deliberate: a\n"
        "        cap that silently persists in EEPROM would make a different script\n"
        "        behave differently depending on history.\n"
        "\n"
        "        Returns {id: applied_value_or_None}; None means the servo did not ack.\n"
        "        \"\"\"\n"
        "        permille = max(0, min(TORQUE_LIMIT_MAX, int(permille)))\n"
        "        out = {}\n"
        "        for servo_id in ids:\n"
        "            ok = self.write_word(servo_id, ADDR_TORQUE_LIMIT, permille)\n"
        "            out[servo_id] = self.read_word(servo_id, ADDR_TORQUE_LIMIT) if ok else None\n"
        "        return out\n"
        "\n"
        "    def read_positions(self, ids):"
    )
    p.write_text(s)
    print('feetech.py: patched (write_word + set_torque_limit)')
PY

# ----------------------------------------------------------------- teleop.py
python3 - <<'PY'
import pathlib
p = pathlib.Path('/home/arduino/teleop/teleop.py')
s = p.read_text()

if 'TORQUE_LIMIT_PERMILLE' in s:
    print('teleop.py: already patched')
else:
    s = s.replace(
        "MAX_TEMP = 65",
        "MAX_TEMP = 65\n"
        "# Force cap, 0..1000 = 0..100% of rated torque. 350 is enough to hold the\n"
        "# arm's own weight and track the leader, and low enough that it stalls\n"
        "# rather than crushing. RAISE ONLY AFTER a supervised run says it is\n"
        "# too weak -- never as a first response to sagging.\n"
        "TORQUE_LIMIT_PERMILLE = 350"
    )
    # Apply the cap BEFORE torque is ever enabled.
    s = s.replace(
        '            print(f"Easing follower onto the leader pose over {APPROACH_TIME}s...")\n'
        "            follower.set_torque(JOINTS, True)",
        '            applied = follower.set_torque_limit(JOINTS, TORQUE_LIMIT_PERMILLE)\n'
        '            missed = [i for i, v in applied.items() if v is None]\n'
        '            if missed:\n'
        '                sys.exit(\n'
        '                    f"Refusing to run: torque limit not accepted by joints {missed}. "\n'
        '                    "The arm would move at full force."\n'
        '                )\n'
        '            print(f"Torque limit {TORQUE_LIMIT_PERMILLE}/1000 on all joints: "\n'
        '                  + ", ".join(f"{JOINT_NAMES[i]}={applied[i]}" for i in JOINTS))\n'
        '            print(f"Easing follower onto the leader pose over {APPROACH_TIME}s...")\n'
        "            follower.set_torque(JOINTS, True)"
    )
    p.write_text(s)
    print('teleop.py: patched (cap applied before torque enable, hard-fails if refused)')
PY

echo
echo "=== syntax check ==="
python3 -m py_compile feetech.py teleop.py && echo "  both compile"

echo
echo "=== what changed ==="
diff -u "feetech.py.bak-$STAMP" feetech.py | head -45 || true
echo "---"
diff -u "teleop.py.bak-$STAMP" teleop.py | head -30 || true
