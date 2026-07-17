# pleiades-collector.ps1 — Windows Security/AD event collector.
#
# Emits a canonical JSONL outbox plus the current legacy line spool used by the
# lean bridge. Cursor advancement occurs only after both writes succeed, giving
# at-least-once delivery rather than silent loss.

[CmdletBinding()]
param(
  [string]$Root = 'C:\pleiades',
  [ValidateRange(1, 5000)][int]$MaxEvents = 500,
  [switch]$IncludeServiceNoise
)

$ErrorActionPreference = 'Stop'
$spoolDir = Join-Path $Root 'spool'
$stateDir = Join-Path $Root 'state'
$null = New-Item -ItemType Directory -Force -Path $spoolDir, $stateDir
$legacySpool = Join-Path $spoolDir 'windows-events.log'
$jsonSpool = Join-Path $spoolDir 'windows-events.v1.jsonl'
$cursorFile = Join-Path $stateDir 'collector-cursor.txt'

$mutex = [Threading.Mutex]::new($false, 'Global\PleiadesSecurityCollector')
if (-not $mutex.WaitOne(0)) {
  Write-Output 'collector already running; exiting'
  exit 0
}

$eventKinds = @{
  4625 = 'authentication.failure'
  4740 = 'account.lockout'
  4771 = 'kerberos.preauth_failure'
  4720 = 'account.created'
  4722 = 'account.enabled'
  4723 = 'account.password_change_attempt'
  4724 = 'account.password_reset'
  4725 = 'account.disabled'
  4726 = 'account.deleted'
  4738 = 'account.changed'
  4728 = 'group.member_added.global'
  4732 = 'group.member_added.local'
  4756 = 'group.member_added.universal'
}

function ConvertTo-SafeString([object]$Value, [int]$Limit = 256) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) { return $null }
  $valueText = ("$Value" -replace '[\x00-\x1F\x7F]', '')
  if ($valueText.Length -gt $Limit) { $valueText = $valueText.Substring(0, $Limit) }
  return $valueText
}

function Add-Utf8Line([string]$Path, [string]$Line) {
  $encoding = [Text.UTF8Encoding]::new($false)
  $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $writer = [IO.StreamWriter]::new($stream, $encoding)
    try {
      $writer.WriteLine($Line)
      $writer.Flush()
      $stream.Flush($true)
    } finally {
      $writer.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

try {
  if (-not (Test-Path $cursorFile)) {
    try {
      $latest = (Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop).RecordId
    } catch {
      $latest = 0
    }
    Set-Content -Path $cursorFile -Value ([int64]$latest) -Encoding ascii
    Write-Output "baseline set; cursor=$latest; no historical backfill"
    exit 0
  }

  [int64]$cursor = 0
  [void][int64]::TryParse((Get-Content $cursorFile -Raw).Trim(), [ref]$cursor)

  $eventExpression = (@($eventKinds.Keys | Sort-Object) | ForEach-Object { "EventID=$_" }) -join ' or '
  $xpath = "*[System[(($eventExpression)) and EventRecordID > $cursor]]"
  try {
    $events = @(Get-WinEvent -LogName Security -FilterXPath $xpath -Oldest -MaxEvents $MaxEvents -ErrorAction Stop)
  } catch {
    if ($_.Exception.Message -match 'No events were found') { $events = @() } else { throw }
  }

  $serviceAccountPattern = '\$$|^(ANONYMOUS LOGON|CLIUSR|UMFD-\d+|DWM-\d+|himds|SYSTEM|LOCAL SERVICE|NETWORK SERVICE|AADConnectProvisioningAgent|DefaultAccount|-)$|^MSSQL'
  $written = 0
  $filtered = 0
  $maxCommitted = $cursor

  foreach ($event in $events) {
    $data = @{}
    try {
      foreach ($node in ([xml]$event.ToXml()).Event.EventData.Data) {
        $data[$node.Name] = $node.'#text'
      }
    } catch {
      throw "failed to parse Security event RecordId=$($event.RecordId): $($_.Exception.Message)"
    }

    $account = if ($data['TargetUserName']) { $data['TargetUserName'] } else { $data['SubjectUserName'] }
    $isServiceNoise = ("$account" -match $serviceAccountPattern) -or
      ([int]$event.Id -eq 4625 -and "$($data['LogonType'])" -in '4', '5')

    if ($isServiceNoise -and -not $IncludeServiceNoise) {
      $filtered++
      $maxCommitted = [int64]$event.RecordId
      continue
    }

    $eventTime = ([DateTimeOffset]$event.TimeCreated.ToUniversalTime()).ToUnixTimeSeconds()
    $kind = $eventKinds[[int]$event.Id]
    $severity = if ($event.Id -in 4720, 4724, 4726, 4728, 4732, 4756) { 'high' }
      elseif ($event.Id -in 4740, 4771) { 'medium' }
      else { 'low' }

    $record = [ordered]@{
      schema = 'pleiades.event/v1'
      event_id = "windows-security/$($event.MachineName)/$($event.RecordId)"
      event_type = $kind
      source = [ordered]@{
        collector = 'pleiades-windows-security'
        log = 'Security'
        record_id = [int64]$event.RecordId
        host = $event.MachineName
        trust_class = 'host-collected'
      }
      observed_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      event_time = [int64]$eventTime
      severity = $severity
      subject = [ordered]@{
        account = ConvertTo-SafeString $account 128
        domain = ConvertTo-SafeString $data['TargetDomainName'] 128
      }
      network = [ordered]@{
        ip = ConvertTo-SafeString $data['IpAddress'] 128
        workstation = ConvertTo-SafeString $data['WorkstationName'] 128
      }
      details = [ordered]@{
        windows_event_id = [int]$event.Id
        logon_type = ConvertTo-SafeString $data['LogonType'] 32
        status = ConvertTo-SafeString $data['Status'] 64
        sub_status = ConvertTo-SafeString $data['SubStatus'] 64
        service_noise = [bool]$isServiceNoise
      }
    }

    $json = $record | ConvertTo-Json -Depth 8 -Compress
    $legacy = "ts=$eventTime rid=$($event.RecordId) id=$($event.Id) kind=$($kind -replace '\.', '_') host=$(ConvertTo-SafeString $event.MachineName 128) account=$(ConvertTo-SafeString $account 128) ip=$(ConvertTo-SafeString $data['IpAddress'] 128) ltype=$(ConvertTo-SafeString $data['LogonType'] 32) status=$(ConvertTo-SafeString $data['Status'] 64)"

    Add-Utf8Line -Path $jsonSpool -Line $json
    Add-Utf8Line -Path $legacySpool -Line $legacy
    $maxCommitted = [int64]$event.RecordId
    Set-Content -Path $cursorFile -Value $maxCommitted -Encoding ascii
    $written++
  }

  # Filtered events are intentionally acknowledged only after the whole scan has
  # completed. If the script fails while writing a retained event, its cursor is
  # not advanced and the event will be replayed on the next run.
  if ($events.Count -gt 0 -and $maxCommitted -gt $cursor) {
    Set-Content -Path $cursorFile -Value $maxCommitted -Encoding ascii
  }

  $remaining = if ($events.Count -eq $MaxEvents) { 'possible' } else { 'none' }
  Write-Output "collected=$written filtered=$filtered cursor=$maxCommitted backlog=$remaining"
  exit 0
} catch {
  Write-Error $_
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
