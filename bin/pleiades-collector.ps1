# pleiades-collector.ps1 — Windows Security/AD event collector.
#
# Emits a canonical JSONL outbox plus the current legacy line spool used by the
# lean bridge. Cursor advancement occurs only after both writes succeed, giving
# at-least-once delivery rather than silent loss.

[CmdletBinding()]
param(
  [string]$Root = 'C:\pleiades',
  [ValidateRange(1, 5000)][int]$MaxEvents = 500,
  [switch]$IncludeServiceNoise,
  [switch]$AcceptLogReset
)

$ErrorActionPreference = 'Stop'
$spoolDir = Join-Path $Root 'spool'
$stateDir = Join-Path $Root 'state'
$null = New-Item -ItemType Directory -Force -Path $spoolDir, $stateDir
$legacySpool = Join-Path $spoolDir 'windows-events.log'
$jsonSpool = Join-Path $spoolDir 'windows-events.v1.jsonl'
$cursorFile = Join-Path $stateDir 'collector-cursor.v1.json'
$legacyCursorFile = Join-Path $stateDir 'collector-cursor.txt'
$cursorSchema = 'pleiades.windows-security-cursor/v1'
$currentHost = [Environment]::MachineName

$mutex = [Threading.Mutex]::new($false, 'Global\PleiadesSecurityCollector')
if (-not $mutex.WaitOne(0)) {
  $mutex.Dispose()
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

function Write-AtomicUtf8([string]$Path, [string]$Text) {
  $directory = Split-Path -Parent $Path
  $name = Split-Path -Leaf $Path
  $temporary = Join-Path $directory ".$name.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
  $encoding = [Text.UTF8Encoding]::new($false)
  $bytes = $encoding.GetBytes($Text)
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

function New-CursorState([int64]$RecordId) {
  return [pscustomobject][ordered]@{
    schema = $cursorSchema
    log = 'Security'
    host = $currentHost
    collection_epoch = [Guid]::NewGuid().ToString('D')
    record_id = $RecordId
    updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
}

function Save-CursorState([object]$Cursor, [int64]$RecordId) {
  $value = [ordered]@{
    schema = $cursorSchema
    log = 'Security'
    host = "$($Cursor.host)"
    collection_epoch = "$($Cursor.collection_epoch)"
    record_id = $RecordId
    updated_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  }
  Write-AtomicUtf8 -Path $cursorFile -Text (($value | ConvertTo-Json -Compress) + "`n")
  return [pscustomobject]$value
}

function Read-CursorState {
  if (-not (Test-Path -LiteralPath $cursorFile)) { return $null }
  try {
    $value = Get-Content -LiteralPath $cursorFile -Raw -Encoding utf8 | ConvertFrom-Json
  } catch {
    throw "collector cursor is unreadable: $($_.Exception.Message)"
  }

  $expectedFields = @('collection_epoch', 'host', 'log', 'record_id', 'schema', 'updated_at')
  $actualFields = @($value.PSObject.Properties.Name | Sort-Object)
  if (@(Compare-Object $expectedFields $actualFields).Count -ne 0) {
    throw 'collector cursor has unknown or missing fields'
  }
  if ($value.schema -ne $cursorSchema -or $value.log -ne 'Security') {
    throw "collector cursor schema/log mismatch"
  }
  $epoch = [Guid]::Empty
  if (-not [Guid]::TryParse("$($value.collection_epoch)", [ref]$epoch)) {
    throw 'collector cursor collection_epoch is invalid'
  }
  [int64]$recordId = 0
  if (-not [int64]::TryParse("$($value.record_id)", [ref]$recordId) -or $recordId -lt 0) {
    throw 'collector cursor record_id is invalid'
  }
  [int64]$updatedAt = 0
  if (-not [int64]::TryParse("$($value.updated_at)", [ref]$updatedAt) -or $updatedAt -lt 0) {
    throw 'collector cursor updated_at is invalid'
  }
  if ([string]::IsNullOrWhiteSpace("$($value.host)")) {
    throw 'collector cursor host is invalid'
  }
  return [pscustomobject][ordered]@{
    schema = $cursorSchema
    log = 'Security'
    host = "$($value.host)"
    collection_epoch = $epoch.ToString('D')
    record_id = $recordId
    updated_at = $updatedAt
  }
}

function Get-SecurityHighWater {
  try {
    $latest = Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop
    return [int64]$latest.RecordId
  } catch {
    if ($_.Exception.Message -match 'No events were found') { return [int64]0 }
    throw "cannot read Security log high-water mark: $($_.Exception.Message)"
  }
}

function Initialize-CursorState {
  $cursor = Read-CursorState
  if ($null -ne $cursor) { return $cursor }

  if (Test-Path -LiteralPath $legacyCursorFile) {
    [int64]$legacyRecordId = 0
    $legacyRaw = (Get-Content -LiteralPath $legacyCursorFile -Raw -Encoding ascii).Trim()
    if (-not [int64]::TryParse($legacyRaw, [ref]$legacyRecordId) -or $legacyRecordId -lt 0) {
      throw 'legacy collector cursor is corrupt; refusing implicit replay'
    }
    $cursor = New-CursorState -RecordId $legacyRecordId
    $cursor = Save-CursorState -Cursor $cursor -RecordId $legacyRecordId
    $migrated = "$legacyCursorFile.migrated.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Move-Item -LiteralPath $legacyCursorFile -Destination $migrated -Force
    Write-Output "legacy cursor migrated; cursor=$legacyRecordId epoch=$($cursor.collection_epoch)"
    return $cursor
  }

  $latest = Get-SecurityHighWater
  $cursor = New-CursorState -RecordId $latest
  $cursor = Save-CursorState -Cursor $cursor -RecordId $latest
  Write-Output "baseline set; cursor=$latest epoch=$($cursor.collection_epoch); no historical backfill"
  return $cursor
}

try {
  $cursorState = Initialize-CursorState
  [int64]$cursor = $cursorState.record_id
  $latestRecordId = Get-SecurityHighWater
  $epochInvalid = ($cursorState.host -ne $currentHost) -or ($latestRecordId -lt $cursor)
  if ($epochInvalid) {
    if (-not $AcceptLogReset) {
      throw (
        "Security log identity/high-water no longer matches the saved cursor " +
        "(saved_host=$($cursorState.host) current_host=$currentHost " +
        "cursor=$cursor latest=$latestRecordId). Re-run with -AcceptLogReset " +
        "only after reviewing the log reset or host replacement."
      )
    }
    $cursorState = New-CursorState -RecordId $latestRecordId
    $cursorState = Save-CursorState -Cursor $cursorState -RecordId $latestRecordId
    Write-Output (
      "collection epoch reset; cursor=$latestRecordId " +
      "epoch=$($cursorState.collection_epoch); no historical backfill"
    )
    exit 0
  }

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
      event_id = "windows-security/$($event.MachineName)/$($cursorState.collection_epoch)/$($event.RecordId)"
      event_type = $kind
      source = [ordered]@{
        collector = 'pleiades-windows-security'
        log = 'Security'
        collection_epoch = $cursorState.collection_epoch
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
    $legacy = "ts=$eventTime rid=$($event.RecordId) epoch=$($cursorState.collection_epoch) id=$($event.Id) kind=$($kind -replace '\.', '_') host=$(ConvertTo-SafeString $event.MachineName 128) account=$(ConvertTo-SafeString $account 128) ip=$(ConvertTo-SafeString $data['IpAddress'] 128) ltype=$(ConvertTo-SafeString $data['LogonType'] 32) status=$(ConvertTo-SafeString $data['Status'] 64)"

    Add-Utf8Line -Path $jsonSpool -Line $json
    Add-Utf8Line -Path $legacySpool -Line $legacy
    $maxCommitted = [int64]$event.RecordId
    $cursorState = Save-CursorState -Cursor $cursorState -RecordId $maxCommitted
    $written++
  }

  # Filtered events are intentionally acknowledged only after the whole scan has
  # completed. If the script fails while writing a retained event, its cursor is
  # not advanced and the event will be replayed on the next run.
  if ($events.Count -gt 0 -and $maxCommitted -gt $cursorState.record_id) {
    $cursorState = Save-CursorState -Cursor $cursorState -RecordId $maxCommitted
  }

  $remaining = if ($events.Count -eq $MaxEvents) { 'possible' } else { 'none' }
  Write-Output (
    "collected=$written filtered=$filtered cursor=$($cursorState.record_id) " +
    "epoch=$($cursorState.collection_epoch) backlog=$remaining"
  )
  exit 0
} catch {
  Write-Error $_
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
