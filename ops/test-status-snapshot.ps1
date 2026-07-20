[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Supervisor = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/pleiades-supervisor.ps1'
$PowerShell = (Get-Command pwsh -ErrorAction Stop).Source
$Temporary = Join-Path ([IO.Path]::GetTempPath()) ("pleiades-status-test-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Temporary

function Write-Fixture([string]$Name, [string]$Content) {
  $path = Join-Path $Temporary $Name
  [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
  return $path
}

function Invoke-Validation([string]$Path) {
  $output = & $PowerShell -NoProfile -File $Supervisor -ValidateSnapshotPath $Path 2>&1
  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = @($output | ForEach-Object { "$_" })
  }
}

function Assert-Accepted([string]$Name, [string]$Content) {
  $result = Invoke-Validation (Write-Fixture "$Name.json" $Content)
  if ($result.ExitCode -ne 0) {
    throw "$Name was rejected: $($result.Output -join "`n")"
  }
}

function Assert-Rejected([string]$Name, [string]$Content, [string]$Expected) {
  $result = Invoke-Validation (Write-Fixture "$Name.json" $Content)
  if ($result.ExitCode -eq 0) {
    throw "$Name was unexpectedly accepted"
  }
  if (($result.Output -join "`n") -notlike "*$Expected*") {
    throw "$Name did not report '$Expected': $($result.Output -join "`n")"
  }
}

try {
  $valid = '{"schema":"pleiades.status/v1","container":"running","timestamp":1,"ledger":{"state":"VALID","records":2},"agents":[],"events":[]}'
  Assert-Accepted 'valid-object' $valid

  Assert-Rejected 'two-objects-array' "[$valid,$valid]" 'exactly one JSON object'
  Assert-Rejected 'one-object-array' "[$valid]" 'exactly one JSON object'
  Assert-Rejected 'null' 'null' 'exactly one JSON object'
  Assert-Rejected 'scalar' '42' 'exactly one JSON object'
  Assert-Rejected 'missing-schema' '{"container":"running","timestamp":1,"ledger":{"state":"VALID","records":0},"agents":[],"events":[]}' 'missing required field: schema'
  Assert-Rejected 'collection-schema' '{"schema":["pleiades.status/v1"],"container":"running","timestamp":1,"ledger":{"state":"VALID","records":0},"agents":[],"events":[]}' 'schema must be exactly'
  Assert-Rejected 'collection-container' '{"schema":"pleiades.status/v1","container":["running"],"timestamp":1,"ledger":{"state":"VALID","records":0},"agents":[],"events":[]}' 'container state must be'
  Assert-Rejected 'collection-ledger' '{"schema":"pleiades.status/v1","container":"running","timestamp":1,"ledger":[{"state":"VALID","records":0}],"agents":[],"events":[]}' 'ledger must be exactly one object'
  Assert-Rejected 'negative-records' '{"schema":"pleiades.status/v1","container":"running","timestamp":1,"ledger":{"state":"VALID","records":-1},"agents":[],"events":[]}' 'records must be a non-negative integer'
  Assert-Rejected 'string-timestamp' '{"schema":"pleiades.status/v1","container":"running","timestamp":"1","ledger":{"state":"VALID","records":0},"agents":[],"events":[]}' 'timestamp must be a non-negative integer'
  Assert-Rejected 'scalar-agents' '{"schema":"pleiades.status/v1","container":"running","timestamp":1,"ledger":{"state":"VALID","records":0},"agents":{},"events":[]}' 'agents must be an array'
  Assert-Rejected 'scalar-events' '{"schema":"pleiades.status/v1","container":"running","timestamp":1,"ledger":{"state":"VALID","records":0},"agents":[],"events":{}}' 'events must be an array'

  $sentinel = Write-Fixture 'prior-status.json' 'previous-valid-status'
  $before = [IO.File]::ReadAllBytes($sentinel)
  $invalid = Write-Fixture 'invalid-does-not-publish.json' "[$valid]"
  $null = Invoke-Validation $invalid
  $after = [IO.File]::ReadAllBytes($sentinel)
  if ([Convert]::ToBase64String($before) -cne [Convert]::ToBase64String($after)) {
    throw 'rejected validation altered the prior status sentinel'
  }

  Write-Output 'PASS: status snapshot validator'
  exit 0
} finally {
  Remove-Item -LiteralPath $Temporary -Recurse -Force -ErrorAction SilentlyContinue
}
