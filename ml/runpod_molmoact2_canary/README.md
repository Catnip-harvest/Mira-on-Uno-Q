# Mira MolmoAct2 canary handoff

This folder contains the deployable checkpoint selected from the completed
2,000-step MolmoAct2 canary and the evidence used to select it.

## Result

- Base model: `allenai/MolmoAct2-SO100_101`
- Training episodes: 135
- Held-out episodes: 15 (`9, 19, ..., 149`)
- Selected checkpoint: step 2000
- Training loss at completion: 0.023
- Held-out paired flow-matching loss:
  - pretrained: 0.353776
  - step 250: 0.136719 (61.35% lower than pretrained)
  - step 1000: 0.084163 (76.21% lower)
  - step 2000: 0.071712 (79.73% lower; best)

Lower flow-matching loss is better. This is strong evidence that the model
learned the recorded screwdriver/microphone demonstrations rather than merely
reducing training loss. It is not proof of real-robot success or generalization
to new objects, lighting, backgrounds, camera geometry, or calibration.

## Contents

- `step2000_pretrained_model/`: complete LeRobot `save_pretrained` checkpoint,
  including weights, config, and preprocessing/postprocessing state.
- `evidence/heldout_eval.json`: machine-readable checkpoint comparison.
- `evidence/training.log`: complete 2,000-step training console log.
- `evidence/pruning.log`: checkpoint-retention log.
- `SHA256SUMS`: local artifact integrity hashes.

The 11 GB `model.safetensors` SHA-256 is
`23f573350102d8c0cc7ed63424b2bbaa0ed44fc3f98288d363b85ce594326a43`,
verified byte-for-byte against the RunPod volume.

## Important deployment warning

Before commanding real hardware, use the same robot configuration, two camera
keys/order, action/state dimensions, gripper normalization, and calibration used
for recording. Start with the robot unloaded, low speed/torque limits, an
operator at the emergency stop, and short rollouts. A lower offline loss does
not make unobserved calibration changes safe.

## Preserved remotely

The persistent RunPod network volume `fpvqvxh8e0` retains full training-state
checkpoints at steps 250, 1000, and 2000. Only the deployable step-2000
`pretrained_model` was downloaded locally because each full model is about
11 GB and step 2000 won the held-out comparison.
