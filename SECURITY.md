# Security Policy

## Supported scope

Pleiades Windows is a pre-production host observer, local evidence outbox, read-only status renderer, and bounded WSL lifecycle coordinator.

Only the current reviewed default branch and the most recent verified source release are eligible for fixes. Historical tags, local state, operator-modified task definitions, and separately deployed web or ingestion services are outside the supported release boundary unless the same issue reproduces on a current revision.

## Private reporting

Use GitHub's private vulnerability-reporting or Security Advisory interface when available. Do not place real event records, account names, machine details, network configuration, credentials, local paths, or private status snapshots in a public issue.

A useful report includes:

- affected commit or release;
- Windows and PowerShell versions;
- whether WSL, scheduled tasks, and the portal were enabled;
- exact command with machine-specific values removed;
- expected and observed behavior;
- impact on cursor state, outbox ordering, network baseline, task registration, WSL lifecycle, snapshot publication, installation, update, or removal.

No response-time or remediation-time guarantee is offered.

## Implemented boundary

The supported code can read selected local Windows observations, write private local state and outboxes, render one validated status snapshot, coordinate one configured WSL systemd unit, and copy encrypted snapshot files into a local mirror.

It does not provide a general command endpoint, network containment, automatic remediation, event signing, global trust decisions, web authentication, or offsite recovery.

Windows remains the authority over its local event logs, task scheduler, filesystem, networking, and WSL configuration. The Linux host remains the authority over its registered container lifecycle.

## Collection and replay

The Security collector uses typed cursor state and a persistent collection epoch. Cursor advancement follows successful local outbox writes, so delivery is intentionally at least once. Downstream ingestion must deduplicate stable event IDs.

Corrupt cursor state and unexpected log identity changes are refused. The explicit log-reset option begins a new epoch and should be used only after review.

Network baseline findings are evidence rather than containment decisions. Baselines remain sticky until an operator verifies a legitimate change.

## Installation and removal

Release artifacts contain source scripts. They are verified by release checksums and an exact-commit receipt; no Authenticode signature is claimed.

The installer must not change execution policy. Scheduled-task registration is separately explicit and requires reviewed principals. Updates preserve replaced managed files and prior task definitions. Removal preserves event outboxes, cursor state, baselines, logs, and local snapshot files unless destructive purge is separately confirmed.

## Sensitive information

Do not commit credentials, private keys, event exports, account inventories, local status data, private network details, local usernames, machine-specific paths, or runtime state.

CI scans the current tracked tree and reachable Git history for configured sensitive patterns. That scan is a review aid, not proof of universal absence. If a real credential reached history, revoke or rotate it before deciding whether coordinated history remediation is required.

## Release integrity

A valid release must come from the matching immutable version tag, pass source and installer verification, reproduce byte-for-byte, include checksums plus SPDX and build receipts, disclose unsigned-source status, and refuse release identity overwrite.
