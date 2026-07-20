# Adversarial contract tests for the Windows status snapshot consumer.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$supervisor = Join-Path $repoRoot 'bin\pleiades-supervisor.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("pleiades-status-test-" + [Guid]::NewGuid().ToString('N'))

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Compact-Json($Value) {
  return $Value | ConvertTo-Json -Depth 20 -Compress
}

function Expect-Valid($Value, [string]$ExpectedState = '') {
  $arguments = @{
    Root = $testRoot
    ValidateSnapshotJson = (Compact-Json $Value)
  }
  if ($ExpectedState) { $arguments.ExpectedSnapshotContainerState = $ExpectedState }
  $output = & $supervisor @arguments
  Assert ($LASTEXITCODE -eq 0) "valid snapshot returned $LASTEXITCODE"
  Assert (($output -join "`n") -like '*valid, exact, and bounded*') 'valid snapshot confirmation missing'
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

function Running-Snapshot {
  return [ordered]@{
    schema = 'pleiades.status/v1'
    container = 'running'
    timestamp = 1700000000
    ledger = [ordered]@{ state = 'VALID'; records = 2 }
    agents = @(
      [ordered]@{
        agent = 'understory/supervisor'
        status = 'healthy'
        generation = 4
        detail = [ordered]@{ queue_depth = 0; ready = $true }
      }
    )
    events = @(
      [ordered]@{
        seq = 1
        timestamp = 1699999999
        digest = ('a' * 64)
        event = 'first event'
      },
      [ordered]@{
        seq = 2
        timestamp = 1700000000
        digest = ('b' * 64)
        event = 'second event'
      }
    )
  }
}

try {
  Expect-Valid (Running-Snapshot) 'running'
  Expect-Valid ([ordered]@{
    schema = 'pleiades.status/v1'
    container = 'down'
    timestamp = 1700000000
    ledger = [ordered]@{ state = 'UNKNOWN'; records = 0 }
    agents = @()
    events = @()
  }) 'down'

  $value = Running-Snapshot
  $value.extra = 'ambient'
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'snapshot must contain exactly'

  $value = Running-Snapshot
  $value.ledger.extra = 1
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'snapshot.ledger must contain exactly'

  $value = Running-Snapshot
  $value.events[0].extra = 'ambient'
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'snapshot.events[] must contain exactly'

  $value = Running-Snapshot
  $value.events[0].digest = 'not-a-digest'
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'lowercase SHA-256'

  $value = Running-Snapshot
  $value.events[1].seq = 1
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'strictly increasing unique'

  $value = Running-Snapshot
  $value.agents[0].detail.message = 'x' * 4097
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'oversized or unsupported string'

  $value = Running-Snapshot
  $value.agents[0].score = 0.5
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null
  } 'floating-point identity'

  $downWithEvidence = [ordered]@{
    schema = 'pleiades.status/v1'
    container = 'down'
    timestamp = 1700000000
    ledger = [ordered]@{ state = 'UNKNOWN'; records = 0 }
    agents = @([ordered]@{ agent = 'ghost'; status = 'healthy' })
    events = @()
  }
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $downWithEvidence) | Out-Null
  } 'down snapshot must contain'

  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json (Running-Snapshot)) -ExpectedSnapshotContainerState degraded | Out-Null
  } 'disagrees with independently observed state'

  $duplicate = '{"schema":"pleiades.status/v1","schema":"pleiades.status/v1","container":"running","timestamp":1700000000,"ledger":{"state":"VALID","records":0},"agents":[],"events":[]}'
  Expect-Failure {
    & $supervisor -Root $testRoot -ValidateSnapshotJson $duplicate | Out-Null
  } 'duplicate property'

  Expect-Failure {
    & $supervisor -Root $testRoot -ExpectedSnapshotContainerState running -ValidateConfigurationOnly | Out-Null
  } 'valid only with ValidateSnapshotJson'

  Assert (-not (Test-Path -LiteralPath $testRoot)) 'validation-only paths created runtime directories'
  Write-Output 'PASS: exact status object, duplicate-key, event, agent, down-state, and independent-state contracts'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
