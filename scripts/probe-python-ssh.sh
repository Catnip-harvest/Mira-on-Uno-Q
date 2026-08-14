#!/bin/bash
# Mira — probe Python packaging policy and SSH readiness. Read-only.
sec() { echo; echo "===== $1 ====="; }

sec "PIP"
which pip3 pip || echo "no pip on PATH"
python3 -m pip --version 2>/dev/null || echo "python3 -m pip UNAVAILABLE"

sec "PEP 668 (externally-managed)"
ls /usr/lib/python3*/EXTERNALLY-MANAGED 2>/dev/null || echo "not externally-managed (plain pip install will work)"

sec "VENV / PIPX"
python3 -c 'import venv; print("venv OK")' 2>/dev/null || echo "venv MISSING"
which pipx || echo "pipx MISSING"
dpkg -l python3-venv 2>/dev/null | tail -1

sec "APT AVAILABILITY (offline?)"
ls /etc/apt/sources.list.d/ 2>/dev/null
grep -rhE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | head -10

sec "SSHD POLICY"
grep -nE '^#?[[:space:]]*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AuthorizedKeysFile)' /etc/ssh/sshd_config

sec "SSH HOST KEYS"
ls -1 /etc/ssh/ssh_host_*_key 2>/dev/null || echo "NO HOST KEYS — sshd will fail to start until generated"

sec "SSH SERVICE UNITS"
systemctl list-unit-files 'ssh*' --no-pager 2>/dev/null

sec "ROOT ACCOUNT / USERS"
awk -F: '$3>=1000 || $3==0 {print $1" uid="$3" shell="$7}' /etc/passwd
printf 'root pw field: '
awk -F: '$1=="root"{print substr($2,1,3)"..."}' /etc/shadow 2>/dev/null || echo "unreadable"

sec "DISK — WHAT IS EATING IT"
du -shx /var/lib/docker /usr /opt /home /var/log 2>/dev/null | sort -h

sec "X11 / VNC READINESS"
which x11vnc || echo "x11vnc MISSING (apt install x11vnc)"
ls /var/run/lightdm/root/ 2>/dev/null

sec "DONE"
