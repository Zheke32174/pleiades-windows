# Adversarial contract tests for the Windows status snapshot consumer.
[CmdletBinding()]
param(
  [ValidateSet(
    'all','valid-running','valid-down','valid-fresh','extra-top','extra-ledger',
    'extra-event','bad-digest','duplicate-sequence','oversized-agent','floating-agent',
    'down-with-evidence','state-mismatch','duplicate-key','stale-snapshot',
    'future-snapshot','future-event','invalid-validation-mode','invalid-reference-mode'
  )]
  [string]$Case = 'all'
)

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

function Expect-Valid(
  $Value,
  [string]$ExpectedState = '',
  [long]$ReferenceUnixTime = 0
) {
  $arguments = @{
    Root = $testRoot
    ValidateSnapshotJson = (Compact-Json $Value)
  }
  if ($ExpectedState) { $arguments.ExpectedSnapshotContainerState = $ExpectedState }
  if ($ReferenceUnixTime -gt 0) {
    $arguments.ValidateSnapshotReferenceUnixTime = $ReferenceUnixTime
  }
  $output = & $supervisor @arguments
  Assert ($LASTEXITCODE -eq 0) "valid snapshot returned $LASTEXITCODE"
  Assert (($output -join "`n") -like '*valid, exact, bounded, and temporally coherent*') 'valid snapshot confirmation missing'
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
      [ordered]@{ seq = 1; timestamp = 1699999999; digest = ('a' * 64); event = 'first event' },
      [ordered]@{ seq = 2; timestamp = 1700000000; digest = ('b' * 64); event = 'second event' }
    )
  }
}

function Invoke-Case([string]$Name) {
  Write-Output "CASE: $Name"
  switch ($Name) {
    'valid-running' { Expect-Valid (Running-Snapshot) 'running' }
    'valid-down' {
      Expect-Valid ([ordered]@{
        schema = 'pleiades.status/v1'; container = 'down'; timestamp = 1700000000
        ledger = [ordered]@{ state = 'UNKNOWN'; records = 0 }; agents = @(); events = @()
      }) 'down'
    }
    'valid-fresh' {
      Expect-Valid (Running-Snapshot) 'running' 1700000100
    }
    'extra-top' {
      $value = Running-Snapshot; $value.extra = 'ambient'
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'snapshot must contain exactly'
    }
    'extra-ledger' {
      $value = Running-Snapshot; $value.ledger.extra = 1
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'snapshot.ledger must contain exactly'
    }
    'extra-event' {
      $raw = '{"schema":"pleiades.status/v1","container":"running","timestamp":1700000000,"ledger":{"state":"VALID","records":0},"agents":[],"events":[{"seq":1,"timestamp":1700000000,"digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","event":"first event","extra":"ambient"}]}'
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson $raw | Out-Null } 'snapshot.events[] must contain exactly'
    }
    'bad-digest' {
      $value = Running-Snapshot; $value.events[0].digest = 'not-a-digest'
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'lowercase SHA-256'
    }
    'duplicate-sequence' {
      $value = Running-Snapshot; $value.events[1].seq = 1
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'strictly increasing unique'
    }
    'oversized-agent' {
      $value = Running-Snapshot; $value.agents[0].detail.message = 'x' * 4097
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'oversized or unsupported string'
    }
    'floating-agent' {
      $value = Running-Snapshot; $value.agents[0].score = 0.5
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'floating-point identity'
    }
    'down-with-evidence' {
      $value = [ordered]@{
        schema = 'pleiades.status/v1'; container = 'down'; timestamp = 1700000000
        ledger = [ordered]@{ state = 'UNKNOWN'; records = 0 }
        agents = @([ordered]@{ agent = 'ghost'; status = 'healthy' }); events = @()
      }
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'down snapshot must contain'
    }
    'state-mismatch' {
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json (Running-Snapshot)) -ExpectedSnapshotContainerState degraded | Out-Null } 'disagrees with independently observed state'
    }
    'duplicate-key' {
      $duplicate = '{"schema":"pleiades.status/v1","schema":"pleiades.status/v1","container":"running","timestamp":1700000000,"ledger":{"state":"VALID","records":0},"agents":[],"events":[]}'
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson $duplicate | Out-Null } 'duplicate property'
    }
    'stale-snapshot' {
      Expect-Failure {
        & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json (Running-Snapshot)) -ValidateSnapshotReferenceUnixTime 1700000301 | Out-Null
      } 'stale relative'
    }
    'future-snapshot' {
      Expect-Failure {
        & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json (Running-Snapshot)) -ValidateSnapshotReferenceUnixTime 1699999939 | Out-Null
      } 'unreasonably in the future'
    }
    'future-event' {
      $value = Running-Snapshot
      $value.events[1].timestamp = 1700000001
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotJson (Compact-Json $value) | Out-Null } 'must not be later'
    }
    'invalid-validation-mode' {
      Expect-Failure { & $supervisor -Root $testRoot -ExpectedSnapshotContainerState running -ValidateConfigurationOnly | Out-Null } 'valid only with ValidateSnapshotJson'
    }
    'invalid-reference-mode' {
      Expect-Failure { & $supervisor -Root $testRoot -ValidateSnapshotReferenceUnixTime 1700000000 -ValidateConfigurationOnly | Out-Null } 'valid only with ValidateSnapshotJson'
    }
    default { throw "unknown test case: $Name" }
  }
  Assert (-not (Test-Path -LiteralPath $testRoot)) "$Name created runtime directories"
  Write-Output "PASS: $Name"
}

$cases = @(
  'valid-running','valid-down','valid-fresh','extra-top','extra-ledger','extra-event',
  'bad-digest','duplicate-sequence','oversized-agent','floating-agent',
  'down-with-evidence','state-mismatch','duplicate-key','stale-snapshot',
  'future-snapshot','future-event','invalid-validation-mode','invalid-reference-mode'
)

try {
  if ($Case -eq 'all') { foreach ($name in $cases) { Invoke-Case $name } }
  else { Invoke-Case $Case }
  Write-Output 'PASS: exact status snapshot contract'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
