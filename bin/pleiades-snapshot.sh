#!/usr/bin/env bash
# Emit a schema-valid JSON status snapshot for the Windows Command Deck.
# Runs on the WSL/Linux host and queries the registered nspawn machine through
# systemd-run. No PID-namespace guessing and no hand-built JSON escaping.

set -euo pipefail

MACHINE="${PLEIADES_MACHINE:-pleiades}"
TMP="$(mktemp -d /tmp/pleiades-snapshot.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

emit_down() {
    python3 - <<'PY'
import json, time
print(json.dumps({
    "schema": "pleiades.status/v1",
    "container": "down",
    "timestamp": int(time.time()),
    "ledger": {"state": "UNKNOWN", "records": 0},
    "agents": [],
    "events": [],
}, separators=(",", ":")))
PY
}

for command in machinectl systemd-run python3; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "pleiades-snapshot: required command not found: $command" >&2
        exit 1
    }
done

state="$(machinectl show "$MACHINE" -p State --value 2>/dev/null || true)"
case "$state" in
    running|degraded) ;;
    *) emit_down; exit 0 ;;
esac

run_guest() {
    systemd-run --quiet --pipe --wait --collect -M "$MACHINE" -- "$@"
}

set +e
verify_output="$(run_guest /usr/local/bin/nexus-verify 2>&1)"
verify_rc=$?
set -e
printf '%s\n' "$verify_output" > "$TMP/verify.txt"

case "$verify_output" in
    *'chain intact'*|*'VALID'*) ledger_state=VALID ;;
    *'EMPTY'*)                 ledger_state=EMPTY ;;
    *'MISSING'*)               ledger_state=MISSING ;;
    *'TAMPER'*)                ledger_state=TAMPERED ;;
    *)
        if [[ "$verify_rc" -eq 0 ]]; then ledger_state=VALID; else ledger_state=ERROR; fi
        ;;
esac

run_guest /bin/bash -lc '
  shopt -s nullglob
  for f in /run/pleiades/state/*.json; do
    cat -- "$f"
    printf "\n"
  done
' > "$TMP/agents.jsonl" 2>/dev/null || true

run_guest /bin/bash -lc '
  ledger=/var/lib/maia/nexus/ledger
  [ -f "$ledger" ] || exit 0
  tail -n 18 -- "$ledger"
' > "$TMP/events.ledger" 2>/dev/null || true

records="$(run_guest /bin/bash -lc 'ledger=/var/lib/maia/nexus/ledger; [ -f "$ledger" ] && wc -l < "$ledger" || printf 0' 2>/dev/null | tail -n 1)"
[[ "$records" =~ ^[0-9]+$ ]] || records=0

python3 - "$state" "$ledger_state" "$records" "$TMP/agents.jsonl" "$TMP/events.ledger" <<'PY'
import base64
import binascii
import json
import sys
import time

container_state, ledger_state, records, agents_path, events_path = sys.argv[1:]

agents = []
with open(agents_path, "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            agents.append({"agent": "invalid-status-record", "status": "failed"})
            continue
        if isinstance(value, dict):
            agents.append(value)

agents.sort(key=lambda item: str(item.get("agent", "")))

events = []
with open(events_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        fields = raw.rstrip("\n").split("|")
        if len(fields) != 6:
            continue
        seq, timestamp, _prev, payload_b64, digest, _signature = fields
        try:
            payload = base64.b64decode(payload_b64, validate=True).decode("utf-8", "replace")
            events.append({
                "seq": int(seq),
                "timestamp": int(timestamp),
                "digest": digest,
                "event": payload[:2048],
            })
        except (ValueError, binascii.Error):
            continue

snapshot = {
    "schema": "pleiades.status/v1",
    "container": container_state,
    "timestamp": int(time.time()),
    "ledger": {"state": ledger_state, "records": int(records)},
    "agents": agents,
    "events": events,
}
print(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
PY
