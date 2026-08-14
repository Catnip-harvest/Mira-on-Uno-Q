# Mira — open a shell on the UNO Q over USB.
#   powershell -File scripts\mira-shell.ps1            # interactive shell
#   powershell -File scripts\mira-shell.ps1 -Cmd "df -h"   # one-shot command
#
# The adb forward does NOT survive a replug or board reboot, so this
# re-establishes it every time. Safe to run repeatedly.
param([string]$Cmd = '')

$adb = "$env:USERPROFILE\bin\platform-tools\adb.exe"
if (-not (Test-Path $adb)) { Write-Error "adb not found at $adb"; exit 1 }

Write-Host '[mira] waiting for board over USB...' -ForegroundColor Cyan
& $adb wait-for-device
$serial = (& $adb devices | Select-String -Pattern '\sdevice$' | ForEach-Object { ($_ -split '\s+')[0] }) -join ','
if (-not $serial) { Write-Error '[mira] no authorized adb device. Replug the USB-C cable.'; exit 1 }
Write-Host "[mira] board: $serial" -ForegroundColor Green

# Make sure sshd is actually up (it is enabled, but a fresh flash may not have it).
$active = (& $adb shell systemctl is-active ssh.service).Trim()
if ($active -ne 'active') {
    Write-Host "[mira] ssh.service is '$active' - starting it" -ForegroundColor Yellow
    & $adb shell systemctl start ssh.service | Out-Null
}

& $adb forward tcp:2222 tcp:22 | Out-Null
Write-Host '[mira] forward ready: localhost:2222 -> board:22' -ForegroundColor Green

if ($Cmd) { & ssh mira $Cmd } else { & ssh mira }
