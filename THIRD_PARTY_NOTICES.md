# Third-Party Notices

Pleiades-owned source in this repository is MIT licensed.

The source release does not bundle Windows, PowerShell, WSL, systemd, PHP, a web server, the Pleiades Linux runtime, a container root, event records, credentials, or encrypted snapshot data.

## Microsoft Windows and Task Scheduler

The collectors use Windows event-log, networking, filesystem, and Task Scheduler interfaces supplied by the host operating system. Windows licensing, support, privacy, and platform policies apply independently.

## PowerShell

The Windows scripts require PowerShell 7 (`pwsh`). PowerShell is not bundled in the source release and remains governed by its own license and distribution channel.

The release scripts are unsigned source unless a later separately documented Authenticode process is introduced. Release checksums are integrity receipts and are not Authenticode signatures.

## WSL and Linux tools

The supervisor uses host-provided `wsl.exe` and expects a separately installed Linux distribution with systemd plus the reviewed `pleiades-container.service`. WSL, the Linux distribution, systemd, `machinectl`, and the Pleiades container substrate retain their own licenses, notices, and support boundaries.

## PHP and web server

The read-only Command Deck is PHP source. PHP and the authenticated intranet web server are not bundled or configured here. Their licenses, modules, security settings, logs, and privacy behavior apply independently.

## GitHub Actions

Repository workflows use GitHub Actions and hosted runners. Action licenses and GitHub-hosted execution terms apply independently.

## Downstream distribution

A downstream installer, signed package, web appliance, WSL image, or bundled runtime can create additional license, notice, privacy, source-availability, trademark, and platform-policy obligations. Review the actual downstream artifact rather than relying on this notice as a legal conclusion.
