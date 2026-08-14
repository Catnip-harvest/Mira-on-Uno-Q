#!/bin/bash
# Mira — why did lightdm autologin not take? Read-only.
sec() { echo; echo "===== $1 ====="; }

sec "LIGHTDM LOG (autologin decisions)"
tail -60 /var/log/lightdm/lightdm.log 2>/dev/null | grep -iE 'autologin|seat|session|pam|greeter|start|fail|error' \
  || echo "no /var/log/lightdm/lightdm.log"

sec "SEAT0 GREETER LOG (tail)"
tail -25 /var/log/lightdm/seat0-greeter.log 2>/dev/null || echo "no greeter log"

sec "X SESSION ERRORS FOR arduino"
tail -25 /home/arduino/.xsession-errors 2>/dev/null || echo "no ~arduino/.xsession-errors"

sec "PAM: lightdm-autologin"
cat /etc/pam.d/lightdm-autologin 2>/dev/null || echo "MISSING /etc/pam.d/lightdm-autologin"

sec "DOES arduino HAVE A SHADOW ENTRY AT ALL?"
if grep -q '^arduino:' /etc/shadow 2>/dev/null; then
  echo "yes:"; grep '^arduino:' /etc/shadow | cut -d: -f1,3-8
else
  echo "NO — /etc/shadow has no arduino line. pam_unix account checks will fail."
fi
echo "--- passwd entry ---"
grep '^arduino:' /etc/passwd

sec "EFFECTIVE LIGHTDM CONFIG (is our drop-in being read?)"
lightdm --show-config 2>/dev/null | sed -n '1,60p' || echo "lightdm --show-config unavailable"

sec "MEMORY HEADROOM (matters if we add a second X server)"
free -h

sec "IS xvfb AVAILABLE?"
command -v Xvfb || echo "Xvfb not installed"
apt-cache policy xvfb 2>/dev/null | head -3

sec "DONE"
