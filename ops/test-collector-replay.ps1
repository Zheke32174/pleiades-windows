[CmdletBinding()]
param(
  [string]$Collector = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/pleiades-collector.ps1'),
  [string]$Wrapper = (Join-Path $PSScriptRoot 'collector-fixture-wrapper.ps1')
)
$ErrorActionPreference='Stop'
function Assert([bool]$Ok,[string]$Message){if(-not $Ok){throw "assertion failed: $Message"}}
function ReadJson([string]$Path){Get-Content $Path -Raw -Encoding utf8|ConvertFrom-Json}
$collector=(Resolve-Path $Collector).Path;$wrapper=(Resolve-Path $Wrapper).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) "pleiades-replay-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $temp|Out-Null
try{
  $fixture=Join-Path $temp events.json
  @(
    @{record_id=10;event_id=4625;machine=[Environment]::MachineName;time='2026-07-19T12:00:00Z';data=@{TargetUserName='alice';TargetDomainName='P';IpAddress='192.0.2.10';WorkstationName='a';LogonType='3';Status='x';SubStatus='y'}},
    @{record_id=11;event_id=4720;machine=[Environment]::MachineName;time='2026-07-19T12:01:00Z';data=@{TargetUserName='bob';TargetDomainName='P';IpAddress='-';WorkstationName='b';LogonType='-';Status='-';SubStatus='-'}}
  )|ConvertTo-Json -Depth 7|Set-Content $fixture -Encoding utf8
  function Run([string]$Root,[switch]$Break){
    $a=@('-NoProfile','-File',$wrapper,'-Collector',$collector,'-Root',$Root,'-Fixture',$fixture)
    if($Break){$a+='-BreakStateOnQuery'};& pwsh @a *> $null;$code=$LASTEXITCODE
    if($Break){$state=Join-Path $Root state;if(Test-Path $state -PathType Leaf){Remove-Item $state};if(Test-Path "$state.hold"){Move-Item "$state.hold" $state}}
    $code
  }

  $root=Join-Path $temp root;New-Item -ItemType Directory -Force (Join-Path $root state)|Out-Null
  Set-Content (Join-Path $root state/collector-cursor.txt) 9 -Encoding ascii
  Assert ((Run $root -Break)-eq 1) 'cursor publication failure is fatal'
  Assert ((ReadJson (Join-Path $root state/collector-cursor.v1.json)).record_id -eq 9) 'failed publication preserves prior cursor'
  $first=@(Get-Content (Join-Path $root spool/windows-events.v1.jsonl)|ForEach-Object{$_|ConvertFrom-Json})
  Assert ($first.Count -eq 1) 'one event appended before forced cursor failure'
  $id=$first[0].event_id;$epoch=$first[0].source.collection_epoch

  Assert ((Run $root)-eq 0) 'replay after cursor failure succeeds'
  $events=@(Get-Content (Join-Path $root spool/windows-events.v1.jsonl)|ForEach-Object{$_|ConvertFrom-Json})
  Assert ($events.Count -eq 3) 'at-least-once replay retains duplicate evidence plus next event'
  Assert (@($events|Where-Object event_id -eq $id).Count -eq 2) 'replayed event keeps stable event ID'
  Assert (@($events|Where-Object event_id -eq $id|Where-Object {$_.source.collection_epoch -eq $epoch}).Count -eq 2) 'replayed event keeps stable collection epoch'
  Assert ((ReadJson (Join-Path $root state/collector-cursor.v1.json)).record_id -eq 11) 'successful replay advances cursor'
  Assert (@(Get-Content (Join-Path $root spool/windows-events.log)).Count -eq 3) 'compatibility spool remains at-least-once with canonical spool'
  'collector replay fixture: PASS'
}finally{Remove-Item $temp -Recurse -Force -ErrorAction Ignore}
