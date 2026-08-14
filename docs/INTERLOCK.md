# Mira — Servo Power Interlock

Operator playbook. Read the Safety section before you connect a power supply.

---

## 1. What this is

The relay feeding the SO-101's 12 V servo rail is held closed **only** while a
fresh, checksum-valid heartbeat keeps arriving from the laptop. Heartbeat stops,
E-stop opens, or frames fail validation → the relay opens and the arm
de-energises.

The MCU decides alone. Linux cannot override it, and neither can a crashed host.

```
LAPTOP  ── UDP heartbeat, 20 Hz ──►  UNO Q / Linux  ── UART 115200 ──►  STM32U585
                                     (mira_bridge.py)                   (interlock)
                                                                            │ GPIO
                                                                            ▼
                                                          relay ──► 12 V servo rail
```

**Why it matters for the pitch:** the UNO Q is not the AI accelerator, it is the
safety processor. This is the part that is true, physical, and demonstrable.

---

## 2. Safety rules the firmware enforces

The relay is closed only when **all three** hold:

1. State is `ARMED`, entered only by an explicit `ARM` command
2. Last valid heartbeat is younger than **250 ms**
3. E-stop reads healthy

Anything else opens the relay. Faults **latch** — a flapping network must never
silently re-energise a robot arm the moment it recovers. Clearing a latched fault
requires a human sending `RST`.

| Failure | What happens |
|---|---|
| Laptop process killed | Heartbeat stops → relay opens in ≤250 ms, latches |
| Wi-Fi pulled | Same |
| Linux hangs or is powered off | Same |
| Bridge process killed | Same |
| E-stop pressed | Relay opens immediately, latches |
| **E-stop wire cut** | Reads as pressed → opens. Fails safe |
| UART line noise | CRC-8 rejects the frame; 20 bad frames while armed → fault |
| Stuck/repeating UART buffer | Heartbeat sequence must advance; repeats rejected |
| MCU firmware hangs | Watchdog resets MCU; reset opens the relay |

---

## 3. Wiring

| Signal | Pin | Notes |
|---|---|---|
| Relay drive | **D7** | To relay module input |
| E-stop | **D2** | **Normally-closed** contacts to GND, internal pull-up |
| Green LED (rail live) | **D5** | Series resistor ~330 Ω |
| Red LED (rail dead) | **D6** | Series resistor ~330 Ω |
| ISD1820 play | **D8** | Edge trigger, 150 ms pulse |

### ⚠️ Relay module polarity — check this before first power-on

`RELAY_ACTIVE_HIGH = true` in the sketch assumes a module that closes on a
**HIGH** input. That is the safe kind: MCU pins are low during reset, so the
relay is open whenever the MCU is not in control.

**Many cheap relay modules are ACTIVE-LOW.** With one of those, the relay would
**close during reset** and energise the arm while nothing is supervising it.

If you must use an active-low module:
1. Set `RELAY_ACTIVE_HIGH = false`
2. Fit a **10 kΩ pull-up** from D7 to 3V3
3. **Verify with a meter** that the relay is OPEN while the MCU is held in reset

Do not skip step 3.

### E-stop must be normally-closed

Normally-open looks like it works and silently removes your protection when a
wire breaks. Normally-closed reads a cut wire as "pressed" and fails safe.

---

## 4. Build and flash

The MCU target is Arduino-on-Zephyr, not the classic STM32 core.

```bash
arduino-cli core update-index
arduino-cli core install arduino:zephyr
arduino-cli compile --fqbn arduino:zephyr:unoq firmware/mira_interlock
arduino-cli upload  --fqbn arduino:zephyr:unoq -p /dev/ttyHS1 firmware/mira_interlock
```

`arduino-app-cli` must run as UID 1000 (`su - arduino`) if you use it instead.

---

## 5. Run

**On the UNO Q** — the bridge needs the UART, which `arduino-router` holds:

```bash
sudo systemctl stop arduino-router
sudo python3 bridge/mira_bridge.py --serial /dev/ttyHS1 --listen 0.0.0.0:9000
```

**On the laptop:**

```bash
python3 host/mira_heartbeat.py --host Mira.local --arm
```

Clear a latched fault:

```bash
python3 host/mira_heartbeat.py --host Mira.local --reset
```

---

## 6. Acceptance test — run this before demo day

Do it with the **arm disconnected** first, watching the LEDs only.

| # | Action | Expected |
|---|---|---|
| 1 | Power the board, nothing else running | Red LED on, relay open |
| 2 | Start bridge and heartbeat **without** `--arm` | Still red, relay open |
| 3 | Send `--arm` | Green LED, relay closes |
| 4 | **Ctrl-C the laptop heartbeat** | Red within ~250 ms, latched |
| 5 | Restart heartbeat with `--arm` | **Stays red** — latch holds |
| 6 | `--reset`, then `--arm` | Green again |
| 7 | Armed, then **pull the Wi-Fi** | Red within ~250 ms |
| 8 | Armed, then **press E-stop** | Red immediately |
| 9 | Armed, then **unplug the E-stop wire** | Red — proves fail-safe wiring |
| 10 | Armed, then `kill -9` the bridge | Red within ~250 ms |

**Test 9 is the one to show the judges.** Anyone can stop a robot with a button.
Showing that a *broken* safety wire also stops it is a different level of claim.

Only after all ten pass should the 12 V rail go anywhere near the arm.

---

## 7. Demo script (the 30 seconds that lands)

1. Arm the system. Green LED. Arm is live, holding a pose.
2. Say: *"The UNO Q is not our AI accelerator. It's our safety processor."*
3. **Pull the network cable / kill Wi-Fi.**
4. Red LED, audible click, arm goes limp. Under a quarter of a second.
5. Say: *"Linux can't override that. Nothing on the host can. The MCU stopped
   hearing a heartbeat, so it opened the relay."*
6. Try to re-arm — it refuses. *"And it won't come back on its own."*

---

## 8. Known gaps — be honest about these

- **It compiles, but has never run on hardware.** Verified 2026-08-11 against
  `arduino:zephyr@0.90.0`: 74576 bytes flash (9%), 26944 bytes RAM (10%), no
  warnings. Compiling is not working — do section 6 before trusting any of it.
- **There is NO watchdog. Confirmed, not assumed.** This core ships no
  `IWatchdog.h`, and using Zephyr's native `wdt_*` API breaks the link
  (`undefined reference to __device_dts_ord_175` from `Arduino_RouterBridge`,
  which backs `Serial`) because the sketch is an llext loaded into a prebuilt
  Zephyr image. So **a firmware hang while the relay is closed is not covered**.
  Everything else — host loss, network loss, E-stop, bad frames — is.

  If you need hang coverage, do it in hardware: drive the relay from an
  **AC-coupled square wave** (MCU outputs ~1 kHz → diode/capacitor charge pump →
  transistor). A stuck pin, high *or* low, stops the oscillation and the relay
  drops within ~100 ms. It is also a better answer to "what if your firmware
  crashes?" than any watchdog, because it needs the MCU to be *alive*, not merely
  powered.
- The board prints `M,BOOT,watchdog=ABSENT-fit-hardware-failsafe` on startup, so
  the serial log never lets anyone assume protection that isn't there.
- Timing is unverified end-to-end; the ≤250 ms figure is the design target, not a
  measurement. Measure it and put the real number on the latency HUD.

---

## 9. If something is wrong

The interlock is the one part of Mira that must not be improvised on the day. If
a test in section 6 fails, **do not demo with the arm powered.** Show the
subsystem with LEDs only and say so. A validated subsystem honestly described
beats a live arm you do not trust.
