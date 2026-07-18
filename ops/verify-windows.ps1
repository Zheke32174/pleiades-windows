# Verify the Windows-side Pleiades collector, supervisor, snapshot, and portal.
# Static checks run by default. Live failed-logon and recovery tests are opt-in.

[CmdletBinding()]
param(
  [string]$Root = 'C:\pleiades',
  [string]$Distro = 'Ubuntu',
  [switch]$Integration,
  [switch]$DestructiveRecoveryTest
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Pass([string]$Message) { $script:Pass++; Write-Output "  [PASS] $Message" }
function Fail([string]$Message) { $script:Fail++; Write-Output "  [FAIL] $Message" }
function Check([string]$Message, [scriptblock]$Test) {
  try { if (& $Test) { Pass $Message } else { Fail $Message } } catch { Fail "$Message — $($_.Exception.Message)" }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$required = @(
  'bin/pleiades-collector.ps1',
  'bin/pleiades-supervisor.ps1',
  'bin/pleiades-netwatch.ps1',
  'bin/pleiades-snapshot.sh',
  'portal/pleiades.php'
)

Write-Output '== A. Repository structure and syntax =='
foreach ($relative in $required) {
  $path = Join-Path $repoRoot $relative
  Check "$relative present" { Test-Path $path }
}

foreach ($path in Get-ChildItem -Path (Join-Path $repoRoot 'bin'), (Join-Path $repoRoot 'ops') -Filter '*.ps1' -File) {
  Check "$($path.Name) parses as PowerShell" {
    [void][scriptblock]::Create((Get-Content $path.FullName -Raw))
    return $true
  }
}

Check 'snapshot shell script parses' {
  & bash -n (Join-Path $repoRoot 'bin/pleiades-snapshot.sh')
  return $LASTEXITCODE -eq 0
}

if (Get-Command php -ErrorAction SilentlyContinue) {
  Check 'Command Deck PHP parses' {
    & php -l (Join-Path $repoRoot 'portal/pleiades.php') | Out-Null
    return $LASTEXITCODE -eq 0
  }
} else {
  Write-Output '  [SKIP] php is unavailable; portal parse not checked'
}

$collectorSource = Get-Content (Join-Path $repoRoot 'bin/pleiades-collector.ps1') -Raw
Check 'collector uses typed cursor schema' {
  return $collectorSource.Contains("pleiades.windows-security-cursor/v1")
}
Check 'collector event identity includes collection epoch' {
  return $collectorSource.Contains('collection_epoch') -and
    $collectorSource.Contains('$($cursorState.collection_epoch)/$($event.RecordId)')
}
Check 'collector cursor replacement is durable and atomic' {
  return $collectorSource.Contains('function Write-AtomicUtf8') -and
    $collectorSource.Contains('$stream.Flush($true)') -and
    $collectorSource.Contains('[IO.File]::Replace')
}
Check 'collector refuses implicit log reset' {
  return $collectorSource.Contains('[switch]$AcceptLogReset') -and
    $collectorSource.Contains('Security log identity/high-water no longer matches')
}
Check 'collector strictly parses legacy cursor before migration' {
  return $collectorSource.Contains('legacy collector cursor is corrupt; refusing implicit replay')
}
Check 'collector no longer writes naked cursor text' {
  return -not $collectorSource.Contains("Set-Content -Path `$cursorFile")
}

Write-Output '== B. Installed-state checks =='
$snapshotPath = Join-Path $Root 'portal\status.json'
if (Test-Path $snapshotPath) {
  Check 'published snapshot uses pleiades.status/v1' {
    $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json
    return $snapshot.schema -eq 'pleiades.status/v1'
  }
  Check 'published snapshot is fresh' {
    return ((Get-Date) - (Get-Item $snapshotPath).LastWriteTime).TotalMinutes -lt 20
  }
} else {
  Write-Output '  [SKIP] no installed status snapshot was found'
}

$mirror = Join-Path $Root 'backup'
Check 'snapshot mirror contains no escrow key' { -not (Test-Path (Join-Path $mirror 'escrow.key')) }

if ($Integration) {
  Write-Output '== C. Live integration =='
  $collector = Join-Path $repoRoot 'bin/pleiades-collector.ps1'
  $supervisor = Join-Path $repoRoot 'bin/pleiades-supervisor.ps1'

  Check 'collector completes' {
    & $collector -Root $Root | Out-Null
    return $LASTEXITCODE -eq 0
  }

  Check 'supervisor publishes a valid snapshot' {
    & $supervisor -Root $Root -Distro $Distro | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $snapshotPath)) { return $false }
    $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json
    return $snapshot.schema -eq 'pleiades.status/v1' -and $snapshot.container -in 'running', 'degraded'
  }

  if ($DestructiveRecoveryTest) {
    Write-Output '== D. Opt-in recovery interruption =='
    Check 'container restarts after an intentional stop' {
      & wsl.exe -d $Distro -u root -- systemctl stop pleiades-container.service | Out-Null
      if ($LASTEXITCODE -ne 0) { return $false }
      & $supervisor -Root $Root -Distro $Distro | Out-Null
      if ($LASTEXITCODE -ne 0) { return $false }
      $state = (& wsl.exe -d $Distro -u root -- machinectl show pleiades -p State --value 2>$null | Select-Object -Last 1)
      return "$state" -in 'running', 'degraded'
    }
  }
}

Write-Output ''
Write-Output '===================================='
Write-Output "   WINDOWS-SIDE RESULT: PASS=$script:Pass FAIL=$script:Fail"
Write-Output '===================================='

if ($script:Fail -gt 0) { exit 1 }
exit 0
