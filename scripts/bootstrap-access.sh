#!/usr/bin/env bash
# Mira — set up SSH access to the UNO Q from a Linux machine, and diagnose it
# when it does not work. Safe to re-run; changes nothing that already works.
#
#   bash bootstrap-access.sh              # set up + verify
#   bash bootstrap-access.sh --diagnose   # report only, change nothing
#
# Full reference: docs/UNOQ-ACCESS-AGENT.md
set -uo pipefail

KEY="$HOME/.ssh/unoq-robot-access"
ALIAS="mira"
MDNS="Mira.local"          # NOTE: the board answers to Mira.local, NOT uno-q.local
DIAGNOSE=0
[ "${1:-}" = "--diagnose" ] && DIAGNOSE=1

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

say "1. SSH KEY"
if [ -f "$KEY" ]; then
  ok "private key present: $KEY"
else
  if [ "$DIAGNOSE" -eq 1 ]; then
    bad "no key at $KEY (diagnose mode: not creating one)"
  else
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "unoq-robot-access" -q
    ok "generated $KEY"
    echo
    echo "  >>> SEND THIS PUBLIC KEY to whoever administers the board <<<"
    echo "  >>> It is PUBLIC - safe to paste in chat. Access will not   <<<"
    echo "  >>> work until it is added to the board's authorized_keys.  <<<"
    echo
    sed 's/^/    /' "$KEY.pub"
    echo
  fi
fi
chmod 600 "$KEY" 2>/dev/null

say "2. SSH CONFIG"
if grep -qE "^Host[[:space:]]+$ALIAS([[:space:]]|$)" "$HOME/.ssh/config" 2>/dev/null; then
  ok "Host $ALIAS already in ~/.ssh/config"
elif [ "$DIAGNOSE" -eq 1 ]; then
  warn "no '$ALIAS' entry (diagnose mode: not adding)"
else
  install -d -m 700 "$HOME/.ssh"
  cat >> "$HOME/.ssh/config" <<EOF

# Mira - Arduino UNO Q. Addressed by mDNS so it survives changing networks
# and DHCP leases. If multicast is blocked, put the IPv4 address here instead.
Host $ALIAS
    HostName $MDNS
    User root
    IdentityFile $KEY
    StrictHostKeyChecking accept-new
    ServerAliveInterval 15
    ServerAliveCountMax 3
EOF
  ok "added Host $ALIAS -> $MDNS"
fi

say "3. CAN WE REACH IT?"
FOUND=""

# 3a. mDNS - try this first, it survives network changes
if ping -c1 -W2 "$MDNS" >/dev/null 2>&1; then
  ok "$MDNS responds to ping"
  FOUND="$MDNS"
else
  warn "$MDNS does not resolve or does not answer"
  command -v avahi-resolve >/dev/null 2>&1 || warn "avahi-utils not installed (sudo apt install -y avahi-utils)"
fi

# 3b. subnet sweep, only if mDNS failed
if [ -z "$FOUND" ]; then
  MYIP=$(ip -4 -brief addr show scope global | awk '{print $3}' | cut -d/ -f1 | head -1)
  if [ -n "${MYIP:-}" ]; then
    BASE=$(echo "$MYIP" | cut -d. -f1-3)
    warn "sweeping $BASE.0/24 for an SSH host (this takes ~30s)"
    for i in $(seq 1 254); do (ping -c1 -W1 "$BASE.$i" >/dev/null 2>&1 &) ; done
    sleep 6
    for a in $(ip neigh | awk '/REACHABLE|STALE/{print $1}' | grep "^$BASE\."); do
      if timeout 3 bash -c "</dev/tcp/$a/22" 2>/dev/null; then
        echo "    candidate with ssh open: $a"
        FOUND="$a"
      fi
    done
  fi
fi

# 3c. ADB over USB - only possible when the board is in USB *device* mode
if [ -z "$FOUND" ] && command -v adb >/dev/null 2>&1; then
  if adb devices | grep -qw device; then
    ok "board visible over ADB (USB device mode)"
    warn "use: adb forward tcp:2222 tcp:22 && ssh -p 2222 -i $KEY root@127.0.0.1"
  fi
fi

say "4. LOGIN TEST"
if [ -n "$FOUND" ]; then
  if OUT=$(timeout 15 ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
             -i "$KEY" "root@$FOUND" 'echo OK; hostname; uname -r; uptime -p' 2>&1); then
    ok "logged in"
    echo "$OUT" | sed 's/^/    /'
    echo
    ok "from now on just run:  ssh $ALIAS"
  else
    bad "reachable but login refused:"
    echo "$OUT" | sed 's/^/    /'
    echo
    echo "    Most likely: this machine's PUBLIC key is not in the board's"
    echo "    authorized_keys yet. Send this line to the board's admin:"
    echo
    sed 's/^/      /' "$KEY.pub" 2>/dev/null
  fi
else
  bad "board not reachable by any method"
  cat <<'HINT'

    Work through these in order:
      1. Is the board powered? Check its LEDs.
      2. Is it on the SAME Wi-Fi as this machine? Phone hotspots often
         isolate clients from each other, which blocks this entirely.
      3. Give it 60 seconds after power-on to boot and rejoin Wi-Fi.
      4. Still nothing? Plug a USB-C cable from this machine to the board
         and power-cycle it. It should come up in USB device mode and
         appear under `adb devices`, which is the rescue path.

    Note: the board CANNOT be a USB device to your laptop and host a
    camera/hub at the same time. One port, one job. If the hub is
    attached, the USB rescue path is unavailable.
HINT
fi

say "DONE"
