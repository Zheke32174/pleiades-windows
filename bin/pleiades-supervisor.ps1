# pleiades-supervisor.ps1 — Windows-side lifecycle and status coordinator.
#
# The Linux host's systemd unit is the sole container supervisor. This script
# may query and start exactly one canonical unit and machine through typed WSL
# argv. It publishes one validated status snapshot and mirrors encrypted
# snapshots into the exact installed Windows root.

[CmdletBinding()]
param(
  [string]$Root = 'C:\pleiades',
  [string]$Distro = 'Ubuntu',
  [string]$Machine = 'pleiades',
  [string]$Unit = 'pleiades-container.service',
  [switch]$ValidateConfigurationOnly,
  [string]$ValidateSnapshotPath
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$CanonicalMachine = 'pleiades'
$CanonicalUnit = 'pleiades-container.service'
$MaxSnapshotBytes = 2MB

function Assert-Configuration {
  if ($Distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw 'Distro must use a bounded non-shell identifier'
  }
  if ($Machine -cne $CanonicalMachine) {
    throw "Machine must be exactly $CanonicalMachine"
  }
  if ($Unit -cne $CanonicalUnit) {
    throw "Unit must be exactly $CanonicalUnit"
  }
  if ([string]::IsNullOrWhiteSpace($Root) -or $Root -match '[\x00-\x1F\x7F"]') {
    throw 'Root is empty or contains an unsupported control character or quote'
  }
  if ($IsWindows) {
    $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $driveRoot = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
    if ($resolved.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing drive root as Root: $resolved"
    }
    $script:Root = $resolved
  }
}

function Assert-PosixPath([string]$Name, [string]$Value) {
  if ($Value -notmatch '^/[A-Za-z0-9._/-]+$') {
    throw "$Name is not a bounded absolute POSIX path"
  }
  $segments = @($Value.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
  if ($segments -contains '.' -or $segments -contains '..') {
    throw "$Name contains a traversal segment"
  }
  if ($Value -eq '/') { throw "$Name must not be the filesystem root" }
  return $Value.TrimEnd('/')
}

function Test-JsonInteger([object]$Value) {
  return (
    $Value -is [byte] -or
    $Value -is [sbyte] -or
    $Value -is [int16] -or
    $Value -is [uint16] -or
    $Value -is [int32] -or
    $Value -is [uint32] -or
    $Value -is [int64] -or
    $Value -is [uint64]
  )
}

function Assert-StatusSnapshot([string]$Raw) {
  $trimmed = $Raw.Trim()
  if (-not $trimmed.StartsWith('{') -or -not $trimmed.EndsWith('}')) {
    throw 'snapshot top-level value must be exactly one JSON object'
  }

  $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $parsed -or $parsed -is [System.Array] -or $parsed -isnot [pscustomobject]) {
    throw 'snapshot top-level value must be exactly one JSON object'
  }

  $propertyNames = @($parsed.PSObject.Properties.Name)
  foreach ($required in 'schema', 'container', 'timestamp', 'ledger', 'agents', 'events') {
    if ($propertyNames -cnotcontains $required) {
      throw "snapshot is missing required field: $required"
    }
  }

  if ($parsed.schema -isnot [string] -or $parsed.schema -cne 'pleiades.status/v1') {
    throw 'snapshot schema must be exactly pleiades.status/v1'
  }
  if ($parsed.container -isnot [string] -or $parsed.container -cnotin 'running', 'degraded') {
    throw 'snapshot container state must be running or degraded'
  }
  if (-not (Test-JsonInteger $parsed.timestamp) -or [int64]$parsed.timestamp -lt 0) {
    throw 'snapshot timestamp must be a non-negative integer'
  }

  if ($null -eq $parsed.ledger -or $parsed.ledger -is [System.Array] -or $parsed.ledger -isnot [pscustomobject]) {
    throw 'snapshot ledger must be exactly one object'
  }
  $ledgerNames = @($parsed.ledger.PSObject.Properties.Name)
  if ($ledgerNames -cnotcontains 'state' -or $ledgerNames -cnotcontains 'records') {
    throw 'snapshot ledger must contain state and records'
  }
  if ($parsed.ledger.state -isnot [string] -or $parsed.ledger.state -cnotin 'VALID', 'EMPTY', 'MISSING', 'TAMPERED', 'ERROR', 'UNKNOWN') {
    throw 'snapshot ledger state is invalid'
  }
  if (-not (Test-JsonInteger $parsed.ledger.records) -or [int64]$parsed.ledger.records -lt 0) {
    throw 'snapshot ledger records must be a non-negative integer'
  }
  if ($parsed.agents -isnot [System.Array]) {
    throw 'snapshot agents must be an array'
  }
  if ($parsed.events -isnot [System.Array]) {
    throw 'snapshot events must be an array'
  }

  return $parsed
}

function Invoke-WslTyped(
  [string[]]$Arguments,
  [int[]]$AllowedExitCodes = @(0)
) {
  $command = @('-d', $Distro, '-u', 'root', '--') + $Arguments
  $output = & wsl.exe @command 2>&1
  $exitCode = $LASTEXITCODE
  if ($AllowedExitCodes -notcontains $exitCode) {
    $rendered = $Arguments | ForEach-Object { "[$_]" }
    throw "typed WSL command failed (rc=$exitCode): $($rendered -join ' ')`n$($output -join "`n")"
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = @($output | ForEach-Object { "$_" })
  }
}

function Invoke-WslScript(
  [string]$Script,
  [string[]]$Arguments
) {
  $command = @('-d', $Distro, '-u', 'root', '--', 'bash', '-s', '--') + $Arguments
  $output = $Script | & wsl.exe @command 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "fixed WSL script failed (rc=$exitCode)`n$($output -join "`n")"
  }
  return @($output | ForEach-Object { "$_" })
}

function Get-WslBridgeRoot {
  $result = Invoke-WslTyped -Arguments @('wslpath', '-a', '-u', $Root)
  $lines = @($result.Output | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($lines.Count -ne 1) { throw 'wslpath returned an ambiguous bridge root' }
  return Assert-PosixPath 'derived WSL bridge root' $lines[0]
}

function Get-ContainerRoot {
  $result = Invoke-WslTyped -Arguments @('cat', '--', '/etc/pleiades/container.env')
  $lines = @(
    $result.Output |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and -not $_.StartsWith('#') }
  )
  if ($lines.Count -ne 1 -or $lines[0] -notmatch '^PLEIADES_ROOT=(/.+)$') {
    throw '/etc/pleiades/container.env must contain exactly one plain PLEIADES_ROOT assignment'
  }
  $root = Assert-PosixPath 'PLEIADES_ROOT' $Matches[1]
  Invoke-WslTyped -Arguments @('test', '-f', "$root/.pleiades-container-root") | Out-Null
  return $root
}

function Get-ContainerState {
  $unitArguments = @('systemctl', 'is-active', '--quiet', $CanonicalUnit)
  $unitState = Invoke-WslTyped -Arguments $unitArguments -AllowedExitCodes @(0, 3, 4)
  if ($unitState.ExitCode -eq 3) { return 'inactive' }
  if ($unitState.ExitCode -eq 4) {
    throw "canonical unit is unknown to systemd: $CanonicalUnit"
  }

  $machineState = Invoke-WslTyped -Arguments @(
    'machinectl', 'show', $CanonicalMachine, '-p', 'State', '--value'
  )
  $lines = @($machineState.Output | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($lines.Count -ne 1 -or $lines[0] -notin 'running', 'degraded') {
    throw "canonical unit is active but machine state is invalid: $($lines -join ',')"
  }
  return $lines[0]
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
  $directory = Split-Path -Parent $Path
  $name = Split-Path -Leaf $Path
  $temporary = Join-Path $directory ".$name.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
  $stream = [IO.FileStream]::new(
    $temporary,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write,
    [IO.FileShare]::None
  )
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  try {
    if (Test-Path -LiteralPath $Path) {
      [IO.File]::Replace($temporary, $Path, $null, $true)
    } else {
      [IO.File]::Move($temporary, $Path)
    }
  } catch {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Publish-Snapshot([string]$BridgeRoot) {
  $snapshotScript = "$BridgeRoot/bin/pleiades-snapshot.sh"
  $result = Invoke-WslTyped -Arguments @('bash', '--', $snapshotScript)
  $raw = $result.Output -join "`n"
  $byteCount = [Text.UTF8Encoding]::new($false).GetByteCount($raw)
  if ($byteCount -lt 2 -or $byteCount -gt $MaxSnapshotBytes) {
    throw "snapshot size is outside the accepted bound: $byteCount bytes"
  }
  $parsed = Assert-StatusSnapshot -Raw $raw

  $destination = Join-Path $portalDir 'status.json'
  Write-AtomicUtf8 -Path $destination -Text ($raw + "`n")
  Write-Log "snapshot published ($byteCount bytes, ledger=$($parsed.ledger.state))"
}

function Mirror-EncryptedSnapshots([string]$BridgeRoot) {
  # Local resilience mirror only. The escrow key remains excluded. Independent
  # recovery replication belongs to another device/provider and credential.
  $containerRoot = Get-ContainerRoot
  $source = "$containerRoot/var/lib/maia/snapshots"
  $destination = "$BridgeRoot/backup"
  $copyScript = @'
set -euo pipefail
src=$1
dst=$2
mkdir -p -- "$dst"
[ -d "$src" ] || exit 0
find "$src" -maxdepth 1 -type f \( -name 'maia-*.enc' -o -name 'maia-*.sig' \) -print0 |
  while IFS= read -r -d '' file; do
    [ -L "$file" ] && exit 20
    base=$(basename -- "$file")
    tmp=$(mktemp -- "$dst/.${base}.tmp.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    cp -- "$file" "$tmp"
    mv -f -- "$tmp" "$dst/$base"
    trap - EXIT
  done
'@
  Invoke-WslScript -Script $copyScript -Arguments @($source, $destination) | Out-Null

  $count = @(Get-ChildItem -LiteralPath $backupDir -Filter 'maia-*.enc' -File -ErrorAction SilentlyContinue).Count
  if (Test-Path -LiteralPath (Join-Path $backupDir 'escrow.key')) {
    throw 'escrow.key must never be present in the Windows snapshot mirror'
  }
  Write-Log "encrypted snapshot mirror contains $count archive(s)"
}

Assert-Configuration
if ($ValidateConfigurationOnly) {
  Write-Output "configuration valid: distro=$Distro machine=$CanonicalMachine unit=$CanonicalUnit root=$Root"
  exit 0
}
if (-not [string]::IsNullOrWhiteSpace($ValidateSnapshotPath)) {
  try {
    $snapshotItem = Get-Item -LiteralPath $ValidateSnapshotPath -Force
    if (-not $snapshotItem.PSIsContainer -and $snapshotItem.Length -le $MaxSnapshotBytes) {
      $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
      $rawSnapshot = $strictUtf8.GetString([IO.File]::ReadAllBytes($snapshotItem.FullName))
      Assert-StatusSnapshot -Raw $rawSnapshot | Out-Null
      Write-Output 'snapshot valid: exactly one typed pleiades.status/v1 object'
      exit 0
    }
    throw 'snapshot fixture must be one bounded regular file'
  } catch {
    Write-Error "snapshot validation failed: $($_.Exception.Message)"
    exit 1
  }
}

$stateDir = Join-Path $Root 'state'
$portalDir = Join-Path $Root 'portal'
$backupDir = Join-Path $Root 'backup'
$null = New-Item -ItemType Directory -Force -Path $stateDir, $portalDir, $backupDir
$logPath = Join-Path $stateDir 'supervisor.log'

function Write-Log([string]$Message) {
  if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 2MB) {
    Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force
  }
  $line = "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK') $Message"
  Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
  Write-Output $line
}

$mutex = [Threading.Mutex]::new($false, 'Global\PleiadesSupervisor')
if (-not $mutex.WaitOne(0)) {
  $mutex.Dispose()
  Write-Output 'another Pleiades supervisor run is active; exiting'
  exit 0
}

try {
  $bridgeRoot = Get-WslBridgeRoot
  $state = Get-ContainerState
  if ($state -eq 'inactive') {
    Write-Log "canonical container inactive; starting $CanonicalUnit"
    Invoke-WslTyped -Arguments @('systemctl', 'start', $CanonicalUnit) | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 1
      $state = Get-ContainerState
      if ($state -ne 'inactive') { break }
    }
    if ($state -eq 'inactive') { throw "$CanonicalUnit did not recover within 60 seconds" }
  }

  Write-Log "container state=$state"
  Publish-Snapshot -BridgeRoot $bridgeRoot
  Mirror-EncryptedSnapshots -BridgeRoot $bridgeRoot
  exit 0
} catch {
  Write-Log "FAILED: $($_.Exception.Message)"
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
