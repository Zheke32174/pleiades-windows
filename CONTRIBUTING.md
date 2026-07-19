# Contributing

Pleiades Windows accepts narrowly scoped improvements to host observation, local evidence handling, status rendering, bounded WSL lifecycle coordination, installation/removal safety, documentation, and reproducible source releases.

## Rules

- Do not commit event exports, account data, network baselines, status snapshots, task XML from a real host, credentials, private topology, or local runtime state.
- Keep the Command Deck read-only.
- Do not broaden the supervisor from one configured systemd unit into a general command channel.
- Keep network findings observational; do not add automatic containment without a separate reviewed authority design.
- Preserve typed cursor, collection-epoch, replay, and at-least-once semantics.
- Keep scheduled-task registration explicit and reversible.
- Do not bypass PowerShell execution policy or claim Authenticode signing when only checksums exist.
- Preserve runtime data by default during uninstall.

## Required checks

```powershell
pwsh -File .\ops\verify-windows.ps1 -Root "$PWD\.ci-runtime"
pwsh -File .\ops\test-install-windows.ps1
```

```bash
bash -n bin/pleiades-snapshot.sh
php -l portal/pleiades.php
python3 ci/scan_public_repo.py
python3 scripts/package_release.py --output dist
```

A pull request should explain affected privileges, task principals, data classes, cursor/baseline behavior, WSL assumptions, migration, rollback, and release-provenance effects.

## Compatibility

Changes to event, cursor, baseline, status, install-receipt, task-name, or release schemas require tests and explicit migration/rollback notes. Existing durable state must not be silently reset or discarded.

Release identities are immutable. Do not replace assets or retarget an existing version.

## Support

This is a small pre-production project. Public issues may be used for reproducible non-sensitive defects. Security-sensitive reports belong in GitHub's private reporting channel when available.

No response-time, production-support, Windows-version, WSL-distribution, PHP-server, or long-term compatibility guarantee is offered.
