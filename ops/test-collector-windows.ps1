# Disposable end-to-end fixture for pleiades-collector.ps1.
#
# The test replaces only Get-WinEvent inside a child pwsh process. The collector
# itself runs unchanged against a private temporary root, including its real
# durable append, cursor migration, atomic replacement, reset, and event-ID code.

[CmdletBinding()]
param(
  [string]$Collector = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/pleiades-collector.ps1')
)

$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "assertion failed: $Message" }
}

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
  if ("$Actual" -ne "$Expected") {
    throw "assertion failed: $Message (actual=$Actual expected=$Expected)"
  }
}

function Read-Json([string]$Path) {
  return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

$collectorPath = (Resolve-Path -LiteralPath $Collector).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) "pleiades-collector-fixture-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Force -Path $temp

try {
  $fixturePath = Join-Path $temp 'events.json'
  @(
    [ordered]@{
      record_id = 10
      event_id = 4625
      machine = [Environment]::MachineName
      time = '2026-07-19T12:00:00Z'
      data = [ordered]@{
        TargetUserName = 'alice'
        TargetDomainName = 'PLEIADES'
        IpAddress = '192.0.2.10'
        WorkstationName = 'fixture-a'
        LogonType = '3'
        Status = '0xC000006D'
        SubStatus = '0xC000006A'
      }
    },
    [ordered]@{
      record_id = 11
      event_id = 4720
      machine = [Environment]::MachineName
      time = '2026-07-19T12:01:00Z'
      data = [ordered]@{
        TargetUserName = 'bob'
        TargetDomainName = 'PLEIADES'
        IpAddress = '-'
        WorkstationName = 'fixture-b'
        LogonType = '-'
        Status = '-'
        SubStatus = '-'
      }
    }
  ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixturePath -Encoding utf8

  $wrapperPath = Join-Path $temp 'invoke-fixture.ps1'
  @'
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Collector,
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][string]$Fixture,
  [switch]$AcceptLogReset
)

$ErrorActionPreference = 'Stop'
$script:FixtureRoot = $Root
$script:FixtureEvents = @(
  Get-Content -LiteralPath $Fixture -Raw -Encoding utf8 | ConvertFrom-Json
)
$script:StateBroken = $false

function New-FixtureEvent([object]$Item) {
  $event = [pscustomobject]@{
    RecordId = [int64]$Item.record_id
    Id = [int]$Item.event_id
    MachineName = "$($Item.machine)"
    TimeCreated = [datetime]::Parse("$($Item.time)").ToUniversalTime()
    Data = $Item.data
  }
  $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
    $nodes = foreach ($property in $this.Data.PSObject.Properties) {
      $name = [Security.SecurityElement]::Escape("$($property.Name)")
      $value = [Security.SecurityElement]::Escape("$($property.Value)")
      '<Data Name="{0}">{1}</Data>' -f $name, $value
    }
    return '<Event><EventData>{0}</EventData></Event>' -f ($nodes -join '')
  }
  return $event
}

function global:Get-WinEvent {
  [CmdletBinding()]
  param(
    [string]$LogName,
    [int]$MaxEvents,
    [string]$FilterXPath,
    [switch]$Oldest
  )

  if ($LogName -ne 'Security') { throw "unexpected log: $LogName" }
  $events = @($script:FixtureEvents | ForEach-Object { New-FixtureEvent $_ } | Sort-Object RecordId)

  if ([string]::IsNullOrWhiteSpace($FilterXPath)) {
    if ($events.Count -eq 0) { throw 'No events were found' }
    return $events[-1]
  }

  if ($FilterXPath -notmatch 'EventRecordID > ([0-9]+)') {
    throw "unexpected XPath: $FilterXPath"
  }
  [int64]$cursor = $Matches[1]

  if ($env:PLEIADES_FIXTURE_BREAK_STATE_ON_QUERY -eq '1' -and -not $script:StateBroken) {
    $state = Join-Path $script:FixtureRoot 'state'
    $hold = "$state.hold"
    Move-Item -LiteralPath $state -Destination $hold
    Set-Content -LiteralPath $state -Value 'fixture-blocks-cursor-directory' -Encoding ascii
    $script:StateBroken = $true
  }

  $selected = @($events | Where-Object { $_.RecordId -gt $cursor } | Select-Object -First $MaxEvents)
  if ($selected.Count -eq 0) { throw 'No events were found' }
  return $selected
}

$arguments = @('-Root', $Root)
if ($AcceptLogReset) { $arguments += '-AcceptLogReset' }
& $Collector @arguments
'@ | Set-Content -LiteralPath $wrapperPath -Encoding utf8

  function Invoke-FixtureCollector(
    [string]$Root,
    [switch]$AcceptLogReset,
    [switch]$BreakStateOnQuery
  ) {
    if ($BreakStateOnQuery) {
      $env:PLEIADES_FIXTURE_BREAK_STATE_ON_QUERY = '1'
    } else {
      Remove-Item Env:PLEIADES_FIXTURE_BREAK_STATE_ON_QUERY -ErrorAction SilentlyContinue
    }
    try {
      $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $wrapperPath,
        '-Collector', $collectorPath,
        '-Root', $Root,
        '-Fixture', $fixturePath
      )
      if ($AcceptLogReset) { $arguments += '-AcceptLogReset' }
      $output = @(& pwsh @arguments 2>&1)
      $code = $LASTEXITCODE
    } finally {
      Remove-Item Env:PLEIADES_FIXTURE_BREAK_STATE_ON_QUERY -ErrorAction SilentlyContinue
    }

    if ($BreakStateOnQuery) {
      $state = Join-Path $Root 'state'
      $hold = "$state.hold"
      if (Test-Path -LiteralPath $state -PathType Leaf) {
        Remove-Item -LiteralPath $state -Force
      }
      if (Test-Path -LiteralPath $hold -PathType Container) {
        Move-Item -LiteralPath $hold -Destination $state
      }
    }

    return [pscustomobject]@{ Code = $code; Output = ($output -join "`n") }
  }

  # Initial baseline: high-water is recorded without historical backfill.
  $baselineRoot = Join-Path $temp 'baseline'
  $baseline = Invoke-FixtureCollector -Root $baselineRoot
  Assert-Equal $baseline.Code 0 'initial baseline must succeed'
  $baselineCursor = Read-Json (Join-Path $baselineRoot 'state/collector-cursor.v1.json')
  Assert-Equal $baselineCursor.record_id 11 'initial baseline must use current high-water'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $baselineRoot 'spool/windows-events.v1.jsonl'))) 'baseline must not backfill events'

  # Valid legacy migration followed by ordinary collection.
  $legacyRoot = Join-Path $temp 'legacy'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $legacyRoot 'state')
  Set-Content -LiteralPath (Join-Path $legacyRoot 'state/collector-cursor.txt') -Value '9' -Encoding ascii
  $legacy = Invoke-FixtureCollector -Root $legacyRoot
  Assert-Equal $legacy.Code 0 'legacy migration and collection must succeed'
  $legacyCursor = Read-Json (Join-Path $legacyRoot 'state/collector-cursor.v1.json')
  Assert-Equal $legacyCursor.record_id 11 'legacy migration must advance through fixtures'
  Assert-True ([Guid]::TryParse("$($legacyCursor.collection_epoch)", [ref]([Guid]::Empty))) 'legacy migration must create a valid epoch'
  Assert-Equal @(Get-ChildItem (Join-Path $legacyRoot 'state') -Filter 'collector-cursor.txt.migrated.*').Count 1 'legacy cursor must be retained as migrated evidence'
  $legacyEvents = @(Get-Content -LiteralPath (Join-Path $legacyRoot 'spool/windows-events.v1.jsonl') -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json })
  Assert-Equal $legacyEvents.Count 2 'legacy run must emit two canonical events'
  Assert-Equal @($legacyEvents.event_id | Sort-Object -Unique).Count 2 'ordinary canonical IDs must be unique'
  Assert-Equal @(Get-Content -LiteralPath (Join-Path $legacyRoot 'spool/windows-events.log') -Encoding utf8).Count 2 'compatibility spool must mirror committed canonical events'

  $ordinaryReplay = Invoke-FixtureCollector -Root $legacyRoot
  Assert-Equal $ordinaryReplay.Code 0 'ordinary no-op replay must succeed'
  Assert-Equal @(Get-Content -LiteralPath (Join-Path $legacyRoot 'spool/windows-events.v1.jsonl') -Encoding utf8).Count 2 'advanced cursor must prevent duplicate collection'

  # Simulate a cursor-write failure after event append by replacing the state
  # directory with a file only during the event query. Restore the original
  # durable cursor afterward, then prove replay uses the same event identity.
  $replayRoot = Join-Path $temp 'cursor-failure'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $replayRoot 'state')
  Set-Content -LiteralPath (Join-Path $replayRoot 'state/collector-cursor.txt') -Value '9' -Encoding ascii
  $failed = Invoke-FixtureCollector -Root $replayRoot -BreakStateOnQuery
  Assert-Equal $failed.Code 1 'cursor-write failure must fail the collector'
  $preservedCursor = Read-Json (Join-Path $replayRoot 'state/collector-cursor.v1.json')
  Assert-Equal $preservedCursor.record_id 9 'failed cursor publication must preserve prior high-water'
  $firstAttempt = @(Get-Content -LiteralPath (Join-Path $replayRoot 'spool/windows-events.v1.jsonl') -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json })
  Assert-Equal $firstAttempt.Count 1 'failure fixture must append exactly one event before cursor failure'
  $replayedId = $firstAttempt[0].event_id

  $replay = Invoke-FixtureCollector -Root $replayRoot
  Assert-Equal $replay.Code 0 'replay after cursor failure must succeed'
  $replayEvents = @(Get-Content -LiteralPath (Join-Path $replayRoot 'spool/windows-events.v1.jsonl') -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json })
  Assert-Equal $replayEvents.Count 3 'at-least-once replay must retain duplicate evidence plus the next event'
  Assert-Equal @($replayEvents | Where-Object event_id -eq $replayedId).Count 2 'replayed event must keep a stable epoch-bound ID for downstream deduplication'
  Assert-Equal (Read-Json (Join-Path $replayRoot 'state/collector-cursor.v1.json')).record_id 11 'successful replay must advance the cursor'

  # Channel reset/high-water regression refuses by default and creates a fresh
  # epoch only with the explicit reviewed reset switch, without backfill.
  $resetCursorPath = Join-Path $legacyRoot 'state/collector-cursor.v1.json'
  $beforeReset = Read-Json $resetCursorPath
  $oldEpoch = "$($beforeReset.collection_epoch)"
  $beforeReset.record_id = 100
  ($beforeReset | ConvertTo-Json -Compress) + "`n" | Set-Content -LiteralPath $resetCursorPath -Encoding utf8
  $spoolBeforeReset = @(Get-Content -LiteralPath (Join-Path $legacyRoot 'spool/windows-events.v1.jsonl') -Encoding utf8).Count

  $refusedReset = Invoke-FixtureCollector -Root $legacyRoot
  Assert-Equal $refusedReset.Code 1 'high-water regression must refuse without explicit reset'
  $stillOld = Read-Json $resetCursorPath
  Assert-Equal $stillOld.record_id 100 'refused reset must preserve the saved cursor'
  Assert-Equal $stillOld.collection_epoch $oldEpoch 'refused reset must preserve the epoch'

  $acceptedReset = Invoke-FixtureCollector -Root $legacyRoot -AcceptLogReset
  Assert-Equal $acceptedReset.Code 0 'explicit reset must succeed'
  $newCursor = Read-Json $resetCursorPath
  Assert-Equal $newCursor.record_id 11 'explicit reset must start at current high-water'
  Assert-True ($newCursor.collection_epoch -ne $oldEpoch) 'explicit reset must create a new collection epoch'
  Assert-Equal @(Get-Content -LiteralPath (Join-Path $legacyRoot 'spool/windows-events.v1.jsonl') -Encoding utf8).Count $spoolBeforeReset 'explicit reset must not backfill history'

  Write-Output 'collector fixture tests: PASS'
} finally {
  Remove-Item Env:PLEIADES_FIXTURE_BREAK_STATE_ON_QUERY -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
