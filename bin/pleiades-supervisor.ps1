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
  [string]$ValidateSnapshotJson,
  [ValidateSet('down', 'running', 'degraded')]
  [string]$ExpectedSnapshotContainerState
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$CanonicalMachine = 'pleiades'
$CanonicalUnit = 'pleiades-container.service'
$MaxSnapshotBytes = 2MB
$MaxSnapshotCollectionItems = 4096
$MaxAgentProperties = 64
$MaxAgentDepth = 6
$MaxAgentStringLength = 4096

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

function Get-RequiredJsonProperty([pscustomobject]$Object, [string]$Name) {
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    throw "snapshot is missing required field: $Name"
  }
  return $property
}

function Assert-ExactJsonProperties(
  [pscustomobject]$Object,
  [string]$Path,
  [string[]]$Expected
) {
  $actual = @($Object.PSObject.Properties.Name)
  if ($actual.Count -ne $Expected.Count) {
    throw "$Path must contain exactly: $($Expected -join ', ')"
  }
  foreach ($name in $Expected) {
    if ($actual -cnotcontains $name) {
      throw "$Path must contain exactly: $($Expected -join ', ')"
    }
  }
}

function Assert-NoDuplicateJsonProperties(
  [System.Text.Json.JsonElement]$Element,
  [string]$Path,
  [int]$Depth = 0
) {
  if ($Depth -gt 32) { throw 'snapshot JSON nesting exceeds 32 levels' }
  if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
      if (-not $names.Add($property.Name)) {
        throw "snapshot contains duplicate property at ${Path}.$($property.Name)"
      }
      Assert-NoDuplicateJsonProperties -Element $property.Value -Path "${Path}.$($property.Name)" -Depth ($Depth + 1)
    }
  } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
    $index = 0
    foreach ($item in $Element.EnumerateArray()) {
      Assert-NoDuplicateJsonProperties -Element $item -Path "${Path}[$index]" -Depth ($Depth + 1)
      $index++
    }
  }
}

function Assert-BoundedAgentValue(
  $Value,
  [string]$Path,
  [int]$Depth = 0
) {
  if ($Depth -gt $MaxAgentDepth) {
    throw "$Path exceeds the bounded agent-record nesting depth"
  }
  if ($null -eq $Value -or $Value -is [bool] -or
      $Value -is [int] -or $Value -is [long]) {
    return
  }
  if ($Value -is [string]) {
    if ($Value.Length -gt $MaxAgentStringLength -or $Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
      throw "$Path contains an oversized or unsupported string"
    }
    return
  }
  if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
    throw "$Path must not contain floating-point identity"
  }
  if ($Value -is [System.Array]) {
    if ($Value.Count -gt 128) { throw "$Path exceeds 128 array items" }
    for ($index = 0; $index -lt $Value.Count; $index++) {
      Assert-BoundedAgentValue -Value $Value[$index] -Path "${Path}[$index]" -Depth ($Depth + 1)
    }
    return
  }
  if ($Value -is [pscustomobject]) {
    $properties = @($Value.PSObject.Properties)
    if ($properties.Count -gt $MaxAgentProperties) {
      throw "$Path exceeds $MaxAgentProperties properties"
    }
    foreach ($property in $properties) {
      if ($property.Name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') {
        throw "$Path contains an invalid property name: $($property.Name)"
      }
      Assert-BoundedAgentValue -Value $property.Value -Path "${Path}.$($property.Name)" -Depth ($Depth + 1)
    }
    return
  }
  throw "$Path contains an unsupported JSON value type"
}

function ConvertFrom-ValidatedSnapshot(
  [string]$Raw,
  [string]$ExpectedContainerState
) {
  if ([string]::IsNullOrWhiteSpace($Raw)) {
    throw 'snapshot JSON is empty'
  }

  $trimmed = $Raw.Trim()
  if ($trimmed.Length -lt 2 -or $trimmed[0] -ne '{' -or $trimmed[$trimmed.Length - 1] -ne '}') {
    throw 'snapshot top level must be exactly one JSON object'
  }

  $document = $null
  try {
    $document = [System.Text.Json.JsonDocument]::Parse($trimmed)
    Assert-NoDuplicateJsonProperties -Element $document.RootElement -Path '$'
  } catch {
    throw "snapshot JSON object identity is invalid: $($_.Exception.Message)"
  } finally {
    if ($null -ne $document) { $document.Dispose() }
  }

  try {
    $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "snapshot is not valid JSON: $($_.Exception.Message)"
  }
  if ($null -eq $parsed -or $parsed -is [Array] -or $parsed -isnot [pscustomobject]) {
    throw 'snapshot top level must be exactly one JSON object'
  }

  Assert-ExactJsonProperties -Object $parsed -Path 'snapshot' -Expected @(
    'schema', 'container', 'timestamp', 'ledger', 'agents', 'events'
  )

  $schema = (Get-RequiredJsonProperty $parsed 'schema').Value
  if ($schema -isnot [string] -or $schema -cne 'pleiades.status/v1') {
    throw 'snapshot schema must be the exact scalar pleiades.status/v1'
  }

  $container = (Get-RequiredJsonProperty $parsed 'container').Value
  if ($container -isnot [string] -or $container -notin 'down', 'running', 'degraded') {
    throw 'snapshot container must be exactly down, running, or degraded'
  }
  if ($ExpectedContainerState -and $container -cne $ExpectedContainerState) {
    throw "snapshot container state $container disagrees with independently observed state $ExpectedContainerState"
  }

  $timestamp = (Get-RequiredJsonProperty $parsed 'timestamp').Value
  if (($timestamp -isnot [int] -and $timestamp -isnot [long]) -or $timestamp -lt 1) {
    throw 'snapshot timestamp must be a positive integer scalar'
  }

  $ledger = (Get-RequiredJsonProperty $parsed 'ledger').Value
  if ($null -eq $ledger -or $ledger -is [Array] -or $ledger -isnot [pscustomobject]) {
    throw 'snapshot ledger must be exactly one object'
  }
  Assert-ExactJsonProperties -Object $ledger -Path 'snapshot.ledger' -Expected @('state', 'records')
  $ledgerState = (Get-RequiredJsonProperty $ledger 'state').Value
  if ($ledgerState -isnot [string] -or
      $ledgerState -notin 'VALID', 'EMPTY', 'MISSING', 'TAMPERED', 'ERROR', 'UNKNOWN') {
    throw 'snapshot ledger.state must be one recognized scalar'
  }
  $ledgerRecords = (Get-RequiredJsonProperty $ledger 'records').Value
  if (($ledgerRecords -isnot [int] -and $ledgerRecords -isnot [long]) -or $ledgerRecords -lt 0) {
    throw 'snapshot ledger.records must be a nonnegative integer scalar'
  }

  $agents = (Get-RequiredJsonProperty $parsed 'agents').Value
  $events = (Get-RequiredJsonProperty $parsed 'events').Value
  foreach ($field in 'agents', 'events') {
    $collection = if ($field -eq 'agents') { $agents } else { $events }
    if ($collection -isnot [System.Array]) {
      throw "snapshot $field must be an array"
    }
    if ($collection.Count -gt $MaxSnapshotCollectionItems) {
      throw "snapshot $field exceeds $MaxSnapshotCollectionItems items"
    }
  }

  foreach ($agent in $agents) {
    if ($null -eq $agent -or $agent -is [Array] -or $agent -isnot [pscustomobject]) {
      throw 'snapshot agents entries must be objects'
    }
    $agentName = (Get-RequiredJsonProperty $agent 'agent').Value
    $agentStatus = (Get-RequiredJsonProperty $agent 'status').Value
    if ($agentName -isnot [string] -or $agentName -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$') {
      throw 'snapshot agent.agent must be one bounded identifier'
    }
    if ($agentStatus -isnot [string] -or $agentStatus -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$') {
      throw 'snapshot agent.status must be one bounded identifier'
    }
    Assert-BoundedAgentValue -Value $agent -Path "snapshot.agents[$agentName]"
  }

  $lastSequence = 0L
  foreach ($event in $events) {
    if ($null -eq $event -or $event -is [Array] -or $event -isnot [pscustomobject]) {
      throw 'snapshot events entries must be objects'
    }
    Assert-ExactJsonProperties -Object $event -Path 'snapshot.events[]' -Expected @(
      'seq', 'timestamp', 'digest', 'event'
    )
    $sequence = (Get-RequiredJsonProperty $event 'seq').Value
    $eventTimestamp = (Get-RequiredJsonProperty $event 'timestamp').Value
    $digest = (Get-RequiredJsonProperty $event 'digest').Value
    $eventText = (Get-RequiredJsonProperty $event 'event').Value
    if (($sequence -isnot [int] -and $sequence -isnot [long]) -or $sequence -lt 1) {
      throw 'snapshot event.seq must be a positive integer'
    }
    if ([long]$sequence -le $lastSequence) {
      throw 'snapshot events must use strictly increasing unique sequence values'
    }
    $lastSequence = [long]$sequence
    if (($eventTimestamp -isnot [int] -and $eventTimestamp -isnot [long]) -or $eventTimestamp -lt 1) {
      throw 'snapshot event.timestamp must be a positive integer'
    }
    if ($digest -isnot [string] -or $digest -notmatch '^[0-9a-f]{64}$') {
      throw 'snapshot event.digest must be one lowercase SHA-256 scalar'
    }
    if ($eventText -isnot [string] -or $eventText.Length -gt 2048 -or
        $eventText -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
      throw 'snapshot event.event must be one bounded text scalar'
    }
  }

  if ($container -eq 'down') {
    if ($ledgerState -cne 'UNKNOWN' -or $ledgerRecords -ne 0 -or
        $agents.Count -ne 0 -or $events.Count -ne 0) {
      throw 'a down snapshot must contain UNKNOWN empty ledger state and no agent or event records'
    }
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

function Publish-Snapshot(
  [string]$BridgeRoot,
  [string]$ExpectedContainerState
) {
  $snapshotScript = "$BridgeRoot/bin/pleiades-snapshot.sh"
  $result = Invoke-WslTyped -Arguments @('bash', '--', $snapshotScript)
  $raw = $result.Output -join "`n"
  $byteCount = [Text.UTF8Encoding]::new($false).GetByteCount($raw)
  if ($byteCount -lt 2 -or $byteCount -gt $MaxSnapshotBytes) {
    throw "snapshot size is outside the accepted bound: $byteCount bytes"
  }
  $parsed = ConvertFrom-ValidatedSnapshot -Raw $raw -ExpectedContainerState $ExpectedContainerState

  $destination = Join-Path $portalDir 'status.json'
  Write-AtomicUtf8 -Path $destination -Text ($raw + "`n")
  Write-Log "snapshot published ($byteCount bytes, container=$($parsed.container), ledger=$($parsed.ledger.state))"
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
if ($PSBoundParameters.ContainsKey('ExpectedSnapshotContainerState') -and
    -not $PSBoundParameters.ContainsKey('ValidateSnapshotJson')) {
  throw 'ExpectedSnapshotContainerState is valid only with ValidateSnapshotJson'
}
if ($PSBoundParameters.ContainsKey('ValidateSnapshotJson')) {
  ConvertFrom-ValidatedSnapshot -Raw $ValidateSnapshotJson -ExpectedContainerState $ExpectedSnapshotContainerState | Out-Null
  Write-Output 'snapshot JSON is valid, exact, and bounded'
  exit 0
}
if ($ValidateConfigurationOnly) {
  Write-Output "configuration valid: distro=$Distro machine=$CanonicalMachine unit=$CanonicalUnit root=$Root"
  exit 0
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
  Publish-Snapshot -BridgeRoot $bridgeRoot -ExpectedContainerState $state
  Mirror-EncryptedSnapshots -BridgeRoot $bridgeRoot
  exit 0
} catch {
  Write-Log "FAILED: $($_.Exception.Message)"
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
