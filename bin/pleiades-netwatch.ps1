# pleiades-netwatch.ps1 — network-layer MITM sensor for the Pleiades bridge.
# Catches the EFFECT of evil twins / stingrays / rogue relays once they MITM the
# wire: gateway MAC swap (ARP spoof / rogue gateway), DNS hijack, and ARP conflicts
# (one MAC claiming multiple IPs). Emits to a spool the container seals into the
# signed ledger. No special hardware needed — works on the wired DC.
#
# Baseline is established on first run and is STICKY: a change alerts, it does not
# silently re-baseline (so a persistent MITM can't become the new "normal").
# To re-bless after a legitimate change: delete C:\pleiades\state\netwatch-baseline.json
[CmdletBinding()]
param([string]$Root = 'C:\pleiades')
$ErrorActionPreference = 'Stop'
$spool = Join-Path $Root 'spool\netwatch.log'
$base  = Join-Path $Root 'state\netwatch-baseline.json'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $spool), (Split-Path $base)

function Emit($kind, $sev, $detail) {
  $ts = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  Add-Content -Path $spool -Value "ts=$ts kind=$kind severity=$sev $detail" -Encoding Ascii
}

$cfg  = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
$gwip = $cfg.IPv4DefaultGateway.NextHop
$gwmac = (Get-NetNeighbor -IPAddress $gwip -ErrorAction SilentlyContinue | Select-Object -First 1).LinkLayerAddress
$dns  = (($cfg.DNSServer | Where-Object AddressFamily -eq 2 | Select-Object -Expand ServerAddresses) -join ',')

# ARP conflict: a unicast MAC mapped to more than one IPv4 neighbor = spoofing signature.
$arp = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
  $_.State -in 'Reachable','Stale','Permanent' -and $_.LinkLayerAddress -and
  $_.LinkLayerAddress -notin 'FF-FF-FF-FF-FF-FF','00-00-00-00-00-00' -and
  $_.IPAddress -notmatch '^(224|239|255|0\.|169\.254|127)'
}
$dupMacs = $arp | Group-Object LinkLayerAddress | Where-Object { ($_.Group.IPAddress | Select-Object -Unique).Count -gt 1 }

if (-not (Test-Path $base)) {
  [ordered]@{ gwip=$gwip; gwmac=$gwmac; dns=$dns } | ConvertTo-Json | Set-Content $base -Encoding Ascii
  Emit 'netwatch_baseline' 'info' "gwip=$gwip gwmac=$gwmac dns=$dns"
  "baseline established: gw=$gwip/$gwmac dns=$dns"; return
}

$b = Get-Content $base -Raw | ConvertFrom-Json
$alerts = 0
if ($b.gwmac -and $gwmac -and $b.gwmac -ne $gwmac) { Emit 'gateway_mac_change' 'high' "gwip=$gwip old=$($b.gwmac) new=$gwmac"; $alerts++ }
if ($gwip -and -not $gwmac) { Emit 'gateway_unresolved' 'med' "gwip=$gwip"; $alerts++ }
if ($b.dns -ne $dns) { Emit 'dns_change' 'med' "old=$($b.dns) new=$dns"; $alerts++ }
foreach ($d in $dupMacs) { Emit 'arp_conflict' 'high' ("mac=$($d.Name) ips=" + (($d.Group.IPAddress | Select-Object -Unique) -join ';')); $alerts++ }

"netwatch: gw=$gwip/$gwmac dns=$dns dupMacs=$($dupMacs.Count) alerts=$alerts"
