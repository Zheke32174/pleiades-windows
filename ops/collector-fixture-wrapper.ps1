[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Collector,
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][string]$Fixture,
  [switch]$AcceptLogReset,
  [switch]$BreakStateOnQuery
)

$ErrorActionPreference = 'Stop'
$script:FixtureRoot = $Root
$script:FixtureEvents = @(Get-Content -LiteralPath $Fixture -Raw -Encoding utf8 | ConvertFrom-Json)
$script:StateBroken = $false

function New-FixtureEvent([object]$Item) {
  [int64]$recordId = $Item.record_id
  $event = [pscustomobject]@{
    RecordId = $recordId
    Id = [int]$Item.event_id
    MachineName = "$($Item.machine)"
    TimeCreated = [datetime]::UnixEpoch.AddSeconds(1750000000 + $recordId)
    Data = $Item.data
  }
  $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
    $nodes = foreach ($property in $this.Data.PSObject.Properties) {
      $name = [Security.SecurityElement]::Escape("$($property.Name)")
      $value = [Security.SecurityElement]::Escape("$($property.Value)")
      '<Data Name="{0}">{1}</Data>' -f $name, $value
    }
    '<Event><EventData>{0}</EventData></Event>' -f ($nodes -join '')
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

  if ($BreakStateOnQuery -and -not $script:StateBroken) {
    $state = Join-Path $script:FixtureRoot 'state'
    Move-Item -LiteralPath $state -Destination "$state.hold"
    Set-Content -LiteralPath $state -Value 'fixture-blocks-cursor-directory' -Encoding ascii
    $script:StateBroken = $true
  }

  $selected = @($events | Where-Object { $_.RecordId -gt $cursor } | Select-Object -First $MaxEvents)
  if ($selected.Count -eq 0) { throw 'No events were found' }
  return $selected
}

$collectorArguments = @{ Root = $Root }
if ($AcceptLogReset) { $collectorArguments.AcceptLogReset = $true }
& $Collector @collectorArguments
