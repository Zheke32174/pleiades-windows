[CmdletBinding()]
param(
  [string]$Collector = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/pleiades-collector.ps1'),
  [string]$Wrapper = (Join-Path $PSScriptRoot 'collector-fixture-wrapper.ps1')
)
$ErrorActionPreference = 'Stop'
function Assert([bool]$Ok,[string]$Message){if(-not $Ok){throw "assertion failed: $Message"}}
function ReadJson([string]$Path){Get-Content $Path -Raw -Encoding utf8|ConvertFrom-Json}
$collector=(Resolve-Path $Collector).Path;$wrapper=(Resolve-Path $Wrapper).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) "pleiades-baseline-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $temp|Out-Null
try{
  $fixture=Join-Path $temp events.json
  @(
    @{record_id=10;event_id=4625;machine=[Environment]::MachineName;time='2026-07-19T12:00:00Z';data=@{TargetUserName='alice';TargetDomainName='P';IpAddress='192.0.2.10';WorkstationName='a';LogonType='3';Status='x';SubStatus='y'}},
    @{record_id=11;event_id=4720;machine=[Environment]::MachineName;time='2026-07-19T12:01:00Z';data=@{TargetUserName='bob';TargetDomainName='P';IpAddress='-';WorkstationName='b';LogonType='-';Status='-';SubStatus='-'}}
  )|ConvertTo-Json -Depth 7|Set-Content $fixture -Encoding utf8
  function Run([string]$Root,[switch]$Reset){
    $a=@('-NoProfile','-File',$wrapper,'-Collector',$collector,'-Root',$Root,'-Fixture',$fixture)
    if($Reset){$a+='-AcceptLogReset'}
    $output=@(& pwsh @a 2>&1);$code=$LASTEXITCODE
    if($code -ne 0){Write-Host ($output -join "`n")}
    $code
  }

  $base=Join-Path $temp baseline
  Assert ((Run $base)-eq 0) 'initial baseline succeeds'
  Assert ((ReadJson (Join-Path $base state/collector-cursor.v1.json)).record_id -eq 11) 'baseline records high-water'
  Assert (!(Test-Path (Join-Path $base spool/windows-events.v1.jsonl))) 'baseline does not backfill'

  $legacy=Join-Path $temp legacy;New-Item -ItemType Directory -Force (Join-Path $legacy state)|Out-Null
  Set-Content (Join-Path $legacy state/collector-cursor.txt) 9 -Encoding ascii
  Assert ((Run $legacy)-eq 0) 'legacy migration succeeds'
  $cursor=ReadJson (Join-Path $legacy state/collector-cursor.v1.json);$g=[guid]::Empty
  Assert ($cursor.record_id -eq 11) 'legacy migration advances through fixtures'
  Assert ([guid]::TryParse("$($cursor.collection_epoch)",[ref]$g)) 'migration creates valid epoch'
  Assert (@(Get-ChildItem (Join-Path $legacy state)-Filter 'collector-cursor.txt.migrated.*').Count -eq 1) 'legacy cursor remains as evidence'
  $events=@(Get-Content (Join-Path $legacy spool/windows-events.v1.jsonl)|ForEach-Object{$_|ConvertFrom-Json})
  Assert ($events.Count -eq 2) 'two canonical events emitted'
  Assert (@($events.event_id|Sort-Object -Unique).Count -eq 2) 'canonical IDs are unique'
  Assert (@(Get-Content (Join-Path $legacy spool/windows-events.log)).Count -eq 2) 'compatibility spool mirrors canonical events'
  Assert ((Run $legacy)-eq 0) 'ordinary replay succeeds'
  Assert (@(Get-Content (Join-Path $legacy spool/windows-events.v1.jsonl)).Count -eq 2) 'advanced cursor prevents duplicates'

  $path=Join-Path $legacy state/collector-cursor.v1.json;$old=ReadJson $path;$epoch="$($old.collection_epoch)";$old.record_id=100
  (($old|ConvertTo-Json -Compress)+"`n")|Set-Content $path -Encoding utf8
  $count=@(Get-Content (Join-Path $legacy spool/windows-events.v1.jsonl)).Count
  Assert ((Run $legacy)-eq 1) 'high-water regression refuses without approval'
  $preserved=ReadJson $path;Assert ($preserved.record_id -eq 100 -and $preserved.collection_epoch -eq $epoch) 'refusal preserves cursor and epoch'
  Assert ((Run $legacy -Reset)-eq 0) 'approved reset succeeds';$new=ReadJson $path
  Assert ($new.record_id -eq 11 -and $new.collection_epoch -ne $epoch) 'approved reset starts new epoch at high-water'
  Assert (@(Get-Content (Join-Path $legacy spool/windows-events.v1.jsonl)).Count -eq $count) 'approved reset does not backfill'
  'collector baseline/reset fixture: PASS'
}finally{Remove-Item $temp -Recurse -Force -ErrorAction Ignore}
