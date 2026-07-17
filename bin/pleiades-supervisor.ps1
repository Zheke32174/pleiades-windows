# pleiades-supervisor.ps1 — Windows-side lifecycle and status coordinator.
#
# The Linux host's systemd unit is the sole container supervisor. This script
# starts WSL when necessary, asks systemd for the canonical unit state, publishes
# an atomically validated status snapshot, and mirrors encrypted snapshots.

[CmdletBinding()]
param(
  [string]$Root = 'C:\pleiades',
  [string]$Distro = 'Ubuntu',
  [string]$Machine = 'pleiades',
  [string]$Unit = 'pleiades-container.service',
  [string]$LinuxBridgeRoot = '/mnt/c/pleiades'
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

$stateDir = Join-Path $Root 'state'
$portalDir = Join-Path $Root 'portal'
$backupDir = Join-Path $Root 'backup'
$null = New-Item -ItemType Directory -Force -Path $stateDir, $portalDir, $backupDir
$logPath = Join-Path $stateDir 'supervisor.log'

$mutex = [Threading.Mutex]::new($false, 'Global\PleiadesSupervisor')
if (-not $mutex.WaitOne(0)) {
  Write-Output 'another Pleiades supervisor run is active; exiting'
  exit 0
}

function Write-Log([string]$Message) {
  if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 2MB) {
    Move-Item -Force $logPath "$logPath.1"
  }
  $line = "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK') $Message"
  Add-Content -Path $logPath -Value $line -Encoding utf8
  Write-Output $line
}

function Invoke-WslBash([string]$Command) {
  $output = & wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "WSL command failed (rc=$LASTEXITCODE): $Command`n$($output -join "`n")"
  }
  return @($output)
}

function Get-ContainerState {
  try {
    $cmd = "systemctl is-active '$Unit' >/dev/null 2>&1 || exit 3; machinectl show '$Machine' -p State --value"
    $state = (Invoke-WslBash $cmd | Select-Object -Last 1).Trim()
    if ($state -in 'running', 'degraded') { return $state }
    return 'down'
  } catch {
    return 'down'
  }
}

function Publish-Snapshot {
  $snapshotScript = "$LinuxBridgeRoot/bin/pleiades-snapshot.sh"
  $raw = (Invoke-WslBash "bash '$snapshotScript'") -join "`n"
  $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
  if ($parsed.schema -ne 'pleiades.status/v1') {
    throw "unexpected snapshot schema: $($parsed.schema)"
  }

  $destination = Join-Path $portalDir 'status.json'
  $temporary = "$destination.tmp.$PID"
  $raw | Set-Content -Path $temporary -Encoding utf8NoBOM
  Move-Item -Force $temporary $destination
  Write-Log "snapshot published ($($raw.Length) bytes, ledger=$($parsed.ledger.state))"
}

function Mirror-EncryptedSnapshots {
  # This is a local resilience mirror, not an offsite backup. The escrow key is
  # deliberately excluded. Independent/offsite replication belongs to the
  # recovery plane and should use a separate credential and destination.
  $rootLine = (Invoke-WslBash "set -a; [ -r /etc/pleiades/container.env ] && . /etc/pleiades/container.env; printf '%s' \"${PLEIADES_ROOT:-/var/lib/machines/pleiades}\"") -join ''
  $source = "$rootLine/var/lib/maia/snapshots"
  $copy = @"
set -euo pipefail
src='$source'
dst='$LinuxBridgeRoot/backup'
mkdir -p "`$dst"
[ -d "`$src" ] || exit 0
find "`$src" -maxdepth 1 -type f \( -name 'maia-*.enc' -o -name 'maia-*.sig' \) -print0 |
  while IFS= read -r -d '' f; do
    tmp="`$dst/`$(basename "`$f").tmp"
    cp -- "`$f" "`$tmp"
    mv -f -- "`$tmp" "`$dst/`$(basename "`$f")"
  done
"@
  Invoke-WslBash $copy | Out-Null
  $count = @(Get-ChildItem -Path $backupDir -Filter 'maia-*.enc' -ErrorAction SilentlyContinue).Count
  if (Test-Path (Join-Path $backupDir 'escrow.key')) {
    throw 'escrow.key must never be present in the Windows snapshot mirror'
  }
  Write-Log "encrypted snapshot mirror contains $count archive(s)"
}

try {
  $state = Get-ContainerState
  if ($state -eq 'down') {
    Write-Log "container down; starting $Unit"
    Invoke-WslBash "systemctl start '$Unit'" | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 1
      $state = Get-ContainerState
      if ($state -ne 'down') { break }
    }
    if ($state -eq 'down') { throw "$Unit did not recover within 60 seconds" }
  }

  Write-Log "container state=$state"
  Publish-Snapshot
  Mirror-EncryptedSnapshots
  exit 0
} catch {
  Write-Log "FAILED: $($_.Exception.Message)"
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
