# Pleiades — Windows-side resilience layer (planned, after WSL agents)

Owner's idea (2026-06-27): make the defensive network function **even when WSL is not up**,
by adding Windows-native scripts interconnected with the WSL/container scripts. The Windows
Server DC is always on; WSL may not be. So split the system by availability.

## Architecture split
- **Windows layer (always-on, native):**
  1. **Supervisor** — a Windows Scheduled Task / service that ensures WSL + the nspawn
     container are up; boots them (runs `boot-tmux.sh`) and recovers them if down. This is the
     resilience guarantee that the old WSL-internal heartbeat could not provide.
  2. **Native sensors** — collect real host telemetry the honeypot can't see: Security Event
     Log (4625 failed logon, 4624/4672 logon/privilege, RDP 4778/4779), Windows Firewall drops,
     Defender detections. The DC sees actual attacks against itself, not just port-2222 probes.
  3. **Durable spool** — write collected events as JSONL to e.g. `C:\pleiades\spool\windows-events.jsonl`.
     Retained on Windows so nothing is lost while WSL is down.
- **WSL/container layer (the brain):** Maia (trust root / signing), Nexus (signed ledger),
  Taygete (honeypot), Celaeno (watchdog). Does the signing + forensic sealing.
- **Bridge (one-way: Windows → WSL):** the container bridges `C:` read-only; a `windows_ingest`
  step (folded into Maia's checkpoint, no new timer) reads new spool lines → `nexus_emit` →
  sealed into the tamper-evident ledger. WSL never needs to write Windows. Keeps the existing
  read-only-bridge direction and trust boundary.

## Resilience properties
- Windows always-on ⇒ no blind sensing gaps for host-level attacks.
- WSL down ⇒ events buffer in the Windows spool; Maia seals the backlog on reconnect.
- Windows supervisor auto-recovers WSL/container after reboot/crash/resource pressure.

## Cadence discipline (carries over — see the user's strong preference)
- Windows collector should be **event-driven** (Event Log subscription / WMI event query
  `__InstanceCreationEvent` on the security log) or a **slow** scheduled task — never a tight
  poll loop. Same rule as the WSL side: no fast ticks.

## Sequencing
Do this **after** the WSL agents are all rebuilt (Celaeno → Electra → Alcyone → Merope →
Sterope → Asterope). Then add the Windows supervisor + sensors + bridge ingest.

## Open questions for later
- Run the Windows collector as a Scheduled Task (simplest, survives reboot) vs a real service.
- Event-log volume: filter to security-relevant IDs only; don't seal noise.
- Should the Windows supervisor also verify the ledger (`nexus-verify`) and alert on tamper?
