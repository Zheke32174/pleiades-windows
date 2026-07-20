# Install the reviewed Pleiades Windows source and optionally register bounded tasks.
[CmdletBinding()]
param(
  [string]$InstallRoot = 'C:\pleiades',
  [string]$Distro = 'Ubuntu',
  [string]$Machine = 'pleiades',
  [string]$Unit = 'pleiades-container.service',
  [string]$SupervisorUser = $env:USERNAME,
  [switch]$RegisterTasks,
  [switch]$Update,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$CanonicalMachine = 'pleiades'
$CanonicalUnit = 'pleiades-container.service'
$TaskNames = [ordered]@{
  Collector = 'Pleiades Security Collector'
  Netwatch = 'Pleiades Network Watch'
  Supervisor = 'Pleiades WSL Supervisor'
}
$ReceiptSchema = 'pleiades.windows-install-receipt/v1'
$ManagedFiles = @(
  'LICENSE',
  'VERSION',
  'bin/pleiades-collector.ps1',
  'bin/pleiades-netwatch.ps1',
  'bin/pleiades-snapshot.sh',
  'bin/pleiades-supervisor.ps1',
  'ops/uninstall-windows.ps1',
  'portal/pleiades.php'
)

function Write-Plan([string]$Message) {
  if ($DryRun) { Write-Host "[dry-run] $Message" } else { Write-Host $Message }
}

function Test-Administrator {
  if (-not $IsWindows) { return $false }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SafeText([string]$Name, [string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name must not be empty" }
  if ($Value -match '[\x00-\x1F\x7F"]') { throw "$Name contains an unsupported control character or quote" }
}

function Assert-LifecycleConfiguration {
  if ($Distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw 'Distro must use a bounded non-shell identifier'
  }
  if ($Machine -cne $CanonicalMachine) {
    throw "Machine must be exactly $CanonicalMachine"
  }
  if ($Unit -cne $CanonicalUnit) {
    throw "Unit must be exactly $CanonicalUnit"
  }
}

function Resolve-InstallRoot([string]$Path) {
  Assert-SafeText 'InstallRoot' $Path
  if (-not $IsWindows) {
    if ($DryRun) { return $Path }
    throw 'Windows is required for installation; use -DryRun for review on another platform'
  }
  $resolved = [IO.Path]::GetFullPath($Path)
  $driveRoot = [IO.Path]::GetPathRoot($resolved)
  if ($resolved.TrimEnd('\') -eq $driveRoot.TrimEnd('\')) { throw "refusing drive root as InstallRoot: $resolved" }
  $blocked = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
  foreach ($candidate in $blocked) {
    $full = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
    if ($resolved.TrimEnd('\').Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
      throw "refusing protected host directory as InstallRoot: $resolved"
    }
  }
  return $resolved.TrimEnd('\')
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicText([string]$Path, [string]$Text) {
  $directory = Split-Path -Parent $Path
  $null = New-Item -ItemType Directory -Force -Path $directory
  $temporary = Join-Path $directory ".$(Split-Path -Leaf $Path).tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
  try {
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
  } catch {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Copy-ManagedFile([string]$Source, [string]$Destination, [string]$BackupRoot) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "managed source file missing: $Source" }
  $sourceHash = Get-Sha256 $Source
  if (Test-Path -LiteralPath $Destination) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw "managed destination is not a file: $Destination" }
    $destinationHash = Get-Sha256 $Destination
    if ($sourceHash -eq $destinationHash) {
      Write-Plan "Verified unchanged managed file $Destination"
      return $sourceHash
    }
    if (-not $Update) { throw "refusing to overwrite differing managed file without -Update: $Destination" }
    $relative = [IO.Path]::GetRelativePath($InstallRoot, $Destination)
    $backup = Join-Path $BackupRoot $relative
    Write-Plan "Back up $Destination to $backup"
    if (-not $DryRun) {
      $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup)
      Copy-Item -LiteralPath $Destination -Destination $backup
    }
  }
  Write-Plan "Install $Source to $Destination"
  if (-not $DryRun) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination)
    $temporary = Join-Path (Split-Path -Parent $Destination) ".$(Split-Path -Leaf $Destination).tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
      Copy-Item -LiteralPath $Source -Destination $temporary
      Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } catch {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      throw
    }
  }
  return $sourceHash
}

function Quote-TaskValue([string]$Value) {
  Assert-SafeText 'task argument' $Value
  return '"' + $Value + '"'
}

function Register-ReviewedTask(
  [string]$Name,
  [string]$ScriptPath,
  [string]$Arguments,
  [object[]]$Triggers,
  [object]$Principal,
  [string]$PrincipalLabel,
  [string]$BackupRoot
) {
  $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if ($existing) {
    if (-not $Update) { throw "scheduled task already exists; use -Update after review: $Name" }
    $taskBackup = Join-Path $BackupRoot ('tasks\' + ($Name -replace '[^A-Za-z0-9._-]', '_') + '.xml')
    Write-Plan "Back up scheduled task $Name to $taskBackup"
    if (-not $DryRun) {
      $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $taskBackup)
      Export-ScheduledTask -TaskName $Name | Set-Content -LiteralPath $taskBackup -Encoding utf8
      Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
  }

  Write-Plan "Register task $Name as $PrincipalLabel for $ScriptPath"
  if (-not $DryRun) {
    $action = New-ScheduledTaskAction -Execute (Get-Command pwsh.exe -ErrorAction Stop).Source -Argument $Arguments
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
    $task = New-ScheduledTask -Action $action -Trigger $Triggers -Principal $Principal -Settings $settings -Description 'Managed by pleiades-windows install receipt'
    Register-ScheduledTask -TaskName $Name -InputObject $task -Force | Out-Null
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Assert-LifecycleConfiguration
$InstallRoot = Resolve-InstallRoot $InstallRoot
Assert-SafeText 'SupervisorUser' $SupervisorUser

$versionPath = Join-Path $repoRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) { throw 'VERSION is missing from the source package' }
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "invalid VERSION: $version" }

$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backupRoot = Join-Path $InstallRoot "state\install-backups\$timestamp"
$installed = @()

foreach ($relative in $ManagedFiles) {
  $source = Join-Path $repoRoot $relative
  $destination = Join-Path $InstallRoot $relative
  [string]$hash = Copy-ManagedFile -Source $source -Destination $destination -BackupRoot $backupRoot
  if ($hash -notmatch '^[0-9a-f]{64}$') { throw "managed file hash is malformed: $relative" }
  $installed += [ordered]@{ path = ($relative -replace '\\', '/'); sha256 = $hash }
}

$registeredTasks = @()
if ($RegisterTasks) {
  if (-not $IsWindows) { throw 'scheduled-task registration requires Windows' }
  if (-not (Test-Administrator)) { throw 'scheduled-task registration requires an elevated PowerShell session' }
  if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) { throw 'pwsh.exe is required for scheduled tasks' }

  $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
  $systemPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $userPrincipal = New-ScheduledTaskPrincipal -UserId $SupervisorUser -LogonType Interactive -RunLevel Limited

  $collectorPath = Join-Path $InstallRoot 'bin\pleiades-collector.ps1'
  $netwatchPath = Join-Path $InstallRoot 'bin\pleiades-netwatch.ps1'
  $supervisorPath = Join-Path $InstallRoot 'bin\pleiades-supervisor.ps1'
  $collectorArgs = "-NoLogo -NoProfile -NonInteractive -File $(Quote-TaskValue $collectorPath) -Root $(Quote-TaskValue $InstallRoot)"
  $netwatchArgs = "-NoLogo -NoProfile -NonInteractive -File $(Quote-TaskValue $netwatchPath) -Root $(Quote-TaskValue $InstallRoot)"
  $supervisorArgs = "-NoLogo -NoProfile -NonInteractive -File $(Quote-TaskValue $supervisorPath) -Root $(Quote-TaskValue $InstallRoot) -Distro $(Quote-TaskValue $Distro)"

  Register-ReviewedTask -Name $TaskNames.Collector -ScriptPath $collectorPath -Arguments $collectorArgs -Triggers @($repeat) -Principal $systemPrincipal -PrincipalLabel 'SYSTEM' -BackupRoot $backupRoot
  Register-ReviewedTask -Name $TaskNames.Netwatch -ScriptPath $netwatchPath -Arguments $netwatchArgs -Triggers @($repeat) -Principal $systemPrincipal -PrincipalLabel 'SYSTEM' -BackupRoot $backupRoot
  $supervisorTriggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $SupervisorUser),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5))
  )
  Register-ReviewedTask -Name $TaskNames.Supervisor -ScriptPath $supervisorPath -Arguments $supervisorArgs -Triggers $supervisorTriggers -Principal $userPrincipal -PrincipalLabel $SupervisorUser -BackupRoot $backupRoot

  $registeredTasks = @(
    [ordered]@{ name = $TaskNames.Collector; principal = 'SYSTEM'; script = 'bin/pleiades-collector.ps1' },
    [ordered]@{ name = $TaskNames.Netwatch; principal = 'SYSTEM'; script = 'bin/pleiades-netwatch.ps1' },
    [ordered]@{ name = $TaskNames.Supervisor; principal = $SupervisorUser; script = 'bin/pleiades-supervisor.ps1' }
  )
}

if (-not $DryRun) {
  foreach ($directory in 'spool','state','portal','backup') {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot $directory)
  }

  $commit = $null
  if ((Test-Path -LiteralPath (Join-Path $repoRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $commit = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or "$commit" -notmatch '^[0-9a-f]{40}$') { $commit = $null }
  }

  $receipt = [ordered]@{
    schema = $ReceiptSchema
    version = $version
    source_commit = $commit
    installed_at = [DateTimeOffset]::UtcNow.ToString('o')
    install_root = $InstallRoot
    distro = $Distro
    machine = $CanonicalMachine
    unit = $CanonicalUnit
    scripts_authenticode = 'not-claimed'
    managed_files = $installed
    tasks_registered = [bool]$RegisterTasks
    tasks = $registeredTasks
  }
  $receiptPath = Join-Path $InstallRoot 'state\install-receipt.v1.json'
  Write-AtomicText -Path $receiptPath -Text (($receipt | ConvertTo-Json -Depth 8) + "`n")
  Write-Output "Installed Pleiades Windows $version to $InstallRoot"
  if ($RegisterTasks) { Write-Output 'Scheduled tasks were registered but not started.' }
  Write-Output "Receipt: $receiptPath"
} else {
  Write-Output 'Dry run complete; no files or tasks were changed.'
}
