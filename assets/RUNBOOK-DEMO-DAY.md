# MIRA — Demo Day Runbook (2026-08-16)

The one page to read at the venue. Everything here was verified working the night before.

---

## 1. Power-on ritual (order matters — USB host-mode race)
1. Hub connected to board, peripherals in hub, **hub power OFF**.
2. Power the board. **Count one… two… three.**
3. Power the hub. Wait 60 s.
4. Check: `ssh mira-wifi lsusb` → must show BOYAMIC, HD video (wrist cam), QinHeng serial(s).

**Wi-Fi:** board auto-joins a hotspot named+passworded identically to home Wi-Fi.
Phone hotspots may isolate clients — test `ssh mira-wifi` BEFORE going on stage.

## 2. E-stop — say it to everyone touching the rig
**Board power-off does NOT stop the arm.** The 12 V servo plug is the only E-stop. One hand near it during every motion.

## 3. Voice demo
```
ssh mira-wifi
sudo -u arduino nohup /home/arduino/wakeword-env/bin/python \
  /home/arduino/board_voice_control.py > /home/arduino/voice_run.log 2>&1 &
tail -f /home/arduino/voice_run.log     # watch what she hears
```
- Pronounce **"MEE-RAH"** (Vietnamese style). Wake word + command in ONE breath.
- Commands (vi/en both work): vẫy tay/wave · nhảy/dance · quét/scan · lắc đầu/shake · gật đầu/nod · có/không · ngủ (pause) · dậy đi (resume).
- Mic = BOYA receiver (must be in a GOOD hub port; one hub port is dead), transmitter out of its case.

## 4. Manual motions (backup if voice is shy)
```
ssh mira-wifi
mira-robot list
mira-robot replay bow        # type MOVE to confirm
mira-robot stop
```

## 5. Cloud AI (MolmoAct2) — only if the pitch needs it
1. RunPod (Việt's account) → create pod: **RTX 4090**, image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`, network volume `mira-molmo-canary` at `/workspace`, ports `8765/http, 22/tcp`. (Stopped pods lose GPUs — always create fresh; ~$0.74/hr, balance ≈ $1.)
2. `ssh -p <port> root@<ip>` → `bash /workspace/serve/start-molmoact.sh` → "Ready in ~100 s".
3. Client: `https://<podid>-8765.proxy.runpod.net/infer` or SSH tunnel `-L 8765:localhost:8765` (tunnel is the reliable one).
4. Serves the **AllenAI base SO-100/101 checkpoint** (not the overfitted fine-tune). Shadow mode only — never wired to motors.
5. **Stop the pod the moment the demo segment ends.**

## 6. Known one-night fixes already in place (don't re-debug)
- udev: both arm controllers pinned (serials …7109 = white/follower, …8584 = black/leader).
- Leader recalibrated 2026-08-15 → in git (Qualcom_Mira). Board venv `enter_pressed` stub fixed (calibration Enter works now).
- Black arm's gripper trigger is broken off → teleop works minus the claw. Screws + 5 min to fix, then re-run calibration WITH trigger squeezes.
- Wrist cam = `/dev/mira_cam` (video0); tripod cam = video2. One hub port is dead — avoid it.

## 7. Files that must exist before leaving home
`~/Downloads/JQK-slides/`: organizer pptx (submitted), editable deck (video inside), captioned demo video, poster PDF, pipeline-proof video — all mirrored on GitHub (repo `assets/` + release `demo-2026-08-16`).
