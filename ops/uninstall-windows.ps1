# Remove managed Pleiades Windows files and tasks while preserving runtime data by default.
[CmdletBinding()]
param(
  [string]$InstallRoot = 'C:\pleiades',
  [switch]$PurgeData,
  [switch]$Yes,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ReceiptSchema = 'pleiades.windows-install-receipt/v1'
$TaskNames = @(
  'Pleiades Security Collector',
  'Pleiades Network Watch',
  'Pleiades WSL Supervisor'
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

function Resolve-InstallRoot([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1F\x7F"]') {
    throw 'InstallRoot is empty or contains an unsupported character'
  }
  if (-not $IsWindows) {
    if ($DryRun) { return $Path }
    throw 'Windows is required for removal; use -DryRun for review on another platform'
  }
  $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  $driveRoot = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
  if ($resolved -eq $driveRoot) { throw "refusing drive root as InstallRoot: $resolved" }
  return $resolved
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

$InstallRoot = Resolve-InstallRoot $InstallRoot
$receiptPath = Join-Path $InstallRoot 'state\install-receipt.v1.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
  throw "installation receipt not found; refusing unmanaged removal: $receiptPath"
}

try {
  $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
  throw "installation receipt is unreadable: $($_.Exception.Message)"
}

if ($receipt.schema -ne $ReceiptSchema) { throw "unexpected installation receipt schema: $($receipt.schema)" }
if ([string]::IsNullOrWhiteSpace("$($receipt.install_root)")) { throw 'installation receipt has no install_root' }
$receiptRoot = Resolve-InstallRoot "$($receipt.install_root)"
if (-not $receiptRoot.Equals($InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw "installation receipt belongs to a different root: $receiptRoot"
}

$managed = @($receipt.managed_files)
if ($managed.Count -eq 0) { throw 'installation receipt has no managed files' }
$plannedFiles = @()
foreach ($entry in $managed) {
  $relative = "$($entry.path)"
  $expectedHash = "$($entry.sha256)".ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or $relative.Contains('..')) {
    throw "unsafe managed path in receipt: $relative"
  }
  if ($expectedHash -notmatch '^[0-9a-f]{64}$') { throw "invalid managed hash in receipt: $relative" }
  $path = Join-Path $InstallRoot ($relative -replace '/', '\')
  if (Test-Path -LiteralPath $path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "managed path is no longer a file: $path" }
    $actualHash = Get-Sha256 $path
    if ($actualHash -ne $expectedHash) { throw "refusing modified managed file: $path" }
    $plannedFiles += $path
  }
}

$plannedTasks = @()
if ($IsWindows) {
  foreach ($taskName in $TaskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { continue }
    $receiptTask = @($receipt.tasks | Where-Object { $_.name -eq $taskName }) | Select-Object -First 1
    if (-not $receiptTask) { throw "scheduled task is not listed in the installation receipt: $taskName" }
    $scriptPath = Join-Path $InstallRoot ("$($receiptTask.script)" -replace '/', '\')
    $actions = @($task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Arguments.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
      throw "refusing scheduled task whose action no longer targets the managed script: $taskName"
    }
    $plannedTasks += $taskName
  }
} elseif (@($receipt.tasks).Count -gt 0 -and -not $DryRun) {
  throw 'Windows is required to inspect and remove registered tasks'
}

if ($plannedTasks.Count -gt 0 -and -not $DryRun -and -not (Test-Administrator)) {
  throw 'an elevated PowerShell session is required to remove registered tasks'
}

if ($PurgeData -and -not $Yes) {
  throw '-PurgeData requires -Yes because it deletes event outboxes, cursors, baselines, logs, status, and snapshot mirrors'
}

foreach ($taskName in $plannedTasks) {
  Write-Plan "Remove scheduled task $taskName"
  if (-not $DryRun) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
}

foreach ($path in $plannedFiles) {
  Write-Plan "Remove managed file $path"
  if (-not $DryRun) { Remove-Item -LiteralPath $path -Force }
}

if ($PurgeData) {
  Write-Plan "Purge recognized installation root $InstallRoot"
  if (-not $DryRun) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
  Write-Output 'Pleiades Windows managed files, tasks, and runtime data removed.'
  exit 0
}

if (-not $DryRun) {
  foreach ($directory in 'bin','ops') {
    $path = Join-Path $InstallRoot $directory
    if ((Test-Path -LiteralPath $path) -and -not (Get-ChildItem -LiteralPath $path -Force | Select-Object -First 1)) {
      Remove-Item -LiteralPath $path -Force
    }
  }
  $portal = Join-Path $InstallRoot 'portal'
  if ((Test-Path -LiteralPath $portal) -and -not (Get-ChildItem -LiteralPath $portal -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $portal -Force
  }

  $uninstallReceipt = [ordered]@{
    schema = 'pleiades.windows-uninstall-receipt/v1'
    source_install_schema = $receipt.schema
    version = $receipt.version
    removed_at = [DateTimeOffset]::UtcNow.ToString('o')
    install_root = $InstallRoot
    removed_files = @($plannedFiles | ForEach-Object { [IO.Path]::GetRelativePath($InstallRoot, $_) -replace '\\', '/' })
    removed_tasks = @($plannedTasks)
    runtime_data_preserved = $true
  }
  $uninstallReceiptPath = Join-Path $InstallRoot "state\uninstall-receipt.$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
  Write-AtomicText -Path $uninstallReceiptPath -Text (($uninstallReceipt | ConvertTo-Json -Depth 6) + "`n")
  Write-Output 'Managed program files and reviewed tasks removed.'
  Write-Output "Runtime data preserved at $InstallRoot"
  Write-Output "Receipt: $uninstallReceiptPath"
} else {
  Write-Output 'Dry run complete; no files, tasks, or runtime data were changed.'
}
