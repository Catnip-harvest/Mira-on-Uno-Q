# Getting Into the UNO Q — Human Guide

For a teammate who has never touched this board. Read top to bottom once; after
that you'll only need §1.

---

## 1. The short version

```bash
ssh mira-wifi
```

That's it. You're on the board as root.

To see its desktop in a browser:

```bash
powershell -File scripts/mira-gui.ps1
```

If either fails, the rest of this explains why and what to do.

---

## 2. What this board is, in plain terms

The UNO Q is **two computers on one card**:

- a **Linux computer** (4 cores, 2 GB RAM) running Debian — this is what you SSH into
- a **microcontroller** (STM32) that runs a single small program with precise timing

They share **one USB-C port**, and that port is the source of most confusion.

---

## 3. The three ways in, and when each works

**Wi-Fi (normal).** The board joins Wi-Fi and you SSH to it. This is how you'll
work 95% of the time.

**USB cable (backup).** Only works when the board is in "device mode" — acting
like a USB stick plugged into your PC. Useful for first setup or rescue.

**A screen and keyboard.** Works, but you rarely need it.

> **The important catch:** the board's single USB-C port can either *be* a device
> (talking to your laptop) or *host* devices (camera, mouse, arm) — **never both**.
> If the camera is plugged in, the USB cable to your laptop won't work. That isn't
> a fault; it's one port doing one job at a time.

---

## 4. Finding the board when SSH fails

**Don't hunt for its IP address.** The board announces its own name on the
network. Just use:

```bash
ssh root@Mira.local
```

This keeps working when you change Wi-Fi networks, when the router hands out a
different address, everywhere. The name is **`Mira.local`** — not `uno-q.local`,
even though the board calls itself `uno-q` internally.

If that fails, in order:

1. **Is it powered on?** Check the LEDs.
2. **Is it on the same Wi-Fi as you?** Both devices must be on the same network.
   Phone hotspots often isolate clients from each other.
3. **Give it 60 seconds** after power-on to boot and rejoin Wi-Fi.

**Handy trick when travelling:** name your phone's hotspot the same as your home
Wi-Fi, with the same password. The board joins automatically and you never have
to reconfigure it.

---

## 5. Making the camera work

This is the fiddly part, and **the order matters**. The board has a bug (Arduino's
own, still unfixed) where it decides "am I a host?" in the first few seconds of
boot. Get the order wrong and it decides "no", permanently, until the next reboot.

**The procedure:**

1. Plug the hub into the board. Put the camera and mouse in the hub.
2. **Leave the hub's power unplugged.**
3. Power on the board.
4. **Count: one… two… three.**
5. Now plug in the hub's power.
6. Wait a minute, then check.

**Check it worked:**

```bash
ssh mira-wifi lsusb
```

You should see your hub, camera and mouse listed. If you only see two "root hub"
lines, the sequence missed — power-cycle and try again with slightly different
timing (2 or 4 seconds).

**A free trick:** watch the LED on the USB mouse. If it doesn't light, the board
isn't powering the port and nothing else will work either. It's a 50-cent
diagnostic tool.

---

## 6. If it feels slow

Almost certainly Wi-Fi power saving, not the board — which is usually idle.

It's already fixed on this board, but if it comes back, the desktop-in-a-browser
will feel like typing through treacle (6–8 seconds per keystroke).

**Use SSH instead of the desktop wherever you can.** A terminal sends a few
hundred bytes; the desktop sends a whole screen image. SSH will always feel
instant; the desktop never quite will.

---

## 7. Things that will bite you

**The camera might get a different name.** Linux names devices in the order it
finds them, so `/dev/video0` can become `/dev/video2` if you plug things in
differently. We've fixed this by giving them permanent names:

- `/dev/mira_cam` — the camera, always
- `/dev/mira_arm_bus` — the robot arm's servo bus, always

**Use those names, never the numbered ones.** This is the single most common
cause of "it worked yesterday".

**The microphone moves too.** Use `plughw:CARD=video,DEV=0` for the webcam mic —
never `plughw:1,0`, because that number changes.

**The board's clock can be wrong** if it's been off the network a while. It'll fix
itself once online. If timestamps look strange, that's why.

**Don't yank the power.** Shut it down properly:

```bash
ssh mira-wifi poweroff
```

Pulling power mid-write can corrupt the storage, and there's no backup.

---

## 8. Logging in physically

If you have a keyboard and screen on the board:

- **Username:** `arduino`
- **Password:** `123`

The desktop logs in automatically, so you usually won't be asked.

That password is deliberately weak, which is safe here because **remote login by
password is switched off entirely** — SSH only accepts cryptographic keys. Someone
would need physical access to the board for that password to matter.

---

## 9. Giving another laptop access

On the new laptop:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/unoq-robot-access -C "unoq-robot-access"
cat ~/.ssh/unoq-robot-access.pub
```

Send that `.pub` line to whoever administers the board. It's a **public** key —
safe to paste in chat. The matching private key never leaves your laptop.

Once they've added it:

```bash
ssh -i ~/.ssh/unoq-robot-access root@Mira.local
```

---

## 10. Why this was hard, honestly

Two separate faults were hiding each other:

1. The board wasn't switching on power to its USB port (a missing kernel setting)
2. It was deciding "I'm not a host" too early in boot (Arduino's own open bug)

Fix either one alone and **nothing visibly changes** — you still see no camera. So
every individual fix looked like a failure, right up until both were in place at
once. That's why it took so long, and it's why the boot sequence in §5 is written
so precisely.

Nothing was wrong with the hub, the camera, the cable, or the drivers.
