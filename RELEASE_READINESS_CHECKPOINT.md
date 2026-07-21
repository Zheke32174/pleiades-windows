# Public Release-Readiness Checkpoint

Repository: `Zheke32174/pleiades-windows`  
Draft branch: `hardening/public-release-readiness-v1`  
Draft pull request: `#4`  
Default branch changed: no  
Release publication authority: tag-only draft workflow; no tag or release authorized by this checkpoint

## Last reviewed heads and receipts

- Last fully validated implementation head before this update: `a6b02c280eaf6a8a0a328f1be07158ebddce8707`
- Exact CI run: `29690860645`
- Workflow hardening head: `238825d3b88240b4e887903babe9c31c2813fe40`
- Current ledger head: pending this commit

## Completed scope

- Corrected the public contract from a signed bidirectional authority adapter to a pre-production host observer with unsigned local outboxes and one bounded WSL unit-start request.
- Added MIT licensing, security, privacy, provenance, contribution, changelog, and third-party notice boundaries.
- Added deterministic unsigned-source ZIP packaging from a reviewed manifest.
- Added SHA-256 checksums, SPDX 2.3 source inventory, and an exact-commit build receipt.
- Added current-tree and reachable-history sensitivity scanning that does not echo matched sensitive values.
- Added reversible install, update, backup, dry-run, receipt-bound uninstall, default data preservation, and confirmed purge behavior.
- Added disposable-root tests for install, idempotency, overwrite refusal, update backup, removal, preservation, and purge.
- Consolidated PR validation across Windows PowerShell, portable scripts, ontology assertions, repository scanning, and reproducible packaging.
- Pinned third-party Actions to reviewed full-length commit SHAs.
- Disabled persisted checkout credentials in the release workflow.
- Replaced `ubuntu-latest` with the explicit `ubuntu-24.04` runner identity.
- Added proof that a release tag's commit is reachable from `main` before release creation.
- Preserved release-overwrite refusal and matching `VERSION`/tag enforcement.
- Clarified in generated release notes that unsigned downloaded PowerShell source may require an explicit trust decision under local execution policy and that the release does not alter or bypass that policy.

## Validation receipts

At exact head `a6b02c280eaf6a8a0a328f1be07158ebddce8707`, CI run `29690860645` passed.

The validated scope included:

- PowerShell parsing and PSScriptAnalyzer error enforcement;
- repository verification with thrown failures preserved;
- install/update/uninstall/purge contract tests;
- portable shell and PHP checks;
- MODOS/public-contract assertions;
- current-tree and reachable-history sensitivity scanning;
- two deterministic builds of the same exact head;
- byte-for-byte ZIP comparison;
- exact ZIP-manifest and receipt assertions;
- candidate artifact upload.

The current workflow and ledger commits require a fresh exact-head CI receipt. No release workflow was executed because doing so would require an unauthorized tag and public release.

## External practices applied

- GitHub secure-use guidance: full-length Action commit SHAs are the only immutable Action references.
- GitHub repository policy can require full-length Action pins; administrative verification remains separate from source review.
- Microsoft PowerShell guidance: downloaded unsigned scripts may be blocked by `RemoteSigned` or stricter policy; execution policy is a safety feature rather than a security boundary and must not be silently changed or bypassed.
- Candidate generation remains separate from publication, with exact version, source commit, ancestry, checksums, manifest, and overwrite-refusal checks.

Primary references reviewed on 2026-07-21:

- https://docs.github.com/en/actions/reference/security/secure-use
- https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies

## Open blockers

1. The stacked collector/runtime PR and this release-readiness PR must be reviewed and integrated in dependency order.
2. The disposable Windows event/cursor/reset/deduplication fixture required by the underlying runtime draft remains incomplete.
3. PSScriptAnalyzer warnings require steward review even though error-severity enforcement is green.
4. Scheduled-task registration, update backup, and removal must be tested on a disposable Windows host using the intended WSL-owning user.
5. The unsigned-source distribution decision must be reaffirmed before public release; Authenticode signing is not implemented.
6. Repository rules, branch protection, Actions pinning policy, and private vulnerability-reporting settings remain outside source-level verification.
7. One explicitly authorized disposable prerelease is needed to prove real release assets, checksum consumption, overwrite refusal, download/extraction behavior, and the user-facing execution-policy instructions.

## Deferred work

- Evaluate GitHub artifact attestations for all downloadable verification assets once a real prerelease is authorized and consumer verification can be exercised end to end.
- Decide whether a future signed PowerShell/module distribution is warranted; do not imply Authenticode trust before certificate ownership and key handling are designed.
- Add explicit automated rollback only after partial task-update recovery semantics are designed and tested.

## Reconsideration triggers

Reprocess this repository only when one or more of the following changes:

- draft branch or stacked base head;
- exact-head CI result;
- runtime event/cursor/reset/deduplication evidence;
- installer, updater, task, or uninstall behavior;
- signing or unsigned-source policy;
- public capability, security, support, or installation claims;
- release workflow authority or dependency/advisory state;
- repository administrative settings;
- explicit steward instruction.

## Next action

Inspect CI for the workflow-and-ledger head. If it passes, skip ordinary source reprocessing and move to the disposable Windows runtime fixture and task-registration evidence. Keep the repository on `HOLD` until stacked integration and a separately authorized prerelease validate the real public distribution path.