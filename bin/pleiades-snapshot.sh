#!/bin/bash
# Emit a JSON status snapshot of the Pleiades swarm for the Command Deck.
# Read-only: agent statuses + ledger integrity + recent signed events.
set -uo pipefail
HOSTNS=$(readlink /proc/1/ns/pid); CPID=""
for p in $(pgrep -x systemd); do [ "$(readlink /proc/$p/ns/pid 2>/dev/null)" != "$HOSTNS" ] && CPID=$p; done
if [ -z "$CPID" ]; then
  printf '{"container":"down","ts":%s,"verify":"unknown","records":0,"agents":[],"events":[]}\n' "$(date +%s)"
  exit 0
fi
nsenter -t "$CPID" -m -u -i -n -p -- bash -lc '
LEDGER=/var/lib/maia/nexus/ledger
agents=""
for f in /run/pleiades/state/*.json; do [ -f "$f" ] || continue; agents="${agents:+$agents,}$(tr -d "\n" < "$f")"; done
if nexus-verify >/dev/null 2>&1; then verify=ok; else verify=tamper; fi
records=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)
events=""
while IFS="|" read -r seq t prev eb64 hash sig; do
  [ -z "${seq:-}" ] && continue
  ev=$(printf "%s" "$eb64" | openssl base64 -d -A 2>/dev/null | tr -d "\"\\\\" | tr -c "[:print:]" " ")
  events="${events:+$events,}{\"seq\":$seq,\"ts\":$t,\"event\":\"$ev\"}"
done < <(tail -18 "$LEDGER" 2>/dev/null)
printf "{\"container\":\"up\",\"ts\":%s,\"verify\":\"%s\",\"records\":%s,\"agents\":[%s],\"events\":[%s]}\n" "$(date +%s)" "$verify" "$records" "$agents" "$events"
'
