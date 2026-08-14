# Mira — open the UNO Q desktop in your browser.
#
# Works over EITHER transport, automatically:
#   * USB   — if the board is an ADB device, tunnel with `adb forward`
#   * Wi-Fi — otherwise, tunnel with `ssh -L` to mira-wifi
#
# The board binds noVNC to 127.0.0.1 only, so the desktop is never exposed to the
# LAN. Both paths are tunnels; neither publishes anything.
#
#   powershell -File scripts\mira-gui.ps1
#   powershell -File scripts\mira-gui.ps1 -Stop        # tear the tunnel down
param([switch]$NoBrowser, [switch]$Stop)

$ErrorActionPreference = 'Continue'
$adb  = "$env:USERPROFILE\bin\platform-tools\adb.exe"
$port = 6080
$url  = "http://localhost:$port/vnc.html?host=localhost&port=$port&resize=scale&autoconnect=true"
$pidFile = Join-Path $env:TEMP 'mira-gui-tunnel.pid'

function Stop-Tunnel {
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($old) { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host '[mira] ssh tunnel stopped' -ForegroundColor Yellow
    }
}

if ($Stop) { Stop-Tunnel; exit 0 }
Stop-Tunnel   # never stack tunnels on the same port

# --- pick a transport -------------------------------------------------------
$useUsb = $false
if (Test-Path $adb) {
    $devs = & $adb devices | Select-String -Pattern '\sdevice$'
    if ($devs) { $useUsb = $true }
}

if ($useUsb) {
    Write-Host '[mira] transport: USB (adb)' -ForegroundColor Green
    foreach ($svc in 'mira-x11vnc', 'mira-novnc') {
        if ((& $adb shell systemctl is-active "$svc.service").Trim() -ne 'active') {
            & $adb shell systemctl start "$svc.service" | Out-Null
        }
    }
    & $adb forward "tcp:$port" "tcp:$port" | Out-Null
    & $adb forward 'tcp:2222'  'tcp:22'    | Out-Null
} else {
    Write-Host '[mira] no ADB device - transport: Wi-Fi (ssh -L)' -ForegroundColor Yellow
    $probe = & ssh -o ConnectTimeout=10 -o BatchMode=yes mira-wifi 'echo ok' 2>&1
    if ($probe -notmatch 'ok') {
        Write-Error "[mira] cannot reach the board over Wi-Fi either.`n  $probe`n  Check its address:  ssh mira-wifi ip -brief addr show wlan0"
        exit 1
    }
    foreach ($svc in 'mira-x11vnc', 'mira-novnc') {
        & ssh mira-wifi "systemctl is-active --quiet $svc.service || systemctl start $svc.service" 2>&1 | Out-Null
    }
    $p = Start-Process ssh -ArgumentList @(
            '-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15',
            '-L', "${port}:127.0.0.1:$port", 'mira-wifi'
         ) -PassThru -WindowStyle Hidden
    $p.Id | Set-Content $pidFile
    Write-Host "[mira] ssh tunnel up (pid $($p.Id))" -ForegroundColor Green
    Start-Sleep -Seconds 3
}

# --- verify before claiming success ----------------------------------------
try {
    $r = Invoke-WebRequest -Uri "http://localhost:$port/vnc.html" -UseBasicParsing -TimeoutSec 15
    Write-Host "[mira] noVNC reachable (HTTP $($r.StatusCode))" -ForegroundColor Green
} catch {
    Write-Error "[mira] tunnel is up but noVNC did not answer: $($_.Exception.Message)"
    exit 1
}

Write-Host ''
Write-Host '  Desktop:  ' -NoNewline; Write-Host $url -ForegroundColor Cyan
Write-Host '  Shell:    ' -NoNewline; Write-Host $(if ($useUsb) { 'ssh mira' } else { 'ssh mira-wifi' }) -ForegroundColor Cyan
Write-Host '  Stop:      powershell -File scripts\mira-gui.ps1 -Stop' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoBrowser) { Start-Process $url }
