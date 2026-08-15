# MIRA — Tonight's Recording Script

Phone landscape · room lights ON · arm's space clear · 12 V plug within reach at all times.
Two takes per shot minimum. Voice pipeline is already running.

---

## SHOT 1 — Voice control (the hero clip)
**Frame:** you + mic on one side, whole white arm on the other.
**Say (one breath, Vietnamese-style "MEE-RAH"):**
1. `Mi-ra, vẫy tay` → she waves
2. `Mi-ra, nhảy` → she dances
3. `Mi-ra, quét` → she scans (the inspection story — get this one!)
4. `Mi-ra, gật đầu` → she nods
**If she ignores you:** slower, mic closer, harder "ra". She logs what she heard — Claude can check.
**Proves:** offline Vietnamese voice → robot, all on the 2 GB board.

## SHOT 2 — Motion close-ups (b-roll)
Claude triggers these over SSH on your "go": `bow`, `celebrate`, `thinking`, `shrug`.
**Frame:** close on the gripper/joints, then one wide.
**Proves:** smooth 30 FPS trajectory replay.

## SHOT 3 — Robot's-eye view
Claude records the WRIST CAMERA while the arm runs `scan`.
You do nothing except place 2–3 objects (pen, tape, box) in front of the arm.
**Proves:** inspection camera actually inspecting. (Claude assembles the clip.)

## SHOT 4 — The E-stop (film LAST)
Claude starts `dance` (10 s). Mid-motion, **you pull the 12 V plug on camera.**
Arm stops instantly. Plug back in.
**Proves:** the safety story — power discipline is real, one yank kills the muscle.

## SHOT 5 — Already done ✔
`JQK-Mira-pipeline-proof.mp4` — cloud AI proof video (in this folder).

---

## Voice vocabulary (after "Mi-ra")
| Vietnamese | English also works | Motion |
|---|---|---|
| vẫy tay | wave | wave |
| nhảy / múa | dance | dance |
| quét | scan | scan |
| lắc đầu | shake | head-shake |
| gật đầu | nod | nod |
| có / không | yes / no | yes / no |
| ngủ | sleep | pause listening |
| dậy đi | — | wake up again |

## Manual triggers (for the team, later)
```
ssh mira-wifi                     # onto the board
mira-robot list                   # all motions
mira-robot replay bow             # type MOVE to confirm
mira-robot stop                   # graceful interrupt
```
