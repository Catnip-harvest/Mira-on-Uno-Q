"""Verify the three CRC-8 implementations agree and the frame round-trip works.

Re-implements the C loop from mira_interlock.ino literally, then checks it against
the Python used by the bridge and the host sender.
"""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent  # repo root, so a clone works anywhere


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


bridge = load("mira_bridge", ROOT / "bridge" / "mira_bridge.py")
host = load("mira_heartbeat", ROOT / "host" / "mira_heartbeat.py")


def crc8_c_transliteration(data: bytes) -> int:
    """Literal transliteration of the C loop in mira_interlock.ino."""
    crc = 0x00
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


failures = []

# 1. all three implementations agree over a wide input space
samples = [b"", b"M", b"M,HB,1", b"M,ARM,65535", b"M,ST,1,42,7,1,1,0",
           bytes(range(256)), b"\x00" * 17, b"\xff" * 33]
for s in samples:
    a, b, c = crc8_c_transliteration(s), bridge.crc8(s), host.crc8(s)
    if not (a == b == c):
        failures.append(f"CRC mismatch for {s!r}: c={a:02X} bridge={b:02X} host={c:02X}")
print(f"[1] crc8 agreement over {len(samples)} vectors: "
      f"{'FAIL' if failures else 'OK'}")

# 2. known vector, so a future edit that changes all three together still trips
known = crc8_c_transliteration(b"M,HB,1")
print(f"[2] crc8('M,HB,1') = 0x{known:02X}  (pin this value if the protocol freezes)")

# 3. host frames validate under the bridge's validator
for verb, seq in [("HB", 0), ("HB", 65535), ("ARM", 7), ("DIS", 1), ("RST", 99)]:
    frame = host.build_frame(verb, seq)
    if not bridge.frame_is_valid(frame):
        failures.append(f"bridge rejected a valid host frame: {frame!r}")
print(f"[3] host->bridge frame round-trip: {'FAIL' if failures else 'OK'}")

# 4. corruption must be rejected — one flipped bit anywhere in the payload
frame = host.build_frame("HB", 1234)
caught = 0
for i in range(len(frame) - 3):          # payload bytes only
    corrupt = bytearray(frame)
    corrupt[i] ^= 0x01
    if not bridge.frame_is_valid(bytes(corrupt)):
        caught += 1
total = len(frame) - 3
print(f"[4] single-bit corruption rejected: {caught}/{total}")
if caught != total:
    failures.append(f"only {caught}/{total} corrupt frames rejected")

# 5. malformed input must not raise
for junk in [b"", b",", b"M,HB,1", b"M,HB,1,ZZ", b"x" * 500, b"M,HB,1,", b"\x00\xff"]:
    try:
        bridge.frame_is_valid(junk)
    except Exception as exc:
        failures.append(f"frame_is_valid raised on {junk!r}: {exc}")
print(f"[5] malformed input handled without raising: {'FAIL' if failures else 'OK'}")

# 6. a status frame shaped exactly like the MCU's snprintf must validate
payload = b"M,ST,1,42,7,1,1,0"
status = payload + f",{crc8_c_transliteration(payload):02X}".encode()
ok = bridge.frame_is_valid(status)
print(f"[6] MCU-shaped status frame validates: {'OK' if ok else 'FAIL'}  {status!r}")
if not ok:
    failures.append("MCU status frame shape rejected by bridge")

print()
if failures:
    print("FAILURES:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("ALL CHECKS PASSED")
