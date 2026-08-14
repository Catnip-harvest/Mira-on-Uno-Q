#!/usr/bin/env python3
"""
Mock SO-101 servo bus — develop without the real arm.

Creates a virtual serial port that speaks the Feetech STS/SCS protocol, so
teleop.py, IK code and XR code talk to it exactly as they would the real bus.
Nothing in the robot code changes; you just point it at a different port.

    python3 tools/mock_arm.py
    # prints e.g.  MOCK BUS READY: /dev/ttys004
    # then, in another terminal:
    python3 teleop.py scan --port /dev/ttys004

macOS and Linux only — it uses a pty. On Windows use WSL, or run the self-test
below, which needs no serial port at all.

    python3 tools/mock_arm.py --self-test

WHAT IT DOES AND DOESN'T DO
    Does:    ping, read/write registers, sync-write goals, torque enable,
             torque limit, voltage/temperature, positions that ease toward goals.
    Doesn't: physics, collisions, gravity, current draw, or any reason to
             believe the real arm will behave the same. It proves your protocol
             and control flow are right, not that your motion is safe.
"""

import argparse
import os
import sys
import time

# --- STS3215 control table (matches firmware and LeRobot) -------------------
ADDR_ID                  = 5
ADDR_MAX_TORQUE_LIMIT    = 16
ADDR_TORQUE_ENABLE       = 40
ADDR_GOAL_POSITION       = 42
ADDR_TORQUE_LIMIT        = 48
ADDR_PRESENT_POSITION    = 56
ADDR_PRESENT_VOLTAGE     = 62
ADDR_PRESENT_TEMPERATURE = 63

INST_PING       = 1
INST_READ       = 2
INST_WRITE      = 3
INST_SYNC_WRITE = 0x83

BROADCAST_ID = 0xFE
RESOLUTION   = 4096
CENTRE       = RESOLUTION // 2

# How fast a mock joint closes on its goal, in counts per update. Deliberately
# finite so code that assumes instant movement shows up as a bug here rather
# than on real hardware.
EASE_COUNTS_PER_TICK = 25


def checksum(payload: bytes) -> int:
    """(~sum) & 0xFF — the Feetech/protocol-1.0 checksum."""
    return (~sum(payload)) & 0xFF


class MockServo:
    def __init__(self, servo_id: int):
        self.id = servo_id
        self.position = CENTRE
        self.goal = CENTRE
        self.torque_enabled = False
        self.torque_limit = 1000
        self.voltage_decivolts = 120   # 12.0 V
        self.temperature_c = 31

    def step(self):
        """Ease toward the goal, but only while torque is on — like the real thing."""
        if not self.torque_enabled:
            return
        delta = self.goal - self.position
        if abs(delta) <= EASE_COUNTS_PER_TICK:
            self.position = self.goal
        else:
            self.position += EASE_COUNTS_PER_TICK if delta > 0 else -EASE_COUNTS_PER_TICK

    def read(self, address: int, length: int):
        if address == ADDR_PRESENT_POSITION and length == 2:
            return [self.position & 0xFF, (self.position >> 8) & 0xFF]
        if address == ADDR_GOAL_POSITION and length == 2:
            return [self.goal & 0xFF, (self.goal >> 8) & 0xFF]
        if address == ADDR_TORQUE_LIMIT and length == 2:
            return [self.torque_limit & 0xFF, (self.torque_limit >> 8) & 0xFF]
        if address == ADDR_PRESENT_VOLTAGE and length == 1:
            return [self.voltage_decivolts]
        if address == ADDR_PRESENT_TEMPERATURE and length == 1:
            return [self.temperature_c]
        if address == ADDR_TORQUE_ENABLE and length == 1:
            return [1 if self.torque_enabled else 0]
        if address == ADDR_ID and length == 1:
            return [self.id]
        return [0] * length

    def write(self, address: int, data: list):
        if address == ADDR_TORQUE_ENABLE:
            self.torque_enabled = bool(data[0])
        elif address == ADDR_GOAL_POSITION and len(data) >= 2:
            self.goal = max(0, min(RESOLUTION - 1, data[0] | (data[1] << 8)))
        elif address == ADDR_TORQUE_LIMIT and len(data) >= 2:
            self.torque_limit = data[0] | (data[1] << 8)
        elif address == ADDR_MAX_TORQUE_LIMIT and len(data) >= 2:
            pass  # EEPROM; accepted and ignored


class MockBus:
    """Parses request bytes and produces reply bytes. No I/O — so it is testable."""

    def __init__(self, ids=(1, 2, 3, 4, 5, 6), verbose=True):
        self.servos = {i: MockServo(i) for i in ids}
        self.buffer = bytearray()
        self.verbose = verbose

    def _status(self, servo_id: int, params=()) -> bytes:
        length = len(params) + 2
        body = bytes([servo_id, length, 0]) + bytes(params)   # 0 = no error
        return b"\xff\xff" + body + bytes([checksum(body)])

    def feed(self, data: bytes) -> bytes:
        """Take incoming bytes, return whatever should be sent back."""
        self.buffer.extend(data)
        out = bytearray()

        while True:
            start = self.buffer.find(b"\xff\xff")
            if start < 0 or len(self.buffer) < start + 4:
                break
            servo_id = self.buffer[start + 2]
            length = self.buffer[start + 3]
            total = start + 4 + length          # header(2)+id+len + (instr+params+crc)
            if len(self.buffer) < total:
                break

            packet = bytes(self.buffer[start + 2: total])   # id, len, instr, params, crc
            del self.buffer[:total]

            body, crc = packet[:-1], packet[-1]
            if checksum(body) != crc:
                if self.verbose:
                    print("  ! bad checksum, ignored", file=sys.stderr)
                continue

            instruction = body[2]
            params = body[3:]
            out.extend(self._handle(servo_id, instruction, params))

        return bytes(out)

    def _handle(self, servo_id: int, instruction: int, params: bytes) -> bytes:
        if instruction == INST_PING:
            if servo_id in self.servos:
                if self.verbose:
                    print(f"  ping  id={servo_id} -> pong")
                return self._status(servo_id)
            return b""                                   # absent servo stays silent

        if instruction == INST_READ and len(params) >= 2:
            servo = self.servos.get(servo_id)
            if servo is None:
                return b""
            values = servo.read(params[0], params[1])
            return self._status(servo_id, values)

        if instruction == INST_WRITE and len(params) >= 1:
            servo = self.servos.get(servo_id)
            if servo is None:
                return b""
            servo.write(params[0], list(params[1:]))
            if self.verbose:
                print(f"  write id={servo_id} addr={params[0]} data={list(params[1:])}")
            return self._status(servo_id)

        if instruction == INST_SYNC_WRITE and len(params) >= 2:
            # params: addr, per_servo_len, then repeating [id, data...]
            address, per_len = params[0], params[1]
            body, stride, wrote = params[2:], 1 + per_len, []
            for off in range(0, len(body) - stride + 1, stride):
                sid = body[off]
                data = list(body[off + 1: off + 1 + per_len])
                if sid in self.servos:
                    self.servos[sid].write(address, data)
                    wrote.append(sid)
            if self.verbose:
                print(f"  sync_write addr={address} -> {wrote}")
            return b""                                   # sync-write sends no reply

        return b""

    def tick(self):
        for servo in self.servos.values():
            servo.step()


def run_pty(verbose: bool):
    """Expose the mock on a virtual serial port."""
    if not hasattr(os, "openpty"):
        sys.exit("pty unavailable on this OS — use macOS/Linux/WSL, or --self-test")

    master, slave = os.openpty()
    os.set_blocking(master, False)
    print(f"MOCK BUS READY: {os.ttyname(slave)}")
    print("6 servos, IDs 1-6, torque off, 12.0 V, 31 C")
    print("Point your robot code at that port. Ctrl-C to stop.\n")

    bus = MockBus(verbose=verbose)
    try:
        while True:
            try:
                data = os.read(master, 4096)
            except BlockingIOError:
                data = b""
            if data:
                reply = bus.feed(data)
                if reply:
                    os.write(master, reply)
            bus.tick()
            time.sleep(0.005)              # 200 Hz, faster than any caller
    except KeyboardInterrupt:
        print("\nmock bus stopped")
    finally:
        os.close(master)
        os.close(slave)


def self_test() -> int:
    """Exercise the protocol with no serial port — runs anywhere, including Windows."""
    failures = []
    bus = MockBus(verbose=False)

    def request(servo_id, instruction, params=b""):
        length = len(params) + 2
        body = bytes([servo_id, length, instruction]) + params
        return b"\xff\xff" + body + bytes([checksum(body)])

    def parse(reply):
        assert reply[:2] == b"\xff\xff", "bad header"
        sid, length, err = reply[2], reply[3], reply[4]
        params = reply[5:5 + length - 2]
        assert checksum(bytes([sid, length, err]) + params) == reply[-1], "bad crc"
        return sid, err, list(params)

    # 1. ping present and absent servos
    if not bus.feed(request(1, INST_PING)):
        failures.append("servo 1 did not answer ping")
    if bus.feed(request(99, INST_PING)):
        failures.append("absent servo 99 answered ping")
    print(f"[1] ping present/absent: {'FAIL' if failures else 'OK'}")

    # 2. read present position
    _, _, params = parse(bus.feed(request(1, INST_READ, bytes([ADDR_PRESENT_POSITION, 2]))))
    pos = params[0] | (params[1] << 8)
    print(f"[2] read position -> {pos} (expect {CENTRE})")
    if pos != CENTRE:
        failures.append(f"position {pos} != {CENTRE}")

    # 3. torque limit round-trip (the safety register)
    bus.feed(request(1, INST_WRITE, bytes([ADDR_TORQUE_LIMIT, 350 & 0xFF, 350 >> 8])))
    _, _, params = parse(bus.feed(request(1, INST_READ, bytes([ADDR_TORQUE_LIMIT, 2]))))
    limit = params[0] | (params[1] << 8)
    print(f"[3] torque limit round-trip -> {limit} (expect 350)")
    if limit != 350:
        failures.append(f"torque limit {limit} != 350")

    # 4. a joint must NOT move while torque is off
    goal = CENTRE + 500
    sync = bytes([ADDR_GOAL_POSITION, 2]) + bytes([1, goal & 0xFF, goal >> 8])
    bus.feed(request(BROADCAST_ID, INST_SYNC_WRITE, sync))
    for _ in range(50):
        bus.tick()
    _, _, params = parse(bus.feed(request(1, INST_READ, bytes([ADDR_PRESENT_POSITION, 2]))))
    still = params[0] | (params[1] << 8)
    print(f"[4] moves with torque OFF? -> position {still} (expect {CENTRE}, unmoved)")
    if still != CENTRE:
        failures.append("joint moved while torque was disabled")

    # 5. with torque on, it eases to the goal
    bus.feed(request(1, INST_WRITE, bytes([ADDR_TORQUE_ENABLE, 1])))
    for _ in range(100):
        bus.tick()
    _, _, params = parse(bus.feed(request(1, INST_READ, bytes([ADDR_PRESENT_POSITION, 2]))))
    moved = params[0] | (params[1] << 8)
    print(f"[5] reaches goal with torque ON -> {moved} (expect {goal})")
    if moved != goal:
        failures.append(f"position {moved} != goal {goal}")

    # 6. corrupt frames are rejected, not acted on
    bad = bytearray(request(1, INST_WRITE, bytes([ADDR_TORQUE_ENABLE, 0])))
    bad[-1] ^= 0xFF
    bus.feed(bytes(bad))
    _, _, params = parse(bus.feed(request(1, INST_READ, bytes([ADDR_TORQUE_ENABLE, 1]))))
    print(f"[6] corrupt frame ignored -> torque still {params[0]} (expect 1)")
    if params[0] != 1:
        failures.append("corrupt frame was acted on")

    print()
    if failures:
        print("FAILURES:")
        for f in failures:
            print("  -", f)
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Mock SO-101 servo bus")
    ap.add_argument("--self-test", action="store_true",
                    help="verify the protocol with no serial port (works on Windows)")
    ap.add_argument("-q", "--quiet", action="store_true", help="do not log each request")
    args = ap.parse_args()
    sys.exit(self_test() if args.self_test else run_pty(not args.quiet))
