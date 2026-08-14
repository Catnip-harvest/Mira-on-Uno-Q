# Mira on UNO Q

Robotic camera inspection assistant running on an Arduino UNO Q (Qualcomm QRB2210).
An SO-101 arm carries a camera; the board drives the servo bus, captures images, and
serves a phone UI — **entirely offline, no cloud, no GPU**.

Team JQK · Qualcomm Hack Challenge 2026

---

## Hardware

Two wires power the board. Everything else hangs off one USB-C hub.
**No GPIO is used in this project.**

```
        5V ────┐
       GND ────┤                            ARDUINO UNO Q
               │   ┌──────────────────────────────────────────────┐
               └──►│ 5V / GND pins        QRB2210  (Linux, 2 GB)  │
                   │  ── the only two      + STM32U585 (MCU)      │
                   │     pins we use                              │
                   │                                              │
                   │  Wi-Fi  ))))  ──────────────────────►  phone │
                   │                                     + laptop │
                   │                          LED matrix (onboard)│
                   └───────────────────┬──────────────────────────┘
                                       │ USB-C  (DATA)
                                       │
   USB-C PD ──────────────────┐        │
   (powers hub +              │        │
    all peripherals)          ▼        ▼
                   ┌──────────────────────────────────────────────┐
                   │  PD in            USB-C HUB                  │
                   └───┬────────┬────────────┬──────────┬─────────┘
                       │        │            │          │
                       ▼        ▼            ▼          ▼
                  SO-101 arm  Camera      Speaker   Boya wireless
                  USB serial  (wrist /    audio out  mic  (USB-C)
                  1 Mbaud      overhead)
                       │
                       ▼
                  ┌─────────┐
                  │ SO-101  │◄──── 12 V servo supply
                  │  arm    │      ⚠ E-STOP = cut THIS,
                  │ 6 servos│        not the board's 5 V
                  └─────────┘
```

### Why the board's power is not an emergency stop

The servos have their own 12 V supply. Cutting power to the **board** leaves
`Torque_Enable` set on every servo, so the arm **freezes rigid and keeps pushing**
rather than going limp. The emergency stop must cut the **12 V servo line**.

### Boot order matters

The UNO Q decides whether its USB-C port is a host in the first ~5 seconds of boot
([known Arduino bug](https://github.com/arduino/linux-qcom/issues/2)). Get it wrong
and no peripheral appears:

1. Hub connected to the board, peripherals in the hub, **hub power off**
2. Power the board
3. **Wait ~3 seconds**
4. Power the hub

The board also needs `regulator_ignore_unused` on its kernel command line or it never
puts 5 V on the port. See `docs/UNOQ-ACCESS-AGENT.md` §4.

---

## What runs where

| Component | Runs on | Status |
|---|---|---|
| Servo bus, 100 Hz control loop | UNO Q | Working |
| Camera capture | UNO Q | Working |
| Trajectory replay | UNO Q | Working |
| 3D reconstruction (visual hull) | UNO Q | Planned |
| Phone UI (WebXR / viewer) | UNO Q serves, phone renders | Planned |
| IK / trajectory generation | Laptop, offline | Planned |
| MolmoAct2 policy | Rented GPU (training only) | Evidence in `ml/` |

The arm's camera poses come from **forward kinematics**, not Structure-from-Motion.
That removes the expensive, failure-prone stage of photogrammetry and is why 3D
reconstruction is feasible on a 2 GB board.

---

## Repository layout

```
firmware/mira_interlock/   STM32 safety interlock (compiles; NOT used in the
                           current build, which has no GPIO wiring — kept for
                           reference and for a future relay-based version)
bridge/                    UDP heartbeat -> MCU UART forwarder (Linux side)
host/                      Heartbeat sender (laptop side)
scripts/                   Board bring-up, diagnostics, Wi-Fi, GUI, udev
tests/                     Protocol verification (runs anywhere, no hardware)
tools/                     Mock servo bus - build arm/XR code with no robot
docs/                      Access runbooks and the interlock design
ml/                        MolmoAct2 canary training evidence
teleop/                    ** NOT YET IN THIS REPO — copy from the board **
```

### Missing: `teleop/`

The leader-follower teleop code (`teleop.py`, `trigger.py`, `feetech.py`) lives on
the board at `/home/arduino/teleop/` and is **not** in this package. Copy it in:

```bash
scp -r root@<board>:/home/arduino/teleop ./teleop
```

It includes a Feetech STS3215 driver whose register addresses were verified against
LeRobot's control table, plus a torque (force) limit applied before torque is ever
enabled.

---

## Joining the project

- **`CONTRIBUTING.md`** — setup per track: XR teleop, LeLab datasets/training, the board
- **`docs/TESTING.md`** — the four-tier testing protocol. Do not skip a tier
- **`docs/XR-TELEOP-NO-HARDWARE.md`** — build the phone-control feature with no robot

## Quick start

Everything below assumes the board is reachable. It advertises itself over mDNS as
`Mira.local`, which survives changing networks and DHCP leases.

```bash
ssh root@Mira.local
```

If that fails, `docs/UNOQ-ACCESS-HUMAN.md` walks through it in plain language, and
`docs/UNOQ-ACCESS-AGENT.md` has the full diagnostic tree.

### No arm? You can still build the XR teleop feature.

`tools/mock_arm.py` exposes a virtual serial port speaking the real Feetech
protocol, so the whole phone -> IK -> servo-bus chain runs on a laptop with
nothing plugged in. Robot code points at it unchanged.

```bash
python3 tools/mock_arm.py --self-test   # no serial port needed, works on Windows
python3 tools/mock_arm.py               # virtual port, macOS/Linux/WSL
```

Full walkthrough: `docs/XR-TELEOP-NO-HARDWARE.md`

Verify the wire protocol without any hardware:

```bash
python tests/test_protocol.py
```

---

## Safety

- **Apply the torque cap before enabling torque.** The code refuses to run if any
  joint rejects the limit. Do not remove that check.
- **Keep a hand on the 12 V servo plug** during any unsupervised motion until a
  proper inline switch exists.
- **Start short and slow.** Low torque, short rollouts, operator at the stop.

---

## Known limitations

- The arm's write path and torque cap are lightly tested on real hardware.
- The MolmoAct2 policy is **not deployed**: it requires two cameras (the wrist camera
  is faulty) and a CUDA GPU the board does not have. `ml/` contains the training
  evidence only.
- The STM32 interlock is written and compiles but is **not wired**, because this
  build uses no GPIO.
