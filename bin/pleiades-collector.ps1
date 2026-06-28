# pleiades-collector.ps1 — Windows-side AD/Security sensor for the Pleiades bridge.
# Emits ONLY high-signal, threat-relevant events (real failed logons, lockouts,
# Kerberos failures, account/group changes) — aggressively filtering the DC's
# internal service-account noise. Tokenized lines -> read-only bridge spool ->
# WSL container ingests -> Maia signs into the Nexus ledger.
#
# Idempotent (RecordId cursor). First run sets a baseline (no historical dump).
[CmdletBinding()]
param([string]$Root = 'C:\pleiades', [int]$MaxScan = 250)

$ErrorActionPreference = 'Stop'
$spoolDir = Join-Path $Root 'spool'; $stateDir = Join-Path $Root 'state'
$null = New-Item -ItemType Directory -Force -Path $spoolDir, $stateDir
$spool   = Join-Path $spoolDir 'windows-events.log'
$curFile = Join-Path $stateDir 'collector-cursor.txt'

$kind = @{
  4625='failed_logon';   4740='account_lockout'; 4771='kerberos_preauth_fail'
  4720='account_created';4722='account_enabled';  4723='password_change'
  4724='password_reset'; 4725='account_disabled'; 4726='account_deleted'
  4738='account_changed';4728='member_added_global_grp'
  4732='member_added_local_grp'; 4756='member_added_univ_grp'
}

# First run: baseline the cursor to "now" — do not backfill history.
if (-not (Test-Path $curFile)) {
  try { $latest = (Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop).RecordId } catch { $latest = 0 }
  Set-Content -Path $curFile -Value $latest -Encoding Ascii
  "baseline set; cursor=$latest (no historical backfill)"; return
}
[int64]$cursor = 0; [int64]::TryParse((Get-Content $curFile -Raw).Trim(), [ref]$cursor) | Out-Null

# Internal/service accounts that are noise, not threats — skipped.
$skipAcct = '\$$|^(ANONYMOUS_LOGON|CLIUSR|UMFD-\d+|DWM-\d+|himds|SYSTEM|LOCAL[_ ]SERVICE|NETWORK[_ ]SERVICE|AADConnectProvisioningAgent|DefaultAccount|-)$|^MSSQL'

function San([object]$v) {
  if ($null -eq $v -or "$v" -eq '') { return 'none' }
  $s = ("$v" -replace '[^\x20-\x7E]', '' -replace '\s', '_')
  if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
  if ($s -eq '') { 'none' } else { $s }
}

try {
  $evts = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=@($kind.Keys) } -MaxEvents $MaxScan -ErrorAction Stop |
            Where-Object { $_.RecordId -gt $cursor } | Sort-Object RecordId
} catch { if ($_.Exception.Message -match 'No events') { $evts = @() } else { throw } }

$max = $cursor; $n = 0
foreach ($e in $evts) {
  if ($e.RecordId -gt $max) { $max = $e.RecordId }
  $d = @{}
  try { foreach ($p in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$p.Name] = $p.'#text' } } catch {}
  $acctRaw = if ($d['TargetUserName']) { $d['TargetUserName'] } else { $d['SubjectUserName'] }
  if ("$acctRaw" -match $skipAcct) { continue }                       # service/machine noise
  if ([int]$e.Id -eq 4625 -and ($d['LogonType'] -in '4','5')) { continue }  # batch/service failures
  $line = "ts=$([int64]([DateTimeOffset]$e.TimeCreated.ToUniversalTime()).ToUnixTimeSeconds()) id=$($e.Id) kind=$($kind[[int]$e.Id]) account=$(San $acctRaw) ip=$(San $d['IpAddress']) ltype=$(San $d['LogonType']) status=$(San $d['Status'])"
  Add-Content -Path $spool -Value $line -Encoding Ascii
  $n++
}
Set-Content -Path $curFile -Value $max -Encoding Ascii
"collected $n new high-signal event(s); scanned to RecordId=$max"
