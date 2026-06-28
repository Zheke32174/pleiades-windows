# Windows-side end-to-end verification of the Pleiades bridge + resilience + deck.
$env:WSL_UTF8 = '1'
$script:P = 0; $script:F = 0
function Ok($m){ $script:P++; Write-Output "  [PASS] $m" }
function No($m){ $script:F++; Write-Output "  [FAIL] $m" }

Write-Output "== A. AD bridge end-to-end (real failed logon -> signed ledger) =="
$acct = "verify_intruder_$(Get-Random -Maximum 99999)"
cmd /c "net use \\127.0.0.1\IPC`$ /user:$acct WrongVerifyPass1 2>&1" | Out-Null
Start-Sleep -Seconds 2
& 'C:\pleiades\bin\pleiades-collector.ps1' | Out-Null
$inSpool = (Select-String -Path 'C:\pleiades\spool\windows-events.log' -Pattern $acct -SimpleMatch -ErrorAction SilentlyContinue).Count
if ($inSpool -ge 1) { Ok "collector captured failed logon ($acct)" } else { No "collector did not capture $acct" }
$cnt = [int](wsl -d Ubuntu -u root -e bash /mnt/c/pleiades-analysis/ledger-check.sh $acct | Select-Object -Last 1)
if ($cnt -ge 1) { Ok "AD event sealed into signed ledger ($cnt record)" } else { No "AD event not in ledger" }

Write-Output "== B. Command Deck =="
& 'C:\pleiades\bin\pleiades-supervisor.ps1' | Out-Null
$snap = 'C:\pleiades\portal\status.json'
if (Test-Path $snap) {
  $age = (Get-Date) - (Get-Item $snap).LastWriteTime
  $j = $null; try { $j = Get-Content $snap -Raw | ConvertFrom-Json } catch {}
  if ($j -and $j.verify -eq 'ok' -and $age.TotalSeconds -lt 180) { Ok "snapshot published, fresh ($([int]$age.TotalSeconds)s), ledger ok" } else { No "snapshot stale/invalid" }
} else { No "no status.json" }
$html = & 'C:\xampp\php\php.exe' 'C:\xampp\htdocs\pleiades.php' 2>&1
$errs = @($html | Select-String -Pattern 'Warning|Fatal|Parse error').Count
if ($errs -eq 0 -and ($html | Select-String 'Ledger integrity')) { Ok "dashboard renders cleanly (0 php errors)" } else { No "dashboard render errors: $errs" }
try { Invoke-WebRequest 'http://127.0.0.1:8081/pleiades.php' -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop | Out-Null; No "deck NOT gated (expected redirect)" }
catch { if ($_.Exception.Response.StatusCode.value__ -eq 302) { Ok "deck served behind auth (302 -> login)" } else { No "unexpected deck status" } }

Write-Output "== C. Offsite snapshot backup =="
$bk = @(Get-ChildItem 'C:\pleiades\backup\maia-*.enc' -ErrorAction SilentlyContinue)
$esc = Test-Path 'C:\pleiades\backup\escrow.key'
if ($bk.Count -ge 1 -and -not $esc) { Ok "encrypted snapshot offsite ($($bk.Count)); escrow key NOT copied" } else { No "backup missing or escrow leaked" }

Write-Output "== D. Self-heal (kill container -> supervisor recovers) =="
wsl -d Ubuntu -u root -e bash /mnt/c/pleiades-analysis/kill-container.sh | Out-Null
& 'C:\pleiades\bin\pleiades-supervisor.ps1' | Out-Null
$post = wsl -d Ubuntu -u root -e bash /mnt/c/pleiades-analysis/post-check.sh 2>&1 | Out-String
if ($post -match 'system: running') { Ok "container recovered after kill" } else { No "container did not recover" }
if ($post -match 'ledger:.*OK') { Ok "ledger intact after recovery" } else { No "ledger not intact post-recovery" }
if ($post -match 'bridge: OK') { Ok "windows bridge re-mounted after recovery" } else { No "bridge missing post-recovery" }

Write-Output ""
Write-Output "===================================="
Write-Output "   WINDOWS-SIDE RESULT: PASS=$script:P  FAIL=$script:F"
Write-Output "===================================="
