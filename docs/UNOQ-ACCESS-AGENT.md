# UNO Q Access — Agent Runbook

Machine-oriented. Exact commands, expected output, failure signatures. Written for
an agent driving an Arduino UNO Q (QRB2210, Debian 13 trixie) from a Windows host
over PowerShell + Git Bash. Adapt paths for a Linux host.

---

## 0. Fast path — is access already set up?

```bash
ssh -o ConnectTimeout=8 -o BatchMode=yes mira-wifi 'hostname; uname -r; uptime -p'
```

**Expected:** `Mira`, kernel version, uptime.
**If this works, stop reading. You have access.**

If it fails, do NOT start IP-scanning. Go to §1.

---

## 1. Finding the board — in cost order

Try these in order. Stop at the first that answers.

| # | Method | Command | When it works |
|---|---|---|---|
| 1 | **mDNS** | `ssh root@Mira.local` | Almost always. Survives network + DHCP changes. **Try this first.** |
| 2 | Last known IP | `ssh mira-wifi` | Same network, lease unchanged |
| 3 | ADB over USB | `adb shell` | Board is in USB *device* mode |
| 4 | Subnet sweep | see below | Last resort; slow |

```bash
# mDNS - the single highest-value trick. The board runs avahi and advertises
# itself. Hostname is "Mira", NOT "uno-q" (uname says uno-q; avahi says Mira).
ssh -o ConnectTimeout=8 -i ~/.ssh/id_mira_unoq root@Mira.local 'hostname'
```

```powershell
# Subnet sweep (PowerShell). ~40s for a /24. Only if mDNS is blocked.
$base='192.168.1'
cmd /c "for /L %i in (1,1,254) do @ping -n 1 -w 120 $base.%i >nul 2>&1"
arp -a | Select-String "$base\."
# Then probe port 22 on each. The board's MAC starts 14-b5-cd (this unit).
```

**Pin it permanently** so this never costs time again — put mDNS in `~/.ssh/config`:

```
Host mira-wifi
    HostName Mira.local
    User root
    IdentityFile C:/Users/<you>/.ssh/id_mira_unoq
    UserKnownHostsFile C:/Users/<you>/.ssh/known_hosts_mira
    StrictHostKeyChecking accept-new
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

---

## 2. Bootstrap from zero — no SSH yet

### 2.1 Decide the transport

```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_2341&PID_0078' } |
  Select-Object Status,Class,FriendlyName
```

- `ADB Interface` present → board is in **device mode**. Use ADB (§2.2).
- Nothing → board is in **host mode** or unpowered. ADB is impossible; you need
  the network. If you have neither, you are locked out — see §6.

### 2.2 Install adb (Windows), if absent

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' `
  -OutFile "$env:TEMP\platform-tools.zip" -UseBasicParsing
Expand-Archive "$env:TEMP\platform-tools.zip" -DestinationPath "$env:USERPROFILE\bin" -Force
& "$env:USERPROFILE\bin\platform-tools\adb.exe" devices -l
```

**Expected:** `<serial>  device` — NOT `unauthorized`. Arduino's image ships adbd
with auth disabled, so no RSA fingerprint dialog is needed.

### 2.3 Enable SSH on the board

`sshd` is installed but **has no host keys and is disabled**. Both must be fixed.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_mira_unoq -N "" -C "mira-unoq"
```

```powershell
$adb = "$env:USERPROFILE\bin\platform-tools\adb.exe"
& $adb push "$env:USERPROFILE\.ssh\id_mira_unoq.pub" /tmp/mira.pub
& $adb push scripts\setup-ssh.sh /tmp/setup-ssh.sh
& $adb shell bash /tmp/setup-ssh.sh
```

The script must do, in order:

```bash
ssh-keygen -A                                   # generate missing host keys
install -d -m 700 /root/.ssh
cat /tmp/mira.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
# key-only policy
cat > /etc/ssh/sshd_config.d/10-mira.conf <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl enable --now ssh.service
ss -tlnp | grep :22
```

**Root's password field is `*` (locked)** — key auth is mandatory, not optional.

### 2.4 Lock the private key's ACLs (Windows only)

Win32 OpenSSH refuses keys with loose ACLs:

```powershell
icacls "$env:USERPROFILE\.ssh\id_mira_unoq" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

### 2.5 SSH over the USB cable (no Wi-Fi needed)

```powershell
& $adb forward tcp:2222 tcp:22
ssh -i $env:USERPROFILE\.ssh\id_mira_unoq -p 2222 root@127.0.0.1
```

The forward does **not** survive replug or reboot. Re-run it each time.

---

## 3. Wi-Fi

```bash
nmcli -f SSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list
```

**Critical: an SSID containing a space cannot be passed as argv through
`adb shell`** — the space splits it into two args and you get `ssid-not-found`.
Pass SSID and PSK in files:

```bash
printf %s 'My Network' > /tmp/ssid
printf %s '<psk>'      > /tmp/psk
# script reads both from those paths, then:
nmcli connection add type wifi con-name mira-wifi ifname wlan0 ssid "$SSID" \
  -- wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK"
nmcli connection up mira-wifi
rm -f /tmp/psk /tmp/ssid
```

**Wrong-password signature** (read the journal, don't guess):

```
supplicant interface state: associated -> 4way_handshake
4way_handshake -> disconnected
Activation: (wifi) disconnected during association, asking for new key
state change: need-auth -> failed (reason 'no-secrets')
```

Association succeeding then the 4-way handshake failing = **the PSK is wrong**.
Driver and band are fine.

### 3.1 Disable Wi-Fi power save — always

Default is ON and it destroys interactive latency: RTT swings 40–99 ms with
occasional 2 ms replies (the tell). Fixing it took RTT to **1.17 ms**.

```bash
apt-get install -y iw          # not installed by default
iw dev wlan0 set power_save off
nmcli connection modify mira-wifi 802-11-wireless.powersave 2
```

Persist via a oneshot unit `After=NetworkManager.service` that retries
`iw dev wlan0 set power_save off` for ~60 s.

**If the board "feels slow", check this before anything else.** The board itself
is usually idle (load 0.20, all cores at 2016 MHz, 42 °C).

---

## 4. USB host — the two conditions

Both must hold. Fixing one alone produces *no visible change*, which is what
makes this look like dead hardware.

### 4.1 VBUS must not be switched off

```bash
grep -o regulator_ignore_unused /proc/cmdline
for n in /sys/class/regulator/*/name; do
  grep -qi vbus "$n" && echo "$(cat $n): $(cat $(dirname $n)/state)"
done
```

**Failure signature:** `usb_vbus: disabled`, and in dmesg
`[33.7] usb_vbus: disabling`. The kernel disables regulators nothing claimed.
Stock cmdline has `clk_ignore_unused` and `pd_ignore_unused` but **not** the
regulator one. With no VBUS there is no 5 V on the connector, so nothing can
signal on CC and `partner` reads `none` forever.

**Fix — must go in `/etc/kernel/cmdline`, not the generated entry:**

```bash
BASE=$(tr ' ' '\n' < /proc/cmdline | grep -v '^initrd=' | tr '\n' ' ')
printf '%s\n' "$BASE regulator_ignore_unused" > /etc/kernel/cmdline
sed -i 's|^\(options .*\)$|\1 regulator_ignore_unused|' /boot/efi/loader/entries/*.conf
```

**Why `/etc/kernel/cmdline`:** `kernel-install` regenerates loader entries from
Debian's template and silently discards direct edits. This reverted once and
invalidated several test cycles.

### 4.2 Boot-order sequence

Works around [arduino/linux-qcom#2](https://github.com/arduino/linux-qcom/issues/2)
(open): the PM4125 Type-C controller "detects nothing on CC pins" when the board
boots without a partner, so `dwc3-qcom` defaults to device mode.

**Physical procedure — order is load-bearing:**

1. Hub connected to the board, devices in the hub, **hub power disconnected**
2. Power on the board
3. **Wait ~3 s** (xHCI initialises at ~5.4 s — the window closes there)
4. Power the hub

Powering the hub first, or after boot completes, does **not** work.

Also install a boot unit writing `host` to
`/sys/kernel/debug/usb/4e00000.usb/mode` (documented workaround; harmless, not
sufficient alone).

### 4.3 Verify

```bash
echo "partner = $([ -d /sys/class/typec/port0-partner ] && echo PRESENT || echo none)"
lsusb
```

**Success looks like:**

```
Bus 001 Device 002: ID 214b:7260 Huasheng Electronics USB2.0 HUB
Bus 001 Device 005: ID 349c:3307 Generic HD video
Bus 001 Device 006: ID 4e53:5406 USB OPTICAL MOUSE
```

**Physical probe:** a USB mouse's LED. Dark = no VBUS. It costs nothing and
distinguishes a power fault from a data fault instantly.

### 4.4 Required kernel

`6.16.0-geffa8626771a` (shipped) has the dwc3 role bug and is **no longer in the
repo**. Install `7.0.0-g122c2c22d838` from Arduino's apt repo:

```bash
apt-get install -y linux-image-7.0.0-g122c2c22d838
```

⚠️ **EFI variables are read-only on this U-Boot firmware.** `bootctl set-default`
and `set-oneshot` fail with `Read-only file system`. For a safe kernel trial use
**boot counting** instead — rename the entry with a `+3` suffix and mask
`systemd-bless-boot.service` so only you can make it permanent.

---

## 5. Device pinning (do this before any demo)

Probe order is not stable; serials are.

```bash
udevadm info -q property -n /dev/video0 | grep -E 'ID_VENDOR_ID|ID_MODEL_ID|ID_SERIAL_SHORT'
udevadm info -q property -n /dev/ttyACM0 | grep -E 'ID_SERIAL_SHORT'
```

```bash
cat > /etc/udev/rules.d/99-mira.rules <<'RULES'
SUBSYSTEM=="video4linux", ATTRS{idVendor}=="349c", ATTRS{idProduct}=="3307", ATTR{index}=="0", SYMLINK+="mira_cam", MODE="0660", GROUP="video"
SUBSYSTEM=="tty", ATTRS{serial}=="5A7C118584", SYMLINK+="mira_arm_bus", MODE="0660", GROUP="dialout"
RULES
udevadm control --reload-rules && udevadm trigger
```

`ATTR{index}=="0"` matters — a UVC camera also exposes a metadata node that will
otherwise win the symlink.

**ALSA indices shift when the webcam attaches**: webcam becomes card 0, onboard
codec moves to card 1. Always pin by name:

```
plughw:CARD=video,DEV=0             # webcam mic
plughw:CARD=ArduinoImolaHPH,DEV=0   # onboard codec
```

---

## 6. Adding another machine's key

Public keys are not secrets; paste them directly.

```bash
KEY='ssh-ed25519 AAAA... comment'
install -d -m 700 /root/.ssh
grep -qxF "$KEY" /root/.ssh/authorized_keys || printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -lf /root/.ssh/authorized_keys     # verify by fingerprint
```

---

## 7. Setting a short password

PAM's 8-character minimum applies when a **user** changes their own password.
**Root setting another account's password bypasses it entirely** — no policy needs
weakening:

```bash
echo 'arduino:<choose-a-password>' | chpasswd
passwd -S arduino          # expect: arduino P ...
```

Safe here only because `sshd -T` reports `passwordauthentication no`. Verify that
before setting anything weak.

---

## 8. Gotchas that cost real time

| Gotcha | Signature | Fix |
|---|---|---|
| PowerShell mangles quotes into `adb shell` | `/bin/sh: Syntax error: word unexpected` | Push a script, run `bash /tmp/x.sh`. Never inline quoted commands. |
| SSID with a space via argv | `ssid-not-found` | Pass SSID and PSK in files |
| `kernel-install` wipes cmdline edits | Param vanishes after a while | Write `/etc/kernel/cmdline` |
| EFI vars read-only | `Failed to update EFI variable ... Read-only file system` | Use boot counting (`+3` suffix) |
| Wi-Fi power save | RTT 40–99 ms with occasional 2 ms | `iw dev wlan0 set power_save off` |
| Board clock ~6 weeks behind | TLS failures, nonsense log timestamps | `timedatectl set-ntp true` once networked |
| `sys.exit()` at import time | Module untestable without hardware | Defer to `main()` |
| Hostname mismatch | `uno-q.local` does not resolve | It is **`Mira.local`** |
| Screen blanks → black VNC | Looks like a crash | `xset s off -dpms`, kill `light-locker` |
| lightdm autologin fails | PAM returns **20** `PAM_AUTHTOK_ERR` | `chage -d $(date +%F) arduino` — `sp_lstchg=0` forces a password change autologin can't satisfy |

---

## 9. Diagnostic decision tree

```
Can't reach board
├─ ssh Mira.local works? ────────────── DONE
├─ adb devices shows it? ───────────── device mode; adb forward tcp:2222 tcp:22
└─ neither ───────────────────────────  board off, or host mode + wrong network
                                         → power-cycle; check LEDs

USB device not appearing
├─ usb_vbus == disabled? ───────────── power fault → §4.1 (check /proc/cmdline)
├─ partner == none, vbus enabled? ──── CC/data fault → §4.2 boot sequence
├─ mouse LED dark? ─────────────────── no VBUS, confirms power fault
└─ dmesg silent since boot? ────────── nothing electrical arrived at all

Slow / laggy
├─ RTT erratic 40-99ms? ────────────── Wi-Fi power save → §3.1
├─ load high, cores throttled? ─────── genuine CPU limit
└─ RTT ~1ms but VNC slow? ──────────── VNC is inherently heavy; use SSH
```
