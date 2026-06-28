# pleiades-windows

The always-on **Windows side** of the Pleiades defensive network — the half that
keeps the WSL/nspawn swarm fed, alive, and visible. Companion to the in-container
agents (the [`pleiades`](https://github.com/Zheke32174/pleiades) repo, `lean/`).

The Windows Server DC is always on; WSL may not be. So the system is split by
availability: sensing + resilience + visibility live on Windows; the signing and
forensic brain lives in the container.

## Components

| File | Role |
|---|---|
| `bin/pleiades-collector.ps1` | Reads threat-relevant **AD/Security** events (failed logons 4625, lockouts 4740, Kerberos failures, account/group changes), filters out service-account noise, appends them to the bridge spool. Scheduled task, every 5 min, runs as SYSTEM. |
| `bin/pleiades-supervisor.ps1` | Keeps WSL + the container alive (boots/self-heals), publishes the Command Deck snapshot, and copies encrypted snapshots offsite. Scheduled task, at logon + every 15 min, runs as the WSL-owning user. |
| `bin/pleiades-snapshot.sh` | Emits a JSON status snapshot (agent health + ledger integrity + recent signed events) from inside the container. |
| `portal/pleiades.php` | The **Command Deck** dashboard — drops into the nginx/PHP intranet portal (`C:\xampp\htdocs`), served behind the existing login. |
| `ops/verify-windows.ps1` | End-to-end Windows-side verification (AD→ledger, deck, backup, self-heal). |

## Data flow

```
DC Security log ──collector──▶ C:\pleiades\spool\windows-events.log
                                   │  (read-only bridge: --bind-ro=/mnt/c/pleiades:/host/win)
                                   ▼
                           Maia (in container) ──ingest──▶ hash-chained, Ed25519-signed Nexus ledger
                                   │
                  supervisor ──snapshot──▶ C:\pleiades\portal\status.json ──▶ pleiades.php (Command Deck)
                  supervisor ──backup────▶ C:\pleiades\backup\*.enc (encrypted; escrow key NOT copied)
```

If WSL is down, events buffer in the spool and seal when it returns — no blind gap.

## Runtime layout (created at install; NOT in this repo)
`C:\pleiades\{spool,state,portal,backup}` hold live event data, cursors, the published
snapshot, and encrypted backups. None of it is committed — see `.gitignore`.

## Install (sketch)
1. `bin/*` → `C:\pleiades\bin\`; `portal/pleiades.php` → `C:\xampp\htdocs\`.
2. Register `Pleiades-Collector` (SYSTEM, 5 min) and `Pleiades-Supervisor`
   (current user, logon + 15 min) scheduled tasks.
3. Boot the container with `--bind-ro=/mnt/c/pleiades:/host/win`.

> Headless note: the supervisor runs while the operator is logged on (WSL distros are
> per-user; SYSTEM can't see them). For unattended-reboot recovery, set the task to
> "run whether logged on or not" yourself (it stores your password).
