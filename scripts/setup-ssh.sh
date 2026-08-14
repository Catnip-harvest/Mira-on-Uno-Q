#!/bin/bash
# Mira — enable key-only SSH on the UNO Q.
# Expects the client public key already pushed to /tmp/mira.pub
# Idempotent: safe to re-run.
set -u

PUB=/tmp/mira.pub
sec() { echo; echo "===== $1 ====="; }

if [ ! -s "$PUB" ]; then
  echo "FATAL: $PUB missing or empty — push the .pub first"; exit 1
fi

sec "1. SSH HOST KEYS"
if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  echo "host keys already present:"
else
  echo "generating host keys..."
  ssh-keygen -A
fi
ls -1 /etc/ssh/ssh_host_*_key

sec "2. AUTHORIZED KEY FOR root"
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
KEY=$(cat "$PUB")
if grep -qxF "$KEY" /root/.ssh/authorized_keys; then
  echo "key already authorized"
else
  printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
  echo "key added"
fi
wc -l < /root/.ssh/authorized_keys | xargs echo "authorized_keys lines:"

sec "3. EXPLICIT SSHD POLICY (key-only, no passwords)"
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config; then
  install -d -m 755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-mira.conf <<'EOF'
# Mira dev access — key auth only, root permitted by key.
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  echo "wrote /etc/ssh/sshd_config.d/10-mira.conf"
else
  echo "NOTE: sshd_config has no Include for sshd_config.d"
  echo "      relying on compiled defaults (PermitRootLogin prohibit-password) — key auth still works"
fi

sec "4. VALIDATE CONFIG"
if sshd -t; then echo "sshd -t: config OK"; else echo "sshd -t FAILED — not starting"; exit 1; fi

sec "5. ENABLE + START"
systemctl enable ssh.service
systemctl restart ssh.service
systemctl is-active ssh.service

sec "6. LISTENING SOCKETS"
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -E ':22|sshd' || echo "nothing on :22 (investigate)"

sec "DONE"
