# pleiades-netwatch.ps1 — Windows network-identity drift sensor.
#
# Maintains a sticky per-interface baseline for default gateway identity and DNS.
# Emits typed JSONL evidence plus the current legacy bridge line format. Findings
# are alerts, not automatic containment decisions.

[CmdletBinding()]
param(
  [string]$Root = 'C:\pleiades',
  [string]$InterfaceAlias
)

$ErrorActionPreference = 'Stop'
$spoolDir = Join-Path $Root 'spool'
$stateDir = Join-Path $Root 'state'
$null = New-Item -ItemType Directory -Force -Path $spoolDir, $stateDir
$jsonSpool = Join-Path $spoolDir 'netwatch.v1.jsonl'
$legacySpool = Join-Path $spoolDir 'netwatch.log'
$baselinePath = Join-Path $stateDir 'netwatch-baseline.v1.json'

$mutex = [Threading.Mutex]::new($false, 'Global\PleiadesNetwatch')
if (-not $mutex.WaitOne(0)) {
  Write-Output 'netwatch already running; exiting'
  exit 0
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
    } finally { $writer.Dispose() }
  } finally { $stream.Dispose() }
}

function Normalize-Dns($Configuration) {
  return @(if ($Configuration.DNSServer) {
    $Configuration.DNSServer.ServerAddresses |
      Where-Object { $_ } |
      Sort-Object -Unique
  })
}

function Get-NetworkIdentity {
  $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
    $_.IPv4DefaultGateway -and (-not $InterfaceAlias -or $_.InterfaceAlias -eq $InterfaceAlias)
  })

  $result = @()
  foreach ($config in $configs) {
    $gatewayIp = "$($config.IPv4DefaultGateway.NextHop)"
    $neighbor = Get-NetNeighbor -InterfaceIndex $config.InterfaceIndex -IPAddress $gatewayIp -ErrorAction SilentlyContinue |
      Select-Object -First 1
    $result += [ordered]@{
      interface_index = [int]$config.InterfaceIndex
      interface_alias = "$($config.InterfaceAlias)"
      gateway_ip = $gatewayIp
      gateway_mac = if ($neighbor) { "$($neighbor.LinkLayerAddress)".ToUpperInvariant() } else { $null }
      dns = @(Normalize-Dns $config)
    }
  }
  return @($result | Sort-Object interface_index)
}

function Emit-Finding([string]$Type, [string]$Severity, [hashtable]$Subject, [hashtable]$Evidence) {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $identity = "$Type/$($Subject.interface_index)/$now/$([guid]::NewGuid())"
  $record = [ordered]@{
    schema = 'pleiades.event/v1'
    event_id = "windows-netwatch/$identity"
    event_type = $Type
    source = [ordered]@{
      collector = 'pleiades-windows-netwatch'
      host = $env:COMPUTERNAME
      trust_class = 'host-collected'
    }
    observed_at = $now
    severity = $Severity
    subject = $Subject
    evidence = $Evidence
  }
  Add-Utf8Line $jsonSpool ($record | ConvertTo-Json -Depth 8 -Compress)

  $legacyType = $Type -replace '\.', '_'
  $legacy = "ts=$now kind=$legacyType severity=$Severity interface=$($Subject.interface_index) alias=$($Subject.interface_alias) detail=$((($Evidence | ConvertTo-Json -Compress) -replace '\s','_') -replace '[^\x20-\x7E]','')"
  Add-Utf8Line $legacySpool $legacy
}

try {
  $current = @(Get-NetworkIdentity)
  if ($current.Count -eq 0) {
    throw 'no active IPv4 default-gateway interface was found'
  }

  if (-not (Test-Path $baselinePath)) {
    [ordered]@{
      schema = 'pleiades.netwatch-baseline/v1'
      created_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      interfaces = $current
    } | ConvertTo-Json -Depth 8 | Set-Content -Path $baselinePath -Encoding utf8

    foreach ($item in $current) {
      Emit-Finding 'network.baseline_created' 'info' @{
        interface_index = $item.interface_index
        interface_alias = $item.interface_alias
      } @{
        gateway_ip = $item.gateway_ip
        gateway_mac = $item.gateway_mac
        dns = $item.dns
      }
    }
    Write-Output "baseline established for $($current.Count) interface(s)"
    exit 0
  }

  $baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json -ErrorAction Stop
  if ($baseline.schema -ne 'pleiades.netwatch-baseline/v1') {
    throw "unsupported baseline schema: $($baseline.schema)"
  }

  $findings = 0
  foreach ($expected in @($baseline.interfaces)) {
    $actual = $current | Where-Object { $_.interface_index -eq $expected.interface_index } | Select-Object -First 1
    $subject = @{
      interface_index = [int]$expected.interface_index
      interface_alias = "$($expected.interface_alias)"
    }

    if (-not $actual) {
      Emit-Finding 'network.interface_missing' 'medium' $subject @{
        expected_gateway_ip = "$($expected.gateway_ip)"
      }
      $findings++
      continue
    }

    if ($expected.gateway_ip -ne $actual.gateway_ip) {
      Emit-Finding 'network.gateway_ip_changed' 'high' $subject @{
        old = "$($expected.gateway_ip)"
        new = "$($actual.gateway_ip)"
      }
      $findings++
    }

    if ($expected.gateway_mac -and $actual.gateway_mac -and $expected.gateway_mac -ne $actual.gateway_mac) {
      Emit-Finding 'network.gateway_mac_changed' 'high' $subject @{
        gateway_ip = "$($actual.gateway_ip)"
        old = "$($expected.gateway_mac)"
        new = "$($actual.gateway_mac)"
      }
      $findings++
    } elseif ($actual.gateway_ip -and -not $actual.gateway_mac) {
      Emit-Finding 'network.gateway_unresolved' 'medium' $subject @{
        gateway_ip = "$($actual.gateway_ip)"
      }
      $findings++
    }

    $expectedDns = @($expected.dns | Sort-Object -Unique)
    $actualDns = @($actual.dns | Sort-Object -Unique)
    if (($expectedDns -join ',') -ne ($actualDns -join ',')) {
      Emit-Finding 'network.dns_changed' 'medium' $subject @{
        old = $expectedDns
        new = $actualDns
      }
      $findings++
    }
  }

  # Multi-IP neighbor mappings can indicate spoofing, but proxy ARP and virtual
  # networking can also produce them. Emit a medium-confidence heuristic rather
  # than declaring an attack.
  $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.State -in 'Reachable', 'Stale', 'Permanent' -and $_.LinkLayerAddress -and
    $_.LinkLayerAddress -notin 'FF-FF-FF-FF-FF-FF', '00-00-00-00-00-00' -and
    $_.IPAddress -notmatch '^(224|239|255|0\.|169\.254|127\.)'
  }
  foreach ($group in @($neighbors | Group-Object InterfaceIndex, LinkLayerAddress)) {
    $ips = @($group.Group.IPAddress | Sort-Object -Unique)
    if ($ips.Count -le 1) { continue }
    $first = $group.Group | Select-Object -First 1
    Emit-Finding 'network.neighbor_multi_ip_mac' 'medium' @{
      interface_index = [int]$first.InterfaceIndex
      interface_alias = "$($first.InterfaceAlias)"
    } @{
      mac = "$($first.LinkLayerAddress)"
      ips = $ips
      confidence = 'heuristic'
    }
    $findings++
  }

  Write-Output "netwatch interfaces=$($current.Count) findings=$findings"
  exit 0
} catch {
  Write-Error $_
  exit 1
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
