# pleiades-supervisor.ps1 — keep WSL + the Pleiades nspawn container alive.
# Always-on Windows side. Checks the container; boots it if down. Pinging WSL
# also keeps the distro warm. Runs as the WSL-owning user (Administrator).
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu',
  [string]$BootScript = '/mnt/c/pleiades-analysis/boot-tmux.sh'
)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'                       # make wsl.exe emit UTF-8, not UTF-16
$log = 'C:\pleiades\state\supervisor.log'
function Log($m) { $l = "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') $m"; Add-Content -Path $log -Value $l -Encoding Ascii; Write-Output $l }

function Publish-Snapshot {
  try {
    $json = (& wsl.exe -d $Distro -u root -e bash /mnt/c/pleiades/bin/pleiades-snapshot.sh 2>$null) -join "`n"
    if ($json -match '"container"') {
      Set-Content -Path 'C:\pleiades\portal\status.json' -Value $json -Encoding Ascii
      Log "snapshot published ($($json.Length)b)"
    } else { Log 'snapshot skipped (no valid output)' }
  } catch { Log "snapshot error: $($_.Exception.Message)" }
}

function Backup-Snapshots {
  try {
    $dst = 'C:\pleiades\backup'; New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $src = '\\wsl.localhost\Ubuntu\workspaces\gentoo\root.x86_64\var\lib\maia\snapshots'
    if (Test-Path $src) {
      Get-ChildItem -Path "$src\maia-*.enc","$src\maia-*.sig" -ErrorAction SilentlyContinue | Copy-Item -Destination $dst -Force -ErrorAction SilentlyContinue
      $n = @(Get-ChildItem "$dst\maia-*.enc" -ErrorAction SilentlyContinue).Count
      Log "snapshots backed up to $dst ($n encrypted; escrow key NOT copied)"
    } else { Log 'snapshot source not reachable for backup' }
  } catch { Log "backup error: $($_.Exception.Message)" }
}

# Is a container init (systemd in a non-host pid-namespace) alive? This call also
# auto-starts the WSL distro if it was stopped.
$checkCmd = 'HOSTNS=$(readlink /proc/1/ns/pid); for p in $(pgrep -x systemd); do [ "$(readlink /proc/$p/ns/pid 2>/dev/null)" != "$HOSTNS" ] && { echo UP; exit 0; }; done; echo DOWN'

$state = (& wsl.exe -d $Distro -u root -e bash -c $checkCmd 2>&1 | Select-Object -Last 1)
if ("$state" -match 'UP') { Log 'container UP'; Publish-Snapshot; Backup-Snapshots; exit 0 }

Log "container DOWN ($state) -> booting"
$boot = & wsl.exe -d $Distro -u root -e bash $BootScript 2>&1
Log ('boot: ' + (($boot | Select-Object -Last 2) -join ' | '))
Start-Sleep -Seconds 2
$state2 = (& wsl.exe -d $Distro -u root -e bash -c $checkCmd 2>&1 | Select-Object -Last 1)
if ("$state2" -match 'UP') { Log 'recovered: container UP'; Publish-Snapshot; exit 0 }

# One retry — the first boot after a hard kill can race stale namespace state.
Log "still down ($state2) -> retry boot"
$boot2 = & wsl.exe -d $Distro -u root -e bash $BootScript 2>&1
Log ('boot(retry): ' + (($boot2 | Select-Object -Last 2) -join ' | '))
Start-Sleep -Seconds 2
$state3 = (& wsl.exe -d $Distro -u root -e bash -c $checkCmd 2>&1 | Select-Object -Last 1)
Log "post-retry state: $state3"
if ("$state3" -match 'UP') { Log 'recovered on retry'; Publish-Snapshot; exit 0 } else { Log 'RECOVERY FAILED'; exit 1 }
