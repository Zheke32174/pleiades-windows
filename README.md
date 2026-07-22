# Pleiades Windows

`pleiades-windows` is the pre-production Windows host-observation and read-only status adapter for Pleiades.

It collects selected Windows Security events, records gateway and DNS drift, publishes typed local outboxes, renders one validated status snapshot, and may ask one configured Linux systemd unit to start through WSL. It does **not** own the Pleiades trust root, accept arbitrary model commands, contain network activity, sign its emitted events, or promote its own evidence.

## Release status

Version `0.2.0` is the first proposed verified source release.

The release artifact is a deterministic ZIP of reviewed source. It is **not**:

- an MSI, MSIX, executable installer, Windows service, WSL distribution, container image, or web server;
- a bundle of credentials, event records, cursors, baselines, snapshots, or host configuration;
- an Authenticode-signed binary distribution.

The PowerShell files are intentionally disclosed as unsigned source. Verify the release checksums and exact-commit receipt before running them. This repository does not bypass PowerShell execution policy.

## Download and verify

From the GitHub Releases page, download all four assets for the same version:

```text
pleiades-windows-0.2.0.zip
pleiades-windows-0.2.0.spdx.json
pleiades-windows-0.2.0.build-receipt.json
SHA256SUMS.txt
```

Verify the ZIP hash in PowerShell:

```powershell
Get-FileHash .\pleiades-windows-0.2.0.zip -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

The reported SHA-256 must match the `pleiades-windows-0.2.0.zip` entry exactly. The build receipt records the repository commit, release-manifest digest, source timestamp, artifact hashes, and explicit package exclusions.

Extract the ZIP into a review directory. Do not run directly from a browser download cache or shared writable directory.

## Requirements

The supported source expects:

- Windows with PowerShell 7 available as `pwsh.exe`;
- Windows ScheduledTasks cmdlets only when task registration is requested;
- permission to read the Windows Security log for the collector;
- Windows networking cmdlets for netwatch;
- a reviewed WSL distribution with systemd for supervisor operation;
- the canonical `pleiades-container.service` already installed inside that WSL distribution;
- a separately administered authenticated PHP host only when the optional Command Deck is published.

The package does not install WSL, PHP, a web server, `pleiades-container`, or any Linux guest.

## Components

| File | Role |
|---|---|
| `bin/pleiades-collector.ps1` | Collects selected Security/AD events in RecordId order and writes canonical JSONL plus a temporary compatibility spool. |
| `bin/pleiades-netwatch.ps1` | Maintains sticky per-interface gateway and DNS baselines and emits drift evidence without containment. |
| `bin/pleiades-supervisor.ps1` | Checks the configured WSL unit, requests that one unit to start when down, publishes status, and mirrors encrypted snapshots locally. |
| `bin/pleiades-snapshot.sh` | Produces a schema-valid `pleiades.status/v1` snapshot from the registered Linux machine. |
| `portal/pleiades.php` | Renders one validated snapshot as a read-only page with defensive response headers. |
| `ops/install-windows.ps1` | Installs reviewed files, records hashes and settings, and optionally registers bounded tasks. |
| `ops/uninstall-windows.ps1` | Removes only receipt-matching files and tasks while preserving runtime data by default. |
| `ops/verify-windows.ps1` | Performs static checks and separately opt-in live integration tests. |

## Review before installation

The installer supports a non-mutating review pass:

```powershell
pwsh -File .\ops\install-windows.ps1 `
  -InstallRoot 'C:\pleiades' `
  -Distro 'Ubuntu' `
  -Machine 'pleiades' `
  -Unit 'pleiades-container.service' `
  -SupervisorUser "$env:USERDOMAIN\$env:USERNAME" `
  -DryRun
```

The dry run copies nothing, registers no tasks, and starts nothing.

## Install managed files

Install the reviewed files without registering tasks:

```powershell
pwsh -File .\ops\install-windows.ps1 -InstallRoot 'C:\pleiades'
```

The installer:

- copies only its fixed managed-file list;
- refuses protected roots and differing existing files;
- writes files through temporary replacements;
- creates private runtime directories but no event records;
- writes `C:\pleiades\state\install-receipt.v1.json` with exact managed-file hashes;
- does not register or start scheduled tasks unless explicitly requested.

## Register scheduled tasks

Task registration is a separate explicit action and requires an elevated PowerShell session:

```powershell
pwsh -File .\ops\install-windows.ps1 `
  -InstallRoot 'C:\pleiades' `
  -RegisterTasks `
  -SupervisorUser 'DOMAIN\WslOwner'
```

The proposed task split is:

| Task | Principal | Behavior |
|---|---|---|
| `Pleiades Security Collector` | `SYSTEM` | Runs the Security-log collector every five minutes. |
| `Pleiades Network Watch` | `SYSTEM` | Runs network-observation collection every five minutes. |
| `Pleiades WSL Supervisor` | named WSL-owning user | Runs at logon and periodically so it uses the intended user's WSL distribution. |

Registration does not start any task. Existing tasks are refused unless `-Update` is supplied after review. Replaced task definitions and managed files are backed up under `state\install-backups\<timestamp>`.

## Verify

Run the non-disruptive repository and installed-state checks:

```powershell
pwsh -File .\ops\verify-windows.ps1 -Root 'C:\pleiades'
```

A live collector and supervisor check is separately opt-in:

```powershell
pwsh -File .\ops\verify-windows.ps1 `
  -Root 'C:\pleiades' `
  -Distro 'Ubuntu' `
  -Integration
```

The intentional stop-and-recovery test requires both live integration and the destructive switch:

```powershell
pwsh -File .\ops\verify-windows.ps1 `
  -Root 'C:\pleiades' `
  -Distro 'Ubuntu' `
  -Integration `
  -DestructiveRecoveryTest
```

Do not run the destructive test on a host whose availability has not been explicitly scheduled for interruption.

## Update and rollback evidence

Review the new release and its hashes first, then update:

```powershell
pwsh -File .\ops\install-windows.ps1 `
  -InstallRoot 'C:\pleiades' `
  -Update
```

Add `-RegisterTasks` and the same reviewed `-SupervisorUser` only when task definitions are also meant to be replaced. The installer backs up differing managed files and existing task XML before replacement. It refuses silent overwrite without `-Update`.

The backup directory is evidence for manual rollback; the current pre-production installer does not automatically restore a failed partial task update. Review the receipt and backup set before enabling tasks after an update.

## Remove program files and tasks

Review removal first:

```powershell
pwsh -File 'C:\pleiades\ops\uninstall-windows.ps1' `
  -InstallRoot 'C:\pleiades' `
  -DryRun
```

Then remove managed program files and receipt-listed tasks:

```powershell
pwsh -File 'C:\pleiades\ops\uninstall-windows.ps1' `
  -InstallRoot 'C:\pleiades'
```

Removal is receipt-bound. It refuses modified managed files, unlisted tasks, tasks whose action no longer targets the managed script, and installations without a readable recognized receipt.

By default it preserves:

- event outboxes and compatibility spools;
- collector cursor and network baseline state;
- supervisor logs;
- published status;
- encrypted local snapshot mirrors;
- install/update backups and uninstall receipts.

Destructive removal requires two explicit switches:

```powershell
pwsh -File 'C:\pleiades\ops\uninstall-windows.ps1' `
  -InstallRoot 'C:\pleiades' `
  -PurgeData `
  -Yes
```

That deletes the recognized installation root, including event and recovery data. Export or preserve required evidence first.

## Data flow and retention

```text
Windows Security log ─┐
                      ├─ local collectors ─▶ typed JSONL outboxes
Gateway/DNS state ────┘                         │
                                                ├─ temporary compatibility spools
                                                └─ future authenticated ingestion

registered WSL systemd unit ─▶ status snapshot ─▶ read-only Command Deck
                  │
                  └─ encrypted snapshot files ─▶ local Windows mirror
```

There is no authenticated network ingestion implementation in this repository. Local records are not acknowledged or compacted merely because a network request was attempted. See [PRIVACY.md](PRIVACY.md) for retention and deletion details.

## Runtime layout

```text
C:\pleiades\
├── bin\
├── ops\
├── spool\
│   ├── windows-events.v1.jsonl
│   ├── windows-events.log
│   ├── netwatch.v1.jsonl
│   └── netwatch.log
├── state\
│   ├── collector-cursor.v1.json
│   ├── netwatch-baseline.v1.json
│   ├── supervisor.log
│   ├── install-receipt.v1.json
│   └── install-backups\
├── portal\
│   └── status.json
└── backup\
```

The `backup` directory is a local encrypted-snapshot mirror, not offsite recovery. Independent recovery replication needs another failure domain and separate credentials.

## Security boundary

- Collectors observe and emit evidence; they do not contain or retaliate.
- Network changes produce evidence and do not silently replace the sticky baseline.
- The Command Deck validates and renders one snapshot and has no control endpoint.
- The supervisor can request only the configured systemd unit through the configured WSL distribution.
- The installer never starts tasks, bypasses execution policy, or installs dependencies.
- Snapshot mirroring excludes `escrow.key` and fails if that file appears in the mirror.
- Emitted records are unsigned local observations and require downstream authentication and deduplication.

See [SECURITY.md](SECURITY.md) for the supported reporting scope.

## Development

```powershell
pwsh -File .\ops\verify-windows.ps1 -Root "$PWD\.verification-root"
pwsh -File .\ops\test-install-windows.ps1
```

Portable checks also parse `bin/pleiades-snapshot.sh`, lint `portal/pleiades.php`, scan the current tree and reachable Git history, and build the exact release source twice for byte comparison.

## Related repositories

- [`pleiades`](https://github.com/Zheke32174/pleiades) — canonical lean runtime and defensive architecture
- [`pleiades-container`](https://github.com/Zheke32174/pleiades-container) — Linux/Gentoo nspawn substrate and registered unit lifecycle
- [`pleiades-termux`](https://github.com/Zheke32174/pleiades-termux) — constrained Android observation edge

## License

MIT — see [LICENSE](LICENSE). Third-party and platform notices are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
