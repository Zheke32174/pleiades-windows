# Pleiades Windows

Windows-side sensing, lifecycle coordination, and read-only status publication for the Pleiades defensive system.

This repository is a **host collector and presentation layer**. It does not own the Pleiades trust root, authorize privileged actions, or replace the Linux host's deterministic supervision. The canonical container lifecycle is owned by `pleiades-container.service`; the Windows supervisor only asks that unit to start when WSL returns.

## Current status

Active, pre-production, and being migrated away from the original broad Windows-drive bridge.

The current branch provides:

- replay-safe Windows Security/AD event collection;
- typed `pleiades.event/v1` JSONL outboxes with stable event IDs;
- a temporary legacy line spool for compatibility with the current Maia bridge;
- per-interface gateway and DNS drift sensing with uncertainty labels;
- overlap-safe scheduled execution through named mutexes;
- systemd/machinectl lifecycle coordination instead of `boot-tmux.sh`;
- atomically published `pleiades.status/v1` snapshots;
- a hardened, read-only PHP Command Deck;
- verification that exits nonzero when a guarantee fails;
- destructive recovery tests disabled unless explicitly requested.

The next structural step is an authenticated event-ingestion service. Once that exists, the legacy `C:\pleiades\spool\*.log` bridge can be removed entirely.

## Components

| File | Role |
|---|---|
| `bin/pleiades-collector.ps1` | Collects selected Windows Security/AD events in RecordId order. Writes canonical JSONL and a compatibility spool. |
| `bin/pleiades-netwatch.ps1` | Maintains sticky per-interface gateway/DNS baselines and emits drift findings as evidence, not automatic containment. |
| `bin/pleiades-supervisor.ps1` | Starts the canonical Linux systemd unit when necessary, publishes status atomically, and mirrors encrypted snapshots locally. |
| `bin/pleiades-snapshot.sh` | Queries the registered `pleiades` nspawn machine and emits schema-valid JSON without hand-built escaping. |
| `portal/pleiades.php` | Read-only Command Deck renderer with strict output escaping and browser security headers. |
| `ops/verify-windows.ps1` | Static and optional live integration verification. Fails honestly. |

## Data flow

```text
Windows Security log ─┐
                      ├─ host collectors ─▶ typed JSONL outbox
Gateway/DNS state ────┘                         │
                                                ├─ temporary legacy compatibility spool
                                                └─ future authenticated ingestion service

Linux host systemd ─▶ registered Pleiades machine ─▶ signed Nexus ledger
        │
        └─ snapshot collector ─▶ atomic status.json ─▶ read-only Command Deck
```

## Runtime layout

Created at install time and intentionally not committed:

```text
C:\pleiades\
├── bin\
├── spool\
│   ├── windows-events.v1.jsonl
│   ├── windows-events.log          # temporary compatibility format
│   ├── netwatch.v1.jsonl
│   └── netwatch.log                # temporary compatibility format
├── state\
│   ├── collector-cursor.txt
│   ├── netwatch-baseline.v1.json
│   └── supervisor.log
├── portal\
│   └── status.json
└── backup\                         # local encrypted snapshot mirror only
```

The `backup` directory is **not offsite storage** merely because it is outside the guest. Independent recovery replication belongs on another device or storage provider with separate credentials.

## Installation outline

1. Copy `bin/*` to `C:\pleiades\bin\`.
2. Place `portal/pleiades.php` behind the existing authenticated intranet portal.
3. Register scheduled tasks:
   - collector as SYSTEM every five minutes;
   - netwatch under a network-readable account every five minutes;
   - supervisor as the WSL-owning user at logon and periodically.
4. Ensure WSL has the canonical `pleiades-container.service` from [`pleiades-container`](https://github.com/Zheke32174/pleiades-container).
5. Run static verification before enabling tasks.

```powershell
pwsh -File .\ops\verify-windows.ps1
```

For a live integration check:

```powershell
pwsh -File .\ops\verify-windows.ps1 -Integration
```

The intentional container-stop recovery test requires a second explicit switch:

```powershell
pwsh -File .\ops\verify-windows.ps1 -Integration -DestructiveRecoveryTest
```

## Baselines

Network baselines are sticky. A detected change generates evidence and does not silently become the new normal.

After a verified legitimate network change, remove the baseline deliberately and rerun netwatch:

```powershell
Remove-Item C:\pleiades\state\netwatch-baseline.v1.json
pwsh -File C:\pleiades\bin\pleiades-netwatch.ps1
```

## Security boundary

- Collectors observe and emit evidence; they do not contain or retaliate.
- The Command Deck reads one validated snapshot and has no control endpoint.
- The supervisor can request the one canonical Linux unit to start; it does not execute arbitrary model-generated commands.
- Snapshot mirroring excludes `escrow.key` and fails if that key appears in the mirror.
- Typed events carry stable IDs so the future gateway can deduplicate at-least-once delivery.
- The current compatibility spool is temporary and should be replaced by authenticated, durable ingestion.

## Related repositories

- [`pleiades`](https://github.com/Zheke32174/pleiades) — canonical lean runtime and defensive architecture
- [`pleiades-container`](https://github.com/Zheke32174/pleiades-container) — Gentoo nspawn substrate and host lifecycle
- [`pleiades-factory-stack`](https://github.com/Zheke32174/pleiades-factory-stack) — research toolchain manifests

MIT — see [LICENSE](LICENSE). Security reports should follow [SECURITY.md](SECURITY.md).
