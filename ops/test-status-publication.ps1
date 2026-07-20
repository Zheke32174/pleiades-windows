# Disposable Windows fixtures for monotonic, atomic status publication.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$supervisor = Join-Path $repoRoot 'bin\pleiades-supervisor.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("pleiades-status-publication-" + [Guid]::NewGuid().ToString('N'))
$statusPath = Join-Path $testRoot 'portal\status.json'
$env:PLEIADES_WINDOWS_TEST_MODE = '1'

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Snapshot([long]$Timestamp, [string]$Marker) {
  return [ordered]@{
    schema = 'pleiades.status/v1'
    container = 'running'
    timestamp = $Timestamp
    ledger = [ordered]@{ state = 'VALID'; records = 1 }
    agents = @([ordered]@{ agent = 'fixture/status'; status = 'healthy'; marker = $Marker })
    events = @(
      [ordered]@{
        seq = 1
        timestamp = $Timestamp
        digest = ('a' * 64)
        event = "fixture-$Marker"
      }
    )
  }
}

function Json($Value) {
  return $Value | ConvertTo-Json -Depth 20 -Compress
}

function Publish([string]$Raw, [long]$ReferenceUnixTime) {
  $arguments = @{
    Root = $testRoot
    TestSnapshotPublicationPath = $statusPath
    TestSnapshotPublicationJson = $Raw
    TestSnapshotReferenceUnixTime = $ReferenceUnixTime
  }
  $output = & $supervisor @arguments
  Assert ($LASTEXITCODE -eq 0) "publication returned $LASTEXITCODE"
  return ($output -join "`n")
}

function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
  try {
    & $Action
  } catch {
    Assert ($_.Exception.Message -like "*$Pattern*") "failure did not contain '$Pattern': $($_.Exception.Message)"
    return
  }
  throw "ASSERTION FAILED: command unexpectedly succeeded; expected '$Pattern'"
}

function Bytes([string]$Path) {
  return [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

try {
  $generation100 = Json (Snapshot 1700000000 'generation-100')
  $result = Publish $generation100 1700000010
  Assert ($result -like '*fixture: published*') 'initial publication did not report published'
  Assert (Test-Path -LiteralPath $statusPath -PathType Leaf) 'initial status snapshot is absent'
  Assert ((Get-Content -LiteralPath $statusPath -Raw).Trim() -ceq $generation100) 'initial status bytes are wrong'

  $initialBytes = Bytes $statusPath
  $result = Publish $generation100 1700000010
  Assert ($result -like '*fixture: exact-retry*') 'exact retry was not identified'
  Assert ((Bytes $statusPath) -ceq $initialBytes) 'exact retry changed status bytes'

  $generation101 = Json (Snapshot 1700000001 'generation-101')
  $result = Publish $generation101 1700000010
  Assert ($result -like '*fixture: published*') 'replacement publication did not report published'
  Assert ((Get-Content -LiteralPath $statusPath -Raw).Trim() -ceq $generation101) 'replacement status bytes are wrong'
  $generation101Bytes = Bytes $statusPath

  $debris = @(
    Get-ChildItem -LiteralPath (Split-Path -Parent $statusPath) -Force |
      Where-Object { $_.Name -like '.status.json.tmp.*' -or $_.Name -like '.status.json.backup.*' }
  )
  Assert ($debris.Count -eq 0) 'successful replacement left temporary or backup debris'

  Expect-Failure { Publish $generation100 1700000010 | Out-Null } 'timestamp rollback'
  Assert ((Bytes $statusPath) -ceq $generation101Bytes) 'rollback attempt changed the prior snapshot'

  $collision = Json (Snapshot 1700000001 'equal-time-collision')
  Expect-Failure { Publish $collision 1700000010 | Out-Null } 'equal snapshot timestamp carries different content'
  Assert ((Bytes $statusPath) -ceq $generation101Bytes) 'equal-time collision changed the prior snapshot'

  $stale = Json (Snapshot 1699999600 'stale')
  Expect-Failure { Publish $stale 1700000010 | Out-Null } 'stale relative'
  Assert ((Bytes $statusPath) -ceq $generation101Bytes) 'stale snapshot changed the prior snapshot'

  $future = Json (Snapshot 1700000100 'future')
  Expect-Failure { Publish $future 1700000010 | Out-Null } 'unreasonably in the future'
  Assert ((Bytes $statusPath) -ceq $generation101Bytes) 'future snapshot changed the prior snapshot'

  $futureEvent = Snapshot 1700000002 'future-event'
  $futureEvent.events[0].timestamp = 1700000003
  Expect-Failure { Publish (Json $futureEvent) 1700000010 | Out-Null } 'must not be later'
  Assert ((Bytes $statusPath) -ceq $generation101Bytes) 'future-event snapshot changed the prior snapshot'

  $realDirectory = Join-Path $testRoot 'real-reparse-target'
  $junctionDirectory = Join-Path $testRoot 'reparse-parent'
  $null = New-Item -ItemType Directory -Force -Path $realDirectory
  $null = New-Item -ItemType Junction -Path $junctionDirectory -Target $realDirectory
  $junctionStatus = Join-Path $junctionDirectory 'status.json'
  $arguments = @{
    Root = $testRoot
    TestSnapshotPublicationPath = $junctionStatus
    TestSnapshotPublicationJson = (Json (Snapshot 1700000002 'reparse'))
    TestSnapshotReferenceUnixTime = 1700000010
  }
  Expect-Failure { & $supervisor @arguments | Out-Null } 'must not be a reparse point'
  Assert (-not (Test-Path -LiteralPath (Join-Path $realDirectory 'status.json'))) 'reparse refusal wrote through to its target'

  Write-Output 'PASS: monotonic atomic status publication'
} finally {
  Remove-Item Env:PLEIADES_WINDOWS_TEST_MODE -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
