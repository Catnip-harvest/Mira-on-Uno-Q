#!/usr/bin/env python3
"""
Mira — interlock bridge. Runs on the UNO Q's Linux side (QRB2210).

WHAT IT DOES
    Forwards heartbeat and command frames from the laptop (UDP, Wi-Fi) to the
    STM32 over the internal UART, and relays MCU status back to the laptop.

THE ONE RULE
    This process NEVER generates a heartbeat of its own. It only forwards frames
    that actually arrived from the laptop and passed CRC. If the laptop stops,
    the Wi-Fi drops, or this process is killed, the MCU stops hearing heartbeats
    and opens the relay. Any "helpful" retry, buffer or keepalive here would
    defeat the entire interlock -- do not add one.

PORT OWNERSHIP
    /dev/ttyHS1 is normally held open by arduino-router. Stop it first:
        sudo systemctl stop arduino-router
    We take the UART directly so no third-party broker sits in the safety path.

USAGE
    sudo python3 mira_bridge.py --serial /dev/ttyHS1 --listen 0.0.0.0:9000
"""

import argparse
import logging
import selectors
import socket
import sys
import time

try:
    import serial  # python3-serial (installed via apt)
except ImportError:
    # Deferred to main() so the pure-protocol functions below stay importable
    # and testable on a machine without pyserial.
    serial = None

LOG = logging.getLogger("mira-bridge")

# Frames larger than this are noise, not protocol.
MAX_FRAME = 128


def crc8(data: bytes) -> int:
    """CRC-8/ATM, poly 0x07, init 0x00, MSB-first.

    Byte-for-byte identical to crc8() in firmware/mira_interlock.ino. Both ends
    must reject exactly the same corrupt frames or the interlock is theatre.
    """
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def frame_is_valid(line: bytes) -> bool:
    """True when the trailing ,<hex crc> matches the payload before it."""
    if not line or len(line) > MAX_FRAME:
        return False
    split = line.rfind(b",")
    if split <= 0:
        return False
    payload, checksum = line[:split], line[split + 1:]
    try:
        return crc8(payload) == int(checksum, 16)
    except ValueError:
        return False


class Bridge:
    def __init__(self, serial_port: str, baud: int, listen: tuple, status_port: int):
        self.mcu = serial.Serial(serial_port, baud, timeout=0)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(listen)
        self.sock.setblocking(False)
        self.status_port = status_port

        # Where to send MCU status back to. Learned from whoever last sent us a
        # valid frame, so the laptop's DHCP address never needs configuring.
        self.peer = None

        self.mcu_buffer = bytearray()
        self.forwarded = 0
        self.rejected = 0
        self.last_report = time.monotonic()
        self.last_state = None

    # ---------------------------------------------------------------- laptop
    def on_udp(self):
        try:
            data, addr = self.sock.recvfrom(512)
        except BlockingIOError:
            return

        line = data.strip()
        if not frame_is_valid(line):
            self.rejected += 1
            return

        # Only a validated frame is allowed to teach us where the laptop is;
        # otherwise a stray packet could redirect our status stream.
        self.peer = addr
        self.mcu.write(line + b"\n")
        self.forwarded += 1

    # ------------------------------------------------------------------- mcu
    def on_serial(self):
        chunk = self.mcu.read(512)
        if not chunk:
            return
        self.mcu_buffer.extend(chunk)

        while b"\n" in self.mcu_buffer:
            raw, _, rest = self.mcu_buffer.partition(b"\n")
            self.mcu_buffer = bytearray(rest)
            line = raw.strip()
            if not frame_is_valid(line):
                continue
            self.report_state(line)
            if self.peer:
                self.sock.sendto(line, (self.peer[0], self.status_port))

        if len(self.mcu_buffer) > MAX_FRAME * 4:
            self.mcu_buffer.clear()  # desynchronised; resync on next newline

    def report_state(self, line: bytes):
        """Log only on transition, so the journal shows the story not the noise."""
        fields = line.split(b",")
        if len(fields) < 3 or fields[1] != b"ST":
            return
        names = {b"0": "SAFE", b"1": "ARMED", b"2": "FAULT"}
        state = names.get(fields[2], "?")
        if state != self.last_state:
            LOG.warning("MCU state -> %s   (%s)", state, line.decode(errors="replace"))
            self.last_state = state

    # ------------------------------------------------------------------ loop
    def run(self):
        sel = selectors.DefaultSelector()
        sel.register(self.sock, selectors.EVENT_READ, self.on_udp)
        sel.register(self.mcu, selectors.EVENT_READ, self.on_serial)

        LOG.info("bridge up: udp %s -> %s", self.sock.getsockname(), self.mcu.port)
        LOG.info("this process never invents a heartbeat; silence means relay opens")

        while True:
            for key, _ in sel.select(timeout=1.0):
                key.data()

            now = time.monotonic()
            if now - self.last_report >= 10.0:
                LOG.info("forwarded=%d rejected=%d peer=%s",
                         self.forwarded, self.rejected, self.peer)
                self.last_report = now


def parse_endpoint(text: str) -> tuple:
    host, _, port = text.rpartition(":")
    return (host or "0.0.0.0", int(port))


def main():
    ap = argparse.ArgumentParser(description="Mira interlock bridge (UNO Q Linux side)")
    ap.add_argument("--serial", default="/dev/ttyHS1", help="UART to the STM32")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--listen", default="0.0.0.0:9000", help="UDP listen host:port")
    ap.add_argument("--status-port", type=int, default=9001,
                    help="UDP port on the laptop to send MCU status to")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
    )

    if serial is None:
        sys.exit("pyserial missing: sudo apt install -y python3-serial")

    try:
        bridge = Bridge(args.serial, args.baud, parse_endpoint(args.listen),
                        args.status_port)
    except serial.SerialException as exc:
        sys.exit(f"cannot open {args.serial}: {exc}\n"
                 f"is arduino-router still holding it?  "
                 f"sudo systemctl stop arduino-router")

    try:
        bridge.run()
    except KeyboardInterrupt:
        LOG.warning("bridge stopping - MCU will time out and open the relay")


if __name__ == "__main__":
    main()
