#!/usr/bin/env python3
"""Mira live shadow test — REAL board camera frame + REAL follower state
-> RunPod MolmoAct2 server -> predicted actions. Motors are never commanded.
"""
import base64
import json
import subprocess
import time
import urllib.request

INFER_URL = "http://localhost:8765/infer"
TASK = "pick up the pen"
SSH = ["ssh", "-o", "BatchMode=yes", "-i",
       "/Users/edwardtran/.ssh/unoq-robot-access", "arduino@Mira.local"]

print("MIRA LIVE SHADOW TEST — real robot data, cloud inference, no motor commands")
print("=" * 74)

print("[1/3] Capturing REAL frame from the board's camera (/dev/mira_cam)...")
frame = subprocess.run(
    SSH + ["fswebcam -d /dev/mira_cam -r 640x480 --no-banner --jpeg 85 - 2>/dev/null"],
    capture_output=True, timeout=30).stdout
print(f"      got {len(frame)} bytes of JPEG")
open("/tmp/mira_live_frame.jpg", "wb").write(frame)

print("[2/3] Reading REAL follower joint state over the servo bus...")
out = subprocess.run(
    SSH + ["~/.local/share/mira-so101/venv/bin/python /home/arduino/read_follower_state.py"],
    capture_output=True, text=True, timeout=30)
state_map = json.loads(out.stdout.strip().splitlines()[-1])
order = ["shoulder_pan.pos", "shoulder_lift.pos", "elbow_flex.pos",
         "wrist_flex.pos", "wrist_roll.pos", "gripper.pos"]
state = [state_map[k] for k in order]
print("      state:", [round(s, 1) for s in state])

print(f"[3/3] Sending to MolmoAct2 on RunPod ({INFER_URL.split('/')[2]})...")
b64 = base64.b64encode(frame).decode()
body = {"camera1": b64, "camera2": b64, "camera2_is_placeholder": True,
        "state": state, "task": TASK}
req = urllib.request.Request(INFER_URL, data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
t0 = time.perf_counter()
resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
wall = time.perf_counter() - t0

actions = resp.get("action") or resp.get("actions")
print()
print(f"RESPONSE in {wall:.2f}s  (GPU inference: {resp.get('latency_ms', 0)/1000:.2f}s)")
chunk = actions[0] if isinstance(actions[0][0], list) else actions
print(f"Predicted action chunk: {len(chunk)} steps x {len(chunk[0])} joints")
for i, step in enumerate(chunk[:5]):
    print(f"  step {i}: " + "  ".join(f"{v:8.2f}" for v in step))
print(f"  ... ({len(chunk)} steps total)")
print()
print("PROOF COMPLETE: real camera + real joint state -> cloud model -> actions.")
