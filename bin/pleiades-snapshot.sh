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

capture_verifier() {
    local output_path="$1" rc_path="$2" output rc
    set +e
    output="$(run_guest /usr/local/bin/nexus-verify 2>&1)"
    rc=$?
    set -e
    printf '%s' "$output" > "$output_path"
    printf '%s\n' "$rc" > "$rc_path"
}

# The first verifier result establishes the ledger generation observed before
# collection. The second must be byte-identical and report the same exit code.
capture_verifier "$TMP/verify-before.txt" "$TMP/verify-before.rc"

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
printf '%s\n' "$records" > "$TMP/records.txt"

capture_verifier "$TMP/verify-after.txt" "$TMP/verify-after.rc"

python3 - \
  "$state" \
  "$TMP/verify-before.txt" "$TMP/verify-before.rc" \
  "$TMP/verify-after.txt" "$TMP/verify-after.rc" \
  "$TMP/records.txt" "$TMP/agents.jsonl" "$TMP/events.ledger" <<'PY'
import base64
import binascii
import json
import re
import sys
import time
from pathlib import Path

(
    container_state,
    verify_before_path,
    verify_before_rc_path,
    verify_after_path,
    verify_after_rc_path,
    records_path,
    agents_path,
    events_path,
) = sys.argv[1:]

OK_RE = re.compile(
    r"^nexus-verify: OK — ([0-9]+) records, chain intact, all signatures valid "
    r"\(head=[0-9a-f]{16}\.\.\.\)$"
)
MISSING_RE = re.compile(
    r"^nexus-verify: no ledger at .+ \(nothing sealed yet\)$"
)
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


def load_verifier(output_path: str, rc_path: str):
    text = Path(output_path).read_text(encoding="utf-8", errors="strict")
    rc_text = Path(rc_path).read_text(encoding="ascii", errors="strict").strip()
    if not rc_text.isdigit():
        return text, -1
    return text, int(rc_text)


def classify(text: str, rc: int):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    final = lines[-1] if lines else ""
    if rc == 0:
        if MISSING_RE.fullmatch(final):
            return "MISSING", 0
        matched = OK_RE.fullmatch(final)
        if matched:
            count = int(matched.group(1))
            return ("EMPTY" if count == 0 else "VALID"), count
        return "ERROR", None
    if rc == 1 and final == "nexus-verify: TAMPER DETECTED":
        return "TAMPERED", None
    return "ERROR", None


before_text, before_rc = load_verifier(verify_before_path, verify_before_rc_path)
after_text, after_rc = load_verifier(verify_after_path, verify_after_rc_path)
before_state, before_count = classify(before_text, before_rc)
after_state, after_count = classify(after_text, after_rc)
records_text = Path(records_path).read_text(encoding="ascii", errors="strict").strip()
records = int(records_text) if records_text.isdigit() else 0

stable = before_rc == after_rc and before_text == after_text
if not stable or before_state != after_state or before_count != after_count:
    ledger_state = "ERROR"
elif before_state in {"VALID", "EMPTY", "MISSING"} and before_count != records:
    ledger_state = "ERROR"
else:
    ledger_state = before_state

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
last_sequence = 0
with open(events_path, "r", encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        fields = raw.rstrip("\n").split("|")
        if len(fields) != 6:
            continue
        seq, timestamp, _prev, payload_b64, digest, _signature = fields
        try:
            sequence = int(seq)
            event_timestamp = int(timestamp)
            if sequence <= last_sequence or event_timestamp < 1 or not DIGEST_RE.fullmatch(digest):
                continue
            payload = base64.b64decode(payload_b64, validate=True).decode("utf-8", "replace")
        except (ValueError, binascii.Error):
            continue
        events.append({
            "seq": sequence,
            "timestamp": event_timestamp,
            "digest": digest,
            "event": payload[:2048],
        })
        last_sequence = sequence

snapshot = {
    "schema": "pleiades.status/v1",
    "container": container_state,
    "timestamp": int(time.time()),
    "ledger": {"state": ledger_state, "records": records},
    "agents": agents,
    "events": events,
}
print(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")))
PY
