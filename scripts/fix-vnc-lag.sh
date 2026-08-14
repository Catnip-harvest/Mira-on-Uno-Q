#!/bin/bash
# Mira — measure, then reduce, noVNC latency. Run: ssh mira-wifi bash -s < this-file
sec() { echo; echo "===== $1 ====="; }

sec "1. BEFORE — WHO IS BURNING CPU"
uptime
ps -eo pcpu,pmem,rss,comm --sort=-pcpu | head -12
echo "--- x11vnc specifically ---"
ps -eo pcpu,pmem,rss,args -C x11vnc --no-headers 2>/dev/null || echo "(x11vnc not running)"

sec "2. BEFORE — MEMORY"
free -h

sec "3. FIX A: DROP -noxdamage (it forces full-screen polling)"
sed -i 's/ -noxdamage//' /etc/systemd/system/mira-x11vnc.service
# Cheaper wire format + fewer wakeups. -wait raises the poll interval floor.
sed -i 's|-forever -shared|-forever -shared -wait 30 -defer 30|' /etc/systemd/system/mira-x11vnc.service
grep ExecStart -A1 /etc/systemd/system/mira-x11vnc.service

sec "4. FIX B: TURN OFF XFCE COMPOSITING (no GPU headroom for it)"
SPID=$(pgrep -u arduino -x xfce4-session | head -1)
if [ -n "$SPID" ]; then
  DBA=$(tr '\0' '\n' < "/proc/$SPID/environ" | grep '^DBUS_SESSION_BUS_ADDRESS=' | cut -d= -f2-)
  echo "session bus: ${DBA:0:40}..."
  run_x() { su arduino -s /bin/bash -c "DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='$DBA' $1" 2>&1; }
  run_x "xfconf-query -c xfwm4 -p /general/use_compositing -s false --create -t bool"
  echo "compositing now: $(run_x 'xfconf-query -c xfwm4 -p /general/use_compositing')"
  # A solid colour costs far less to re-encode than a photo wallpaper.
  run_x "xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorVNC-0/workspace0/image-style -s 0 --create -t int" >/dev/null 2>&1
  run_x "xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/image-style -s 0 --create -t int" >/dev/null 2>&1
  echo "wallpaper set to solid where applicable"
else
  echo "no xfce4-session found for arduino - skipping compositing tweak"
fi

sec "5. RESTART VNC WITH NEW FLAGS"
systemctl daemon-reload
systemctl restart mira-x11vnc.service
sleep 3
systemctl restart mira-novnc.service
sleep 2
systemctl is-active mira-x11vnc.service mira-novnc.service
ss -tlnp | grep -E '5900|6080' || echo "NOT LISTENING"

sec "6. AFTER — CPU"
sleep 5
ps -eo pcpu,pmem,rss,comm --sort=-pcpu | head -10
echo "--- x11vnc now ---"
ps -eo pcpu,pmem,rss --no-headers -C x11vnc 2>/dev/null

sec "7. AFTER — MEMORY"
free -h

sec "8. CPU CAPABILITY CHECK (is the board itself throttling?)"
for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
  [ -r "$p" ] && echo "$(dirname "$(dirname "$p")" | xargs basename): $(( $(cat "$p") / 1000 )) MHz"
done
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
echo "--- thermal ---"
for z in /sys/class/thermal/thermal_zone*/temp; do
  [ -r "$z" ] && echo "$(basename "$(dirname "$z")"): $(( $(cat "$z") / 1000 ))C"
done | head -6

sec "DONE"
