#!/usr/bin/env python3
"""
Mira XR bridge — point your phone, the arm follows.

    phone (WebXR)  --->  this bridge  --->  SO-101 servo bus
                         pose -> joints

Two mapping modes. Start with `orientation`; move to `ik` only once that works.

  --mode orientation   Phone tilt drives 2-3 joints directly. No IK, no solver,
                       no URDF. Cannot fail to find a solution. For a camera
                       that follows where you point, it looks the same to an
                       audience.

  --mode ik            Full 6-DOF Cartesian via LeRobot's placo kinematics.
                       Needs the SO-101 URDF. SO-101 has 5 DOF plus gripper, so
                       some phone poses are unreachable -- those HOLD position.

Develop with no robot at all:

    python3 tools/mock_arm.py            # prints a virtual port
    python3 xr/mira_xr_bridge.py --port /dev/ttysNNN --mode orientation

Check the mapping maths with no phone and no robot:

    python3 xr/mira_xr_bridge.py --self-test

SAFETY
  * The torque cap is applied before torque is ever enabled. If any joint
    refuses it, this exits. Do not remove that check.
  * Every command is rate-limited to MAX_STEP counts per tick.
  * `move` false (finger off the screen), a lost connection, or an IK failure
    all HOLD position. Nothing ever jumps.
  * Cutting power to the BOARD does not stop the arm. The servos hold torque
    and go rigid. The emergency stop is the 12 V servo supply.
"""

import argparse
import math
import signal
import sys
import time

sys.path.insert(0, __file__.rsplit("xr", 1)[0])   # repo root, for arm/

JOINTS = [1, 2, 3, 4, 5, 6]
JOINT_NAMES = {1: "shoulder_pan", 2: "shoulder_lift", 3: "elbow_flex",
               4: "wrist_flex", 5: "wrist_roll", 6: "gripper"}

CENTRE = 2048                 # mid-travel, 4096 counts per revolution
COUNTS_PER_RAD = 4096 / (2 * math.pi)

MAX_STEP = 60                 # counts per tick -- caps follower speed
RATE_HZ = 50                  # command rate to the bus
TORQUE_LIMIT_PERMILLE = 350   # force cap; raise only after a supervised run
APPROACH_TIME = 3.0           # seconds easing onto the first target

# Orientation mode: how far each joint swings for a full phone rotation, and
# which joints move at all. Deliberately less than the mechanical range.
ORIENTATION_MAP = {
    1: ("yaw",   1.0, 900),   # joint: (phone axis, gain, max counts from centre)
    2: ("pitch", 1.0, 600),
    5: ("roll",  1.0, 700),
}


def quaternion_to_euler(w, x, y, z):
    """Return (roll, pitch, yaw) in radians. Standard aerospace convention."""
    sinr_cosp = 2 * (w * x + y * z)
    cosr_cosp = 1 - 2 * (x * x + y * y)
    roll = math.atan2(sinr_cosp, cosr_cosp)

    sinp = 2 * (w * y - z * x)
    pitch = math.copysign(math.pi / 2, sinp) if abs(sinp) >= 1 else math.asin(sinp)

    siny_cosp = 2 * (w * z + x * y)
    cosy_cosp = 1 - 2 * (y * y + z * z)
    yaw = math.atan2(siny_cosp, cosy_cosp)
    return roll, pitch, yaw


def orientation_to_joints(quat, origin_euler=None):
    """Map phone orientation straight onto a few joints. Never fails.

    quat: (w, x, y, z). origin_euler: the orientation captured when the user
    started moving, so the arm tracks change rather than absolute phone angle.
    Returns {joint_id: goal_counts}.
    """
    roll, pitch, yaw = quaternion_to_euler(*quat)
    if origin_euler:
        roll -= origin_euler[0]
        pitch -= origin_euler[1]
        yaw -= origin_euler[2]
    axes = {"roll": roll, "pitch": pitch, "yaw": yaw}

    goals = {}
    for joint, (axis, gain, span) in ORIENTATION_MAP.items():
        offset = axes[axis] * gain * COUNTS_PER_RAD
        offset = max(-span, min(span, offset))
        goals[joint] = int(CENTRE + offset)
    return goals


def rate_limit(current, goals, max_step=MAX_STEP):
    """Never move a joint more than max_step counts in one tick."""
    limited = {}
    for joint, goal in goals.items():
        now = current.get(joint, goal)
        delta = max(-max_step, min(max_step, goal - now))
        limited[joint] = now + delta
    return limited


class ArmDriver:
    """Wraps the bus so --dry-run needs no hardware and no code changes."""

    def __init__(self, port, dry_run=False, baud=1_000_000):
        self.dry_run = dry_run
        self.bus = None
        self.positions = {j: CENTRE for j in JOINTS}
        if dry_run:
            print("DRY RUN — no serial port opened, nothing is driven.")
            return
        from arm.feetech import FeetechBus
        self.bus = FeetechBus(port, baud)
        found = self.bus.scan(range(1, 10))
        print(f"servos found: {found}")
        missing = [j for j in JOINTS if j not in found]
        if missing:
            self.bus.close()
            sys.exit(f"Refusing to start: joints {missing} did not answer. "
                     "Check power and the bus cable.")
        self.positions = {j: p for j, p in self.bus.read_positions(JOINTS).items()
                          if p is not None}

    def arm(self):
        """Apply the force cap, then enable torque. Order matters."""
        if self.dry_run:
            print(f"[dry] torque limit {TORQUE_LIMIT_PERMILLE}, torque on")
            return
        applied = self.bus.set_torque_limit(JOINTS, TORQUE_LIMIT_PERMILLE)
        refused = [j for j, v in applied.items() if v is None]
        if refused:
            self.bus.close()
            sys.exit(f"Refusing to run: torque limit rejected by joints {refused}. "
                     "The arm would move at full force.")
        print("torque limit applied: "
              + ", ".join(f"{JOINT_NAMES[j]}={applied[j]}" for j in JOINTS))
        self.bus.set_torque(JOINTS, True)

    def write(self, goals):
        self.positions.update(goals)
        if not self.dry_run:
            self.bus.sync_write_positions(goals)

    def disarm(self):
        if self.dry_run:
            print("[dry] torque off")
            return
        if self.bus:
            ok = self.bus.set_torque(JOINTS, False)
            print("torque off" if ok else "WARNING: could not disable torque",
                  file=sys.stderr if not ok else sys.stdout)
            self.bus.close()


def run(args):
    try:
        from teleop import Teleop
    except ImportError:
        sys.exit("teleop missing:  pip install teleop\n"
                 "See docs/XR-TELEOP-NO-HARDWARE.md")

    driver = ArmDriver(args.port, dry_run=args.dry_run)
    driver.arm()

    state = {"origin": None, "last_msg": 0.0, "goals": dict(driver.positions),
             "moving": False}

    def on_pose(pose_matrix, message):
        data = message.get("data", message) or {}
        state["last_msg"] = time.monotonic()

        if not data.get("move"):
            state["origin"] = None        # finger lifted: re-zero on next grab
            state["moving"] = False
            return

        orient = data.get("orientation") or {}
        quat = (orient.get("w", 1.0), orient.get("x", 0.0),
                orient.get("y", 0.0), orient.get("z", 0.0))

        if state["origin"] is None:       # first frame of this grab
            state["origin"] = quaternion_to_euler(*quat)

        if args.mode == "orientation":
            state["goals"] = orientation_to_joints(quat, state["origin"])
        else:
            solved = solve_ik(pose_matrix, driver.positions, args)
            if solved is None:
                return                    # unreachable: hold, never jump
            state["goals"] = solved
        state["moving"] = True

    teleop = Teleop(host=args.host, port=args.xr_port)
    teleop.subscribe(on_pose)

    stopping = {"now": False}

    def stop(*_):
        stopping["now"] = True
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    print(f"\nXR bridge up — mode: {args.mode}")
    print(f"  open  https://<this-machine>:{args.xr_port}  on your phone")
    print(f"  HTTPS is required by WebXR; see docs/XR-TELEOP-NO-HARDWARE.md")
    print(f"  Ctrl-C stops and disables torque.\n")

    import threading
    threading.Thread(target=teleop.run, daemon=True).start()

    period = 1.0 / RATE_HZ
    try:
        while not stopping["now"]:
            # Deadman: no message for 0.5 s means the phone or the network is
            # gone. Hold position -- do not keep executing a stale target.
            stale = (time.monotonic() - state["last_msg"]) > 0.5
            if state["moving"] and not stale:
                stepped = rate_limit(driver.positions, state["goals"])
                driver.write(stepped)
            time.sleep(period)
    finally:
        print("\nstopping")
        try:
            teleop.stop()
        except Exception:
            pass
        driver.disarm()


def solve_ik(pose_matrix, current, args):
    """4x4 target pose -> joint counts, or None if unreachable."""
    try:
        from lerobot.model.kinematics import RobotKinematics
    except ImportError:
        sys.exit("lerobot missing — install it, or use --mode orientation")
    if not hasattr(solve_ik, "_kin"):
        solve_ik._kin = RobotKinematics(urdf_path=args.urdf,
                                        target_frame_name=args.frame)
    try:
        degrees = [(current.get(j, CENTRE) - CENTRE) / COUNTS_PER_RAD * 180 / math.pi
                   for j in JOINTS[:5]]
        solution = solve_ik._kin.inverse_kinematics(degrees, pose_matrix)
    except Exception:
        return None
    if solution is None:
        return None
    return {j: int(CENTRE + math.radians(a) * COUNTS_PER_RAD)
            for j, a in zip(JOINTS[:5], solution)}


def self_test():
    """Mapping maths only — no phone, no robot, no serial port."""
    failures = []

    # 1. identity quaternion sits every joint at centre
    goals = orientation_to_joints((1.0, 0.0, 0.0, 0.0))
    print(f"[1] level phone -> {goals}")
    if any(v != CENTRE for v in goals.values()):
        failures.append("level phone did not map to centre")

    # 2. yaw moves the pan joint, and in a bounded way
    q = (math.cos(math.radians(30) / 2), 0.0, 0.0, math.sin(math.radians(30) / 2))
    goals = orientation_to_joints(q)
    print(f"[2] 30 deg yaw -> pan {goals[1]} (centre {CENTRE})")
    if goals[1] <= CENTRE:
        failures.append("yaw did not move pan the expected way")

    # 3. an absurd rotation must still clamp inside the configured span
    q = (0.0, 0.0, 0.0, 1.0)              # 180 degrees
    goals = orientation_to_joints(q)
    span = ORIENTATION_MAP[1][2]
    print(f"[3] 180 deg yaw -> pan {goals[1]}, allowed {CENTRE-span}..{CENTRE+span}")
    if not (CENTRE - span <= goals[1] <= CENTRE + span):
        failures.append("clamp failed: joint would exceed its configured span")

    # 4. rate limiting never exceeds MAX_STEP
    current = {j: CENTRE for j in JOINTS}
    stepped = rate_limit(current, {1: CENTRE + 5000})
    print(f"[4] huge jump rate-limited -> {stepped[1]} (max +{MAX_STEP})")
    if stepped[1] != CENTRE + MAX_STEP:
        failures.append(f"rate limit produced {stepped[1]}")

    # 5. relative tracking: same phone angle as origin means no movement
    q = (math.cos(math.radians(45) / 2), 0.0, 0.0, math.sin(math.radians(45) / 2))
    origin = quaternion_to_euler(*q)
    goals = orientation_to_joints(q, origin)
    print(f"[5] phone unchanged since grab -> {goals}")
    if any(v != CENTRE for v in goals.values()):
        failures.append("relative tracking drifted when the phone had not moved")

    print()
    if failures:
        print("FAILURES:")
        for f in failures:
            print("  -", f)
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Mira XR bridge: phone -> SO-101")
    ap.add_argument("--port", default="/dev/mira_arm_bus", help="servo bus serial port")
    ap.add_argument("--mode", choices=["orientation", "ik"], default="orientation")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--xr-port", type=int, default=4443, help="WebXR server port")
    ap.add_argument("--urdf", default="so101.urdf", help="ik mode only")
    ap.add_argument("--frame", default="gripper_frame_link", help="ik mode only")
    ap.add_argument("--dry-run", action="store_true", help="never drive the bus")
    ap.add_argument("--self-test", action="store_true", help="maths only, no hardware")
    args = ap.parse_args()
    sys.exit(self_test() if args.self_test else run(args))
