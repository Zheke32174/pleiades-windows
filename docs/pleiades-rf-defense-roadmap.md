# Pleiades — RF / wireless MITM defense (stingray, deauth, evil twin)

The threat: dirtboxes/stingrays (cell-site simulators), evil twins (rogue APs), deauth
floods, and other MITM. Few native defenses exist, so we stack two things: **detection**
(see the attack) and **hardening** (make the attack worthless even if undetected). The
second matters most — a MITM that can't read or alter your traffic is just noise.

This box is an Ethernet-only server with no WiFi/cellular radio, so it can't *hear* RF
directly — but it can (a) detect the network-layer *effect* of any MITM, and (b) anchor
the hardening. RF sensing needs cheap USB hardware or the phone.

---

## Layer 1 — HARDENING (do these now; they defeat MITM regardless of detection)

A correctly-encrypted, authenticated path makes link-layer MITM (evil twin, stingray,
ARP spoof) unable to read or tamper. We already have most of this.

- **Tailscale everywhere (already deployed).** WireGuard is end-to-end encrypted + mutually
  authenticated. An attacker who MITMs the local link or cellular sees only ciphertext and
  cannot inject. Route sensitive traffic over the tailnet. This is the single biggest win.
- **DNS hardening.** DNS already pinned to the box's own resolver (127.0.0.1). Add **DoH/DoT
  upstream** so a network DNS hijack can't tamper with what the resolver fetches.
- **Static ARP for the gateway.** Pin the gateway IP to its real MAC
  (`netsh interface ip add neighbors`) so ARP-spoof can't silently redirect the box.
  Netwatch already alerts if it changes; static ARP makes the change fail.
- **Phone: disable 2G.** Most cheap/illegal IMSI-catchers force a **2G downgrade** (no mutual
  auth, weak/no crypto). Android dev settings / "2G off" defeats them outright. Use 4G/5G-only
  + a VPN/Tailscale on cellular.
- **WiFi (for the user's wireless devices): WPA3 + PMF (802.11w).** Protected Management Frames
  make **deauth/disassoc forgery fail** — the deauth attack simply stops working. Evil-twin
  resistance improves with WPA3-SAE.

## Layer 2 — DETECTION already built (no hardware)

- **`pleiades-netwatch`** (Windows, every 5 min) → signed ledger + threat score:
  - `gateway_mac_change` (ARP spoof / rogue gateway / MITM relay) — weight 10 (near-certain MITM)
  - `arp_conflict` (one MAC claiming multiple IPs — spoof signature) — weight 8
  - `dns_change` (DNS hijack) — weight 5
  Sticky baseline (`C:\pleiades\state\netwatch-baseline.json`); re-bless by deleting it.

## Layer 3 — RF DETECTION (needs ~$60 of USB hardware; WSL reaches it via `usbipd-win`)

USB devices can be passed into WSL2 with **usbipd-win** (`winget install usbipd`), then a
Linux sensor in WSL/the container reads them and emits to the bridge spool → `rf_event` →
ledger → deck → score (same pipeline as netwatch).

| Hardware (~cost) | Detects | How |
|---|---|---|
| **Monitor-mode WiFi adapter** (Alfa AWUS036ACM, ~$30) | **deauth floods**, **evil twins** | Capture 802.11 mgmt frames (scapy/Kismet). Deauth: count deauth/disassoc rate — a flood is an attack. Evil twin: same SSID with a BSSID/channel not in the trusted set, or a "karma" AP answering all probes; beacon timestamp/sequence anomalies. |
| **RTL-SDR v4** (~$35) | **stingray / IMSI-catcher** | Scan cell bands (gr-gsm / a cell monitor). SnoopSnitch-style heuristics: forced 2G downgrade, cell with no neighbor list, abnormal LAC/TAC churn, a strong cell that appears then vanishes, missing encryption (A5/0), silent-SMS/paging anomalies. |
| **The phone** (already have one) | **stingray + WiFi** | SnoopSnitch (rooted Qualcomm Android) for IMSI-catchers; WiFi scan for evil twins. The old `pleiades-phone` node can forward findings to the Nexus over the tailnet. |

## Event taxonomy (when built)
`rf_event kind={deauth_flood|evil_twin|imsi_catcher|rogue_ap|2g_downgrade} severity=...`
→ Sterope weights: imsi_catcher/evil_twin high, deauth_flood med-high.

## Recommended order
1. Apply Layer-1 hardening now (static ARP, DoH, disable 2G, WPA3/PMF) — biggest risk reduction.
2. Netwatch (Layer 2) is live.
3. Buy the RTL-SDR + monitor-mode adapter (~$60); pass via usbipd; build the Layer-3 sensors.
4. Wire the phone as a roaming RF sensor over the tailnet.
