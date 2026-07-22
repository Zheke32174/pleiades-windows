# Privacy and Data Behavior

Pleiades Windows does not include analytics, advertising, account tracking, or a hosted maintainer service.

## Local data

The default runtime root is `C:\pleiades`. Depending on enabled components, it can contain:

- selected Windows Security-event observations;
- gateway and DNS baseline data;
- typed JSONL outboxes and temporary compatibility logs;
- collector cursor and collection-epoch state;
- supervisor logs and a validated status snapshot;
- encrypted snapshot files and detached signatures copied from the Linux guest;
- installation, update, task-definition, and removal receipts.

Those records can reveal account names, host identity, timestamps, network configuration, operational status, and security-relevant events. Treat the runtime tree as private evidence-bearing data.

## Network behavior

The collectors and netwatch do not upload observations. The supervisor uses local `wsl.exe` integration to inspect and coordinate the configured Linux unit.

The PHP Command Deck reads a local status snapshot. Network exposure, authentication, TLS, access logs, retention, and backups depend on the separately configured web server and are not provided by this repository.

A future ingestion service is outside the current implementation. The temporary compatibility spool is not an acknowledgement or deletion protocol.

## Local snapshot mirror

The `backup` directory is a local resilience mirror, not an offsite backup. It contains only selected encrypted snapshot and signature files and must not contain the escrow key.

Independent recovery replication requires a separate destination, credential, retention policy, and deletion procedure.

## Retention

Outboxes, cursors, baselines, logs, status snapshots, and encrypted mirror files remain until the operator removes them. The current runtime does not automatically compact acknowledged events or expire evidence.

Default uninstall removes managed program files and reviewed scheduled tasks while preserving runtime data. Destructive purge requires separate confirmation.

Removing local data cannot delete copies already exported, backed up, mirrored, ingested, or served through another system.

## Public collaboration

Do not attach real event outboxes, cursor files, baselines, supervisor logs, status snapshots, task XML, or local mirror files to public issues. Use synthetic fixtures and remove account, host, network, path, and timestamp details from diagnostics.
