# Changelog

This project uses semantic versioning for the Pleiades-owned Windows collectors, local state schemas, installer/removal helpers, portal source, and source-release tooling.

## Unreleased

- Validate the first immutable `v0.2.0` GitHub Release assets after stacked review and integration.
- Capture a disposable Windows receipt for scheduled-task principals, first collection, replay, explicit log reset, WSL restart, portal rendering, update, rollback, and data-preserving uninstall.
- Replace the temporary compatibility text spools with an authenticated acknowledgement and retention protocol before compaction is added.

## 0.2.0

Windows bridge and public-distribution hardening:

- rebuild Security collection around typed cursor state, persistent collection epochs, atomic replacement, and stable replay-safe event identities;
- refuse corrupt legacy/typed cursor state and implicit Security-log reset;
- emit canonical typed JSONL while retaining a temporary compatibility spool;
- add per-interface sticky gateway/DNS baselines and uncertainty-labelled drift evidence;
- coordinate one registered Linux unit through WSL rather than process guessing;
- publish schema-validated status atomically and render it through an escaped read-only PHP portal;
- keep encrypted snapshot mirroring local and exclude escrow material;
- make verification fail honestly and keep live/destructive checks separately explicit;
- correct the MODOS declaration from operational signed-instruction/event claims to an experimental observer and bounded lifecycle coordinator;
- add a reversible installer with managed-file hashes, receipts, optional reviewed task registration, and update backups;
- add an uninstaller that preserves evidence-bearing runtime data by default and requires explicit purge confirmation;
- add the previously missing MIT license and security/privacy/provenance/support documents;
- add current-tree and reachable-history sensitivity scanning;
- add deterministic Windows ZIP packaging, SHA-256 checksums, SPDX 2.3 inventory, and exact-commit build receipt;
- add immutable tag-only release publication with unsigned-source disclosure;
- consolidate validation into one pull-request workflow with Windows and portable jobs.

`0.2.0` is not published until a reviewed tag creates and verifies the named ZIP and accompanying verification assets.

## Historical state

Earlier revisions used broad Windows-drive bridge assumptions, PID/process guesses, hand-built status JSON, naked cursor text, mutable compatibility state, and manual installation guidance. Those historical paths remain lineage, not the supported release contract.
