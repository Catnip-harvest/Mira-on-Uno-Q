#!/usr/bin/env python3
"""
Mira — host heartbeat sender. Runs on the LAPTOP (Ubuntu 22.04 / ROS 2 box).

WHAT IT DOES
    Sends a checksummed heartbeat to the UNO Q at 20 Hz. While it runs and the
    network holds, the MCU keeps the servo relay closed. Stop it, kill it, or
    pull the Wi-Fi and the arm de-energises within ~250 ms.

DEMO USE
    Terminal 1 (laptop):   python3 mira_heartbeat.py --host Mira.local --arm
    Then, to show the interlock: pull the network, or press Ctrl-C.

    The point of the demo is that NOTHING has to go right for the arm to stop.
    Everything going wrong is what stops it.
"""

import argparse
import logging
import socket
import sys
import threading
import time

LOG = logging.getLogger("mira-heartbeat")


def crc8(data: bytes) -> int:
    """CRC-8/ATM, poly 0x07, init 0x00, MSB-first. Matches MCU and bridge."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def build_frame(verb: str, seq: int) -> bytes:
    payload = f"M,{verb},{seq}".encode()
    return payload + f",{crc8(payload):02X}".encode()


class StatusListener(threading.Thread):
    """Prints MCU state changes so the operator can see the interlock's view."""

    STATES = {"0": "SAFE", "1": "ARMED", "2": "FAULT"}
    FAULTS = {1: "HEARTBEAT_LOST", 2: "ESTOP", 4: "BAD_FRAMES", 8: "ARM_REFUSED"}

    def __init__(self, port: int):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", port))
        self.sock.settimeout(1.0)
        self.last = None
        self.running = True

    def run(self):
        while self.running:
            try:
                data, _ = self.sock.recvfrom(256)
            except socket.timeout:
                continue
            fields = data.decode(errors="replace").strip().split(",")
            if len(fields) < 8 or fields[1] != "ST":
                continue
            state = self.STATES.get(fields[2], "?")
            relay = "CLOSED" if fields[6] == "1" else "OPEN"
            try:
                flags = int(fields[7])
            except ValueError:
                flags = 0
            reasons = [name for bit, name in self.FAULTS.items() if flags & bit]
            summary = f"{state} relay={relay}" + (f" [{', '.join(reasons)}]" if reasons else "")
            if summary != self.last:
                LOG.warning("MCU: %s", summary)
                self.last = summary


def main():
    ap = argparse.ArgumentParser(description="Mira interlock heartbeat (laptop side)")
    ap.add_argument("--host", required=True, help="UNO Q address, e.g. Mira.local")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--status-port", type=int, default=9001)
    ap.add_argument("--rate", type=float, default=20.0, help="heartbeats per second")
    ap.add_argument("--arm", action="store_true", help="send ARM once heartbeats are flowing")
    ap.add_argument("--reset", action="store_true", help="clear a latched fault, then exit")
    ap.add_argument("--disarm", action="store_true", help="disarm immediately, then exit")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = (args.host, args.port)
    seq = 0

    if args.disarm or args.reset:
        verb = "DIS" if args.disarm else "RST"
        sock.sendto(build_frame(verb, seq), target)
        LOG.info("sent %s to %s:%d", verb, args.host, args.port)
        return

    listener = StatusListener(args.status_port)
    listener.start()

    period = 1.0 / args.rate
    armed_sent = False
    # The MCU refuses to arm unless heartbeats are ALREADY fresh, so let a few
    # land before asking. Arming into silence is exactly what it should reject.
    arm_after = time.monotonic() + 0.5

    LOG.info("heartbeat -> %s:%d at %.0f Hz. Ctrl-C drops the rail.",
             args.host, args.port, args.rate)

    try:
        next_send = time.monotonic()
        while True:
            now = time.monotonic()
            if now < next_send:
                time.sleep(min(period, next_send - now))
                continue
            next_send += period

            seq = (seq + 1) & 0xFFFF
            sock.sendto(build_frame("HB", seq), target)

            if args.arm and not armed_sent and time.monotonic() >= arm_after:
                sock.sendto(build_frame("ARM", seq), target)
                armed_sent = True
                LOG.info("ARM sent")
    except KeyboardInterrupt:
        LOG.warning("stopping - heartbeat ends, MCU opens the relay within ~250 ms")
        listener.running = False


if __name__ == "__main__":
    main()
