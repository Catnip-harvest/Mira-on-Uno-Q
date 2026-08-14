# Testing protocol

Four tiers. **You may not skip a tier.** Each one catches faults that would be
more expensive — or more dangerous — to find at the next.

The rule behind all of it: *a clean run at one tier says nothing about the tier
above it.* Mock success is not hardware success.

| Tier | Needs | Catches | Risk if it fails |
|---|---|---|---|
| 0 | Nothing | Protocol, checksums, logic | None |
| 1 | Laptop + mock bus | Control flow, IK, rate limits, torque sequencing | None |
| 2 | Real arm, unloaded, supervised | Physics, calibration, joint limits | Damaged arm |
| 3 | Full demo rehearsal | Timing, boot order, operator error | Failed demo |

---

## Tier 0 — no hardware

Run on any machine, including plain Windows. Takes seconds.

```bash
python3 tests/test_protocol.py
python3 tools/mock_arm.py --self-test
```

**Pass criteria:** both print `ALL CHECKS PASSED`.

What this proves: the CRC-8 used by the firmware, the bridge and the host sender
are byte-for-byte identical; corrupt frames are rejected; the mock behaves like a
servo. What it does not prove: anything about a robot.

Run this before every commit.

---

## Tier 1 — mock bus on a laptop

No robot. macOS, Linux or WSL (needs a pty).

```bash
# terminal 1
python3 tools/mock_arm.py
# note the port it prints, e.g. /dev/ttys004

# terminal 2 — your code, pointed at that port
python3 your_code.py --port /dev/ttys004
```

**Pass criteria — all six:**

1. Your code discovers 6 servos, IDs 1–6
2. It reads present positions without timing out
3. It applies the torque limit and reads back the value it set
4. Goal positions appear in the mock's log at your expected rate
5. **Killing your code leaves torque disabled** — check the mock's last state
6. Corrupt or truncated frames do not crash it

Test 5 is the one people skip and the one that matters: if your code dies without
disabling torque, the real arm stays rigid and powered.

The mock deliberately **refuses to move a joint while torque is off**, exactly like
a real servo. If your joints never move, you probably forgot to enable torque —
better to learn that here.

---

## Tier 2 — first contact with the real arm

**Do not start this alone. Do not start it tired.**

### Before power

- [ ] Arm is **unloaded** — no tool, no payload, nothing in the gripper
- [ ] Workspace is clear: no hands, no cables, no laptop within its reach
- [ ] The **12 V servo supply plug is accessible**, and someone has a hand on it
- [ ] Everyone present knows that **cutting the board's power does NOT stop the arm**
- [ ] Tier 1 passed with this exact code

### First run

```bash
python3 teleop.py run --duration 20
```

**Watch for, and cut power immediately if you see:**

- Any joint moving faster than a slow walk
- A joint moving toward its own body or the table
- Buzzing or whining from a stationary joint (stall — it is fighting something)
- A joint getting warm

**Pass criteria:**

1. The torque cap prints an applied value for **every** joint. If any joint
   reports `None`, the code exits — do not override this
2. The arm eases into position over the approach ramp, no jump at the start
3. It stops on its own at 20 seconds
4. **Torque is disabled on exit** — the arm is backdrivable by hand afterwards
5. No joint exceeded 65 °C

Then repeat at 60 seconds. Then with the camera mounted. One change at a time.

### If anything is unexpected

Cut the 12 V. Do not "just try again" — find out why first. An arm that behaved
oddly once will behave oddly on stage.

---

## Tier 3 — demo rehearsal

Full run, start to finish, as it will happen on the day. **At least twice, and at
least once by someone who did not write the code.**

### Setup, in order

- [ ] Hub connected to board, peripherals in hub, **hub power off**
- [ ] Power the board
- [ ] **Count three seconds**
- [ ] Power the hub
- [ ] Confirm peripherals appeared: `ssh root@Mira.local lsusb`

Get this order wrong and no camera appears. It is the single most likely way the
demo fails.

### The run

- [ ] Full sequence end to end, timed
- [ ] The deliberate failure: cut the 12 V, arm goes limp, audience sees it
- [ ] Recovery: restore power, re-arm, continue
- [ ] Whole thing fits the time slot with margin

### Also rehearse the bad day

- [ ] Wi-Fi unavailable — does the fallback work?
- [ ] Board reboots mid-demo — how long to recover, and who says what meanwhile?
- [ ] **Backup video plays** from the presenting laptop, offline, full screen

That last one is not optional. A recorded successful run turns "our demo broke"
into "here it is working, and here's it live" — the difference between a bad
moment and a lost competition.

---

## Reporting a failure

Say the tier, what you expected, what happened, and paste the output. Include:

```bash
ssh root@Mira.local 'uname -r; lsusb; ls -l /dev/mira_*; free -h; df -h /'
```

Two days out, a **known** failure is workable. A hidden one is fatal.
