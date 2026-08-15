#!/usr/bin/env bash
# Start the Mira MolmoAct2 inference server (base AllenAI SO100/101 checkpoint).
# Usage: bash /workspace/serve/start-molmoact.sh   — logs to /workspace/serve/server.log
set -euo pipefail
export HF_HOME=/workspace/hf-cache
export MIRA_CKPT="${MIRA_CKPT:-allenai/MolmoAct2-SO100_101}"
cd /workspace/serve
nohup /workspace/lerobot/.venv/bin/python molmoact2_server.py > server.log 2>&1 &
echo $! > server.pid
echo "started pid $(cat server.pid); tail -f /workspace/serve/server.log"
