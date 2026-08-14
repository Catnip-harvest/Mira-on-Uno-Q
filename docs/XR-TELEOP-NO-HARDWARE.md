# Developing XR teleop without the arm

You can build and test the entire phone-controls-the-arm feature on a laptop
with no robot attached. macOS, Linux, or WSL.

The chain has three links, and only the last one needs hardware:

```
  phone (WebXR)  ──►  IK  ──►  servo bus
   no hardware       pure       ← the only link that
                     maths        needs the real arm
                                  ... so we fake it
```

---

## What each link needs

### 1. Phone pose — needs no robot at all

[SpesRobotics/teleop](https://github.com/SpesRobotics/teleop) turns a phone into a
6-DOF spatial controller over WebXR. LAN only, no internet, no GPU.

```bash
pip install teleop
python -m teleop.basic
```

Open the printed URL on your phone (same Wi-Fi). Move the phone, watch the pose
stream. **This works today, with nothing plugged in.**

### 2. Pose to joint angles — pure computation

LeRobot's kinematics, placo-based, CPU only:

```python
from lerobot.model.kinematics import RobotKinematics

kin = RobotKinematics(urdf_path="so101.urdf", target_frame_name="gripper_frame_link")
joints = kin.inverse_kinematics(current_joint_pos, desired_ee_pose)
```

Needs the SO-101 URDF. No hardware, no GPU.

**SO-101 is 5-DOF plus the gripper**, so it cannot reach every 6-DOF pose the
phone can describe. Expect IK to fail on some targets and decide now what happens
when it does — hold position, never jump.

### 3. Servo bus — the only link that needs the arm, so mock it

```bash
python3 tools/mock_arm.py
# MOCK BUS READY: /dev/ttys004
```

That is a virtual serial port speaking the real Feetech STS protocol: ping,
read/write registers, sync-write, torque enable, torque limit, positions that
ease toward goals. Point your robot code at that port instead of
`/dev/mira_arm_bus` and **nothing else changes**.

Verify it anywhere, including Windows, with no serial port:

```bash
python3 tools/mock_arm.py --self-test
```

---

## Full loop on a laptop

```bash
# terminal 1 — fake arm
python3 tools/mock_arm.py

# terminal 2 — phone controller
python -m teleop.basic

# terminal 3 — your bridge: pose -> IK -> joint targets -> the mock port
python3 your_xr_bridge.py --port /dev/ttys004
```

Pick up the phone, move it, watch the mock log goal positions. If that works, the
software is right and only the physical arm remains untested.

---

## What the mock proves, and what it does not

**Proves:** your protocol framing, checksums, IK, rate limiting, control flow,
torque sequencing, and error handling.

**Does not prove:** anything physical. No gravity, no inertia, no collisions, no
current draw, no joint limits from the real linkage. **A clean mock run is not
evidence that the motion is safe on the real arm.**

The mock deliberately refuses to move a joint while torque is off, exactly like a
real servo, so code that forgets to enable torque fails here rather than
confusing you on hardware.

---

## Tools that do NOT solve this

| Tool | Why not |
|---|---|
| **LeLab** | A web UI for LeRobot. Calibrate, teleoperate, record, train — all assume a **real arm connected**. Great once you have hardware; no help without it. |
| **Isaac Lab** ([SO-101 sim](https://github.com/liorbenhorin/lerobot_so101_teleop)) | Needs an **NVIDIA GPU with CUDA**. Not available on macOS. |
| **MuJoCo** | Genuinely works on Mac including Apple Silicon, and gives real physics — but it is a bigger lift than the mock and you do not need physics to test a control pipeline. Worth it later for a demo video. |

---

## First run on the real arm

When the mock loop works and the arm is available:

1. **Torque cap first.** The code exits if any joint rejects the limit. Do not
   remove that check.
2. **Someone with a hand on the 12 V servo plug.** Cutting power to the *board*
   does not stop the arm — the servos hold torque and go rigid.
3. **Short and slow.** `--duration 20`, low speed, unloaded, nothing near it.
4. Only then, longer runs.

---

## Phones: Android only on this team

### ⚠ Install ARCore on every phone BEFORE demo day

WebXR AR on Android requires **Google Play Services for AR** (ARCore) installed
and enabled, on an **ARCore-supported device**. It is a free Play Store install
— but it needs internet **once**, and there is no internet at the venue.

Do this now, on every phone that might be used:

1. Check the device is on Google's [ARCore supported devices list](https://developers.google.com/ar/devices)
2. Install **Google Play Services for AR** from the Play Store
3. Open the XR page once while still online and confirm the AR session starts

**If you arrive at HCMUS with a phone that has no ARCore, the XR demo is dead
and cannot be fixed on site.** Test at least two phones so there is a spare.

### HTTPS is required — and do NOT use a tunnel

WebXR only runs in a **secure context**. `localhost` is exempt; a LAN address is
not. `http://192.168.x.x:4443` will be refused.

**Do not solve this with ngrok or Cloudflare.** They need internet, and the whole
product claim is offline operation. A tunnel is a dependency on someone else's
infrastructure in a room where the Wi-Fi is already a risk.

Two ways to get a secure context, both fully offline:

#### While developing — USB port forwarding, no certificates at all

Chrome DevTools can forward a port over the USB cable so the phone sees the
server as `localhost`, which **is** a secure context. Nothing to install, no
certificates, no warnings.

1. Enable Developer options and USB debugging on the phone
2. Plug the phone into the laptop
3. On the laptop open `chrome://inspect/#devices` -> **Port forwarding**
4. Add `4443` -> `localhost:4443`
5. On the phone browse to `http://localhost:4443`

This is the fastest path for the person building the feature.

#### For the demo — a self-signed certificate on the LAN

The phone must be untethered on stage, so port forwarding is out.

```bash
mkcert -install
mkcert -cert-file cert.pem -key-file key.pem <server-lan-ip> localhost 127.0.0.1
```

`teleop` picks up `cert.pem` and `key.pem` from the server directory
automatically. Then install mkcert's root CA on the Android phone:

- Copy `rootCA.pem` to the phone (`mkcert -CAROOT` prints where it lives)
- Settings -> Security -> Encryption & credentials -> **Install a certificate**
  -> CA certificate
- Android warns you; that is expected for a self-signed CA

Without the CA installed the phone shows a certificate warning and **WebXR still
refuses**, even if you tap through to the page.

Note the port is **4443**, not 5000.

### Chrome flag: not a reliable path on Android

`unsafely-treat-insecure-origin-as-secure` exists, but on Android the
command-line form requires a rooted device or dev mode. Do not build the demo
around it. Use USB forwarding for development and a certificate for the demo.

---

## Testing without a phone

The bridge's mapping maths runs with no phone and no robot:

```bash
python3 xr/mira_xr_bridge.py --self-test
```

Checks that a level phone maps to centre, that rotation moves the right joint,
that extreme angles clamp inside the configured span, that rate limiting holds,
and that tracking is relative to where you grabbed rather than absolute.

For the full loop you do need a real phone — WebXR pose comes from the device's
own sensors and cannot be faked from the server side.
