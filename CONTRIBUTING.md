# Building on Mira

Setup for anyone joining the project. Pick the section for what you're working
on — you don't need all of it.

**You do not need the robot arm to start.** Most of the work can be built and
tested on a laptop.

---

## Everyone: get the repo

```bash
git clone https://github.com/Catnip-harvest/Mira-on-Uno-Q.git
cd Mira-on-Uno-Q
python3 tests/test_protocol.py        # should print ALL CHECKS PASSED
```

That test needs no hardware and no dependencies beyond Python 3. If it passes,
your environment is fine.

macOS, Linux and WSL are all supported. Plain Windows works for the tests and
the mock's self-test, but not for the virtual serial port (no pty).

---

## Track A — XR teleop (phone controls the arm)

**You can build this entire feature with no robot.** See
`docs/XR-TELEOP-NO-HARDWARE.md` for the full walkthrough; the short version:

```bash
pip install teleop                    # WebXR phone controller, LAN-only, no GPU
python -m teleop.basic                # open the printed URL on your phone
```

```bash
python3 tools/mock_arm.py             # virtual servo bus on a fake serial port
# MOCK BUS READY: /dev/ttys004
```

Then write the bridge in between: phone pose → inverse kinematics → joint
targets → that serial port.

For IK, use LeRobot's — do not write your own:

```python
from lerobot.model.kinematics import RobotKinematics
kin = RobotKinematics(urdf_path="so101.urdf", target_frame_name="gripper_frame_link")
joints = kin.inverse_kinematics(current_joint_pos, desired_ee_pose)
```

placo-based, CPU only, no GPU. **Run IK on the laptop, not the board** — placo may
have no aarch64 wheel and the board has ~800 MB of disk free. Send joint targets
to the board over UDP at 20–50 Hz.

**SO-101 has 5 degrees of freedom plus the gripper**, so it cannot reach every
6-DOF pose the phone can describe. Decide now what happens when IK fails: hold
position. Never jump.

### If IK fights you

Take this fallback rather than losing a day: map phone **orientation** straight to
2–3 joints (pan, tilt, wrist roll). No IK, no solver. To an audience watching a
camera follow them, it looks identical.

---

## Track B — datasets and policy training (LeLab)

[LeLab](https://huggingface.co/docs/lerobot/main/en/lelab) is a web UI over
LeRobot: calibrate, teleoperate, record datasets, train, and run policies without
memorising CLI commands. **It supports SO-ARM101 specifically**, which is our arm.

```bash
# needs uv: https://docs.astral.sh/uv/getting-started/installation/
uv tool install git+https://github.com/huggingface/leLab.git && lelab
```

After install, run `lelab` any time to start the app.

**LeLab requires the physical arm connected.** It has no simulation mode — it is a
friendlier front end, not a substitute for hardware. Use it when you have the arm
on the bench; use `tools/mock_arm.py` when you don't.

What it's good for:

- **Calibration** — per-joint, from the middle position, with a live 3D view
- **Dataset recording** — set a task description and episode count, spacebar to
  advance. 30+ episodes recommended
- **Training** — locally, or on GPUs via HF Jobs (`hf auth login` first)
- **Running a trained policy** — pick a model, one click

This is the lowest-friction path if you are not a robotics person: the GUI does
the parts that are otherwise fiddly CLI work.

---

## Track C — the board itself

Access, Wi-Fi, camera, USB host, udev pinning:

- `docs/UNOQ-ACCESS-HUMAN.md` — plain language, start here
- `docs/UNOQ-ACCESS-AGENT.md` — exact commands, failure signatures, decision tree
- `docs/HARDWARE.md` — every physical connection

```bash
ssh root@Mira.local                   # mDNS: survives changing networks
```

Two things that will waste your afternoon if you don't know them:

1. **Boot order matters.** Board first, count three seconds, *then* power the hub.
   Otherwise no USB peripheral appears at all.
2. **The board's power is not an emergency stop.** Cutting it leaves the servos
   holding torque — the arm goes rigid, not limp. The stop is the 12 V servo line.

---

## Before you open a pull request

```bash
python3 tests/test_protocol.py        # protocol still consistent
python3 tools/mock_arm.py --self-test # mock still behaves like a servo
```

Both must pass. Then see `docs/TESTING.md` for what to run before anything
touches the real arm.

Branch, push, open a PR. Việt reviews.
