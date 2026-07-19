# Deterministic installer/uninstaller contract tests using a disposable temporary root.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $PSScriptRoot 'install-windows.ps1'
$uninstaller = Join-Path $PSScriptRoot 'uninstall-windows.ps1'
$supervisor = Join-Path $repoRoot 'bin\pleiades-supervisor.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("pleiades-windows-test-" + [Guid]::NewGuid().ToString('N'))

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
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

try {
  # Lifecycle identity is validated before dry-run planning or filesystem mutation.
  Expect-Failure {
    & $installer -InstallRoot $testRoot -Distro "Ubuntu';touch injected;#" -DryRun | Out-Null
  } 'bounded non-shell identifier'
  Expect-Failure {
    & $installer -InstallRoot $testRoot -Machine "pleiades';touch injected;#" -DryRun | Out-Null
  } 'Machine must be exactly pleiades'
  Expect-Failure {
    & $installer -InstallRoot $testRoot -Unit 'other.service' -DryRun | Out-Null
  } 'Unit must be exactly pleiades-container.service'
  Assert (-not (Test-Path -LiteralPath $testRoot)) 'invalid lifecycle configuration created the install root'

  & $supervisor -Root $testRoot -Distro Ubuntu -ValidateConfigurationOnly | Out-Null
  Expect-Failure {
    & $supervisor -Root $testRoot -Distro 'Ubuntu$(touch-injected)' -ValidateConfigurationOnly | Out-Null
  } 'bounded non-shell identifier'
  Expect-Failure {
    & $supervisor -Root $testRoot -Machine other -ValidateConfigurationOnly | Out-Null
  } 'Machine must be exactly pleiades'
  Expect-Failure {
    & $supervisor -Root $testRoot -Unit other.service -ValidateConfigurationOnly | Out-Null
  } 'Unit must be exactly pleiades-container.service'
  Assert (-not (Test-Path -LiteralPath $testRoot)) 'configuration-only validation created runtime directories'

  $supervisorSource = Get-Content -LiteralPath $supervisor -Raw
  Assert (-not $supervisorSource.Contains('bash -lc')) 'supervisor still constructs bash -lc command strings'
  Assert ($supervisorSource.Contains('function Invoke-WslTyped')) 'typed WSL invocation helper missing'
  Assert ($supervisorSource.Contains("'wslpath', '-a', '-u', `$Root")) 'supervisor does not derive bridge path from installed Root'
  Assert (-not $supervisorSource.Contains('. /etc/pleiades/container.env')) 'supervisor still sources container.env as shell code'

  $installerSource = Get-Content -LiteralPath $installer -Raw
  $supervisorArgumentLine = @($installerSource -split "`n" | Where-Object { $_ -match '^\s*\$supervisorArgs\s*=' })
  Assert ($supervisorArgumentLine.Count -eq 1) 'installer must define one supervisor task argument line'
  Assert (-not $supervisorArgumentLine[0].Contains('-Machine')) 'scheduled supervisor task forwards mutable machine identity'
  Assert (-not $supervisorArgumentLine[0].Contains('-Unit')) 'scheduled supervisor task forwards mutable unit identity'

  & $installer -InstallRoot $testRoot -DryRun | Out-Null
  Assert (-not (Test-Path -LiteralPath $testRoot)) 'dry run created the install root'

  & $installer -InstallRoot $testRoot | Out-Null
  $receiptPath = Join-Path $testRoot 'state\install-receipt.v1.json'
  Assert (Test-Path -LiteralPath $receiptPath) 'install receipt missing'
  $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
  Assert ($receipt.schema -eq 'pleiades.windows-install-receipt/v1') 'unexpected install receipt schema'
  Assert ($receipt.tasks_registered -eq $false) 'tasks registered without explicit switch'
  Assert ($receipt.machine -eq 'pleiades') 'receipt machine identity is not canonical'
  Assert ($receipt.unit -eq 'pleiades-container.service') 'receipt unit identity is not canonical'
  Assert (@($receipt.managed_files).Count -ge 8) 'managed file receipt is incomplete'

  foreach ($entry in @($receipt.managed_files)) {
    $path = Join-Path $testRoot ("$($entry.path)" -replace '/', '\')
    $receiptHash = "$($entry.sha256)"
    Assert ($receiptHash -match '^[0-9a-f]{64}$') "managed receipt hash is not one scalar SHA-256: $path"
    Assert (Test-Path -LiteralPath $path -PathType Leaf) "managed file missing: $path"
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert ($hash -eq $receiptHash) "managed hash mismatch: $path"
  }

  & $installer -InstallRoot $testRoot | Out-Null

  $collector = Join-Path $testRoot 'bin\pleiades-collector.ps1'
  Add-Content -LiteralPath $collector -Value '# local modification' -Encoding utf8
  Expect-Failure { & $installer -InstallRoot $testRoot | Out-Null } 'refusing to overwrite differing managed file'

  & $installer -InstallRoot $testRoot -Update | Out-Null
  $collectorHash = (Get-FileHash -LiteralPath $collector -Algorithm SHA256).Hash.ToLowerInvariant()
  $sourceCollector = Join-Path $repoRoot 'bin\pleiades-collector.ps1'
  Assert ($collectorHash -eq (Get-FileHash -LiteralPath $sourceCollector -Algorithm SHA256).Hash.ToLowerInvariant()) 'update did not restore source collector'
  $backupCollector = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state\install-backups') -Recurse -Filter 'pleiades-collector.ps1' -File)
  Assert ($backupCollector.Count -ge 1) 'update did not preserve previous managed file'
  Assert ((Get-Content -LiteralPath $backupCollector[-1].FullName -Raw).Contains('# local modification')) 'backup does not contain replaced file'

  $sentinel = Join-Path $testRoot 'spool\preserve-me.txt'
  Set-Content -LiteralPath $sentinel -Value 'runtime evidence fixture' -Encoding utf8
  & $uninstaller -InstallRoot $testRoot | Out-Null
  Assert (Test-Path -LiteralPath $sentinel) 'default uninstall removed runtime data'
  Assert (-not (Test-Path -LiteralPath $collector)) 'default uninstall left managed collector'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state') -Filter 'uninstall-receipt.*.json').Count -eq 1) 'uninstall receipt missing'

  & $installer -InstallRoot $testRoot | Out-Null
  Add-Content -LiteralPath $collector -Value '# modified before uninstall' -Encoding utf8
  Expect-Failure { & $uninstaller -InstallRoot $testRoot | Out-Null } 'refusing modified managed file'
  Assert (Test-Path -LiteralPath $collector) 'refused uninstall removed modified file'

  & $installer -InstallRoot $testRoot -Update | Out-Null
  Expect-Failure { & $uninstaller -InstallRoot $testRoot -PurgeData | Out-Null } 'requires -Yes'
  Assert (Test-Path -LiteralPath $testRoot) 'unconfirmed purge removed test root'

  & $uninstaller -InstallRoot $testRoot -PurgeData -Yes | Out-Null
  Assert (-not (Test-Path -LiteralPath $testRoot)) 'confirmed purge did not remove test root'

  Write-Output 'PASS: Windows lifecycle configuration, install, update, uninstall, preservation, and purge contracts'
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
