"""Minimal Feetech STS/SCS servo driver (protocol 1.0) over a serial bus.

Covers exactly what teleop needs: ping, read/write registers, and a broadcast
sync-write so all follower joints move in one packet.

Register addresses verified against huggingface/lerobot's
STS_SMS_SERIES_CONTROL_TABLE. Do not change them from memory — check the table.

This file is mirrored at /home/arduino/teleop/feetech.py on the board. Keep the
two in sync; the repo copy is authoritative.
"""

import serial

# STS3215 control table
ADDR_ID = 5
ADDR_MAX_TORQUE_LIMIT = 16    # EEPROM, 2 bytes -- we do NOT write this
ADDR_TORQUE_ENABLE = 40
ADDR_GOAL_POSITION = 42
ADDR_TORQUE_LIMIT = 48        # RAM, 2 bytes, 0..1000 (0.1% of max torque)
ADDR_PRESENT_POSITION = 56
ADDR_PRESENT_VOLTAGE = 62
ADDR_PRESENT_TEMPERATURE = 63
TORQUE_LIMIT_MAX = 1000

INST_PING = 1
INST_READ = 2
INST_WRITE = 3
INST_SYNC_WRITE = 0x83

BROADCAST_ID = 0xFE
RESOLUTION = 4096  # counts per full revolution


def _checksum(payload):
    return (~sum(payload)) & 0xFF


class FeetechBus:
    def __init__(self, port, baudrate=1_000_000, timeout=0.02):
        self.ser = serial.Serial(port, baudrate, timeout=timeout, write_timeout=0.2)
        try:
            # Drops the FTDI/CH34x 16ms latency timer; without it we cap out
            # around 60Hz no matter how fast the bus is.
            self.ser.set_low_latency_mode(True)
        except (AttributeError, ValueError, OSError):
            pass
        self.port = port

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    def _send(self, servo_id, instruction, params=b""):
        length = len(params) + 2
        body = bytes([servo_id, length, instruction]) + bytes(params)
        self.ser.reset_input_buffer()
        self.ser.write(b"\xff\xff" + body + bytes([_checksum(body)]))
        self.ser.flush()

    def _read_status(self, expect_params=0):
        """Read one status packet, resyncing on the 0xFF 0xFF header."""
        header = self.ser.read(2)
        spins = 0
        while header != b"\xff\xff":
            if len(header) < 2:
                return None
            nxt = self.ser.read(1)
            if not nxt:
                return None
            header = header[1:] + nxt
            spins += 1
            if spins > 64:
                return None

        meta = self.ser.read(3)  # id, length, error
        if len(meta) < 3:
            return None
        servo_id, length, error = meta
        remaining = self.ser.read(length - 1)  # params + checksum
        if len(remaining) < length - 1:
            return None
        params = remaining[:-1]
        if _checksum(bytes([servo_id, length, error]) + params) != remaining[-1]:
            return None
        if len(params) != expect_params:
            return None
        return servo_id, error, params

    def ping(self, servo_id):
        self._send(servo_id, INST_PING)
        return self._read_status(0) is not None

    def scan(self, id_range=range(1, 21)):
        return [i for i in id_range if self.ping(i)]

    def read_byte(self, servo_id, address):
        self._send(servo_id, INST_READ, bytes([address, 1]))
        status = self._read_status(1)
        return None if status is None else status[2][0]

    def read_word(self, servo_id, address):
        self._send(servo_id, INST_READ, bytes([address, 2]))
        status = self._read_status(2)
        if status is None:
            return None
        low, high = status[2]
        return low | (high << 8)

    def write_byte(self, servo_id, address, value):
        self._send(servo_id, INST_WRITE, bytes([address, value & 0xFF]))
        return self._read_status(0) is not None

    def write_word(self, servo_id, address, value):
        """Write a 2-byte register, low byte first (Feetech is little-endian)."""
        value = int(value) & 0xFFFF
        self._send(servo_id, INST_WRITE,
                   bytes([address, value & 0xFF, (value >> 8) & 0xFF]))
        return self._read_status(0) is not None

    def set_torque_limit(self, ids, permille):
        """Cap how hard the servos may push. 0..1000 = 0..100% of rated torque.

        Writes the RAM register (48), which resets on power cycle -- so the cap
        must be re-applied by whatever drives the arm. That is deliberate: a cap
        that silently persists in EEPROM would make a different script behave
        differently depending on history.

        Returns {id: applied_value_or_None}; None means the servo did not ack.
        """
        permille = max(0, min(TORQUE_LIMIT_MAX, int(permille)))
        out = {}
        for servo_id in ids:
            ok = self.write_word(servo_id, ADDR_TORQUE_LIMIT, permille)
            out[servo_id] = self.read_word(servo_id, ADDR_TORQUE_LIMIT) if ok else None
        return out

    def read_positions(self, ids):
        """Present position per id; None for any servo that didn't answer."""
        return {i: self.read_word(i, ADDR_PRESENT_POSITION) for i in ids}

    def sync_write_positions(self, goals):
        """Broadcast goal positions -- one packet, no status replies."""
        params = bytearray([ADDR_GOAL_POSITION, 2])
        for servo_id, pos in goals.items():
            pos = max(0, min(RESOLUTION - 1, int(pos)))
            params += bytes([servo_id, pos & 0xFF, (pos >> 8) & 0xFF])
        self._send(BROADCAST_ID, INST_SYNC_WRITE, bytes(params))

    def set_torque(self, ids, enabled):
        ok = True
        for servo_id in ids:
            ok &= bool(self.write_byte(servo_id, ADDR_TORQUE_ENABLE, 1 if enabled else 0))
        return ok

    def health(self, ids):
        """Voltage (V) and temperature (C) per id, for the pre-flight check."""
        out = {}
        for servo_id in ids:
            volts = self.read_byte(servo_id, ADDR_PRESENT_VOLTAGE)
            temp = self.read_byte(servo_id, ADDR_PRESENT_TEMPERATURE)
            out[servo_id] = (None if volts is None else volts / 10.0, temp)
        return out
