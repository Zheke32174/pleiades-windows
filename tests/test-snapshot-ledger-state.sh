#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SNAPSHOT="$ROOT/bin/pleiades-snapshot.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat > "$FAKE_BIN/machinectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'running\n'
SH

cat > "$FAKE_BIN/systemd-run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
while (($#)) && [[ "$1" != -- ]]; do shift; done
[[ "${1:-}" == -- ]] || exit 90
shift
command="${1:-}"
shift || true
case "$command" in
  /usr/local/bin/nexus-verify)
    count=0
    [[ ! -f "$VERIFY_COUNTER" ]] || count="$(cat "$VERIFY_COUNTER")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$VERIFY_COUNTER"
    if [[ "$count" -eq 1 ]]; then
      cat "$VERIFY_BEFORE_FILE"
      exit "$VERIFY_BEFORE_RC"
    fi
    cat "$VERIFY_AFTER_FILE"
    exit "$VERIFY_AFTER_RC"
    ;;
  /bin/bash)
    joined="$*"
    case "$joined" in
      *'/run/pleiades/state/'*) cat "$AGENTS_FILE" ;;
      *'tail -n 18'*) cat "$EVENTS_FILE" ;;
      *'wc -l'*) printf '%s\n' "$LEDGER_RECORDS" ;;
      *) exit 91 ;;
    esac
    ;;
  *) exit 92 ;;
esac
SH
chmod 700 "$FAKE_BIN/machinectl" "$FAKE_BIN/systemd-run"

: > "$TMP/agents"
: > "$TMP/events"

run_case() {
  local name="$1" before_rc="$2" before_text="$3" after_rc="$4" after_text="$5" records="$6" expected="$7"
  local case_dir="$TMP/$name"
  mkdir -p "$case_dir"
  printf '%s' "$before_text" > "$case_dir/before"
  printf '%s' "$after_text" > "$case_dir/after"
  rm -f "$case_dir/counter"
  env \
    PATH="$FAKE_BIN:$PATH" \
    VERIFY_COUNTER="$case_dir/counter" \
    VERIFY_BEFORE_FILE="$case_dir/before" \
    VERIFY_AFTER_FILE="$case_dir/after" \
    VERIFY_BEFORE_RC="$before_rc" \
    VERIFY_AFTER_RC="$after_rc" \
    AGENTS_FILE="$TMP/agents" \
    EVENTS_FILE="$TMP/events" \
    LEDGER_RECORDS="$records" \
    bash "$SNAPSHOT" > "$case_dir/status.json"
  python3 - "$case_dir/status.json" "$expected" "$records" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["schema"] == "pleiades.status/v1"
assert value["container"] == "running"
assert value["ledger"]["state"] == sys.argv[2], value
assert value["ledger"]["records"] == int(sys.argv[3]), value
PY
}

missing='nexus-verify: no ledger at /var/lib/maia/nexus/ledger (nothing sealed yet)'
empty='nexus-verify: OK — 0 records, chain intact, all signatures valid (head=0000000000000000...)'
valid='nexus-verify: OK — 2 records, chain intact, all signatures valid (head=aaaaaaaaaaaaaaaa...)'
valid_three='nexus-verify: OK — 3 records, chain intact, all signatures valid (head=bbbbbbbbbbbbbbbb...)'
tamper=$'nexus-verify: SIGNATURE INVALID at seq=2\nnexus-verify: TAMPER DETECTED'
ambiguous='nexus-verify: SIGNATURE INVALID at seq=2'

run_case missing 0 "$missing" 0 "$missing" 0 MISSING
run_case empty 0 "$empty" 0 "$empty" 0 EMPTY
run_case valid 0 "$valid" 0 "$valid" 2 VALID
run_case tamper 1 "$tamper" 1 "$tamper" 2 TAMPERED
run_case ambiguous-valid-substring 1 "$ambiguous" 1 "$ambiguous" 2 ERROR
run_case verifier-drift 0 "$valid" 0 "$valid_three" 2 ERROR
run_case count-mismatch 0 "$valid" 0 "$valid" 3 ERROR

printf 'exact ledger-verifier classification fixtures passed\n'
