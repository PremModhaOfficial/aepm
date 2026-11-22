#!/usr/bin/env bash
# stop.sh — the "stop"/"pause" switch, as code. Sets mode: paused and prints the
# workers that were in flight so the Router can task_cancel each by taskId.
#
#   stop.sh            pause + list in-flight tasks
#   stop.sh resume     mode: auto
#   stop.sh status
set -euo pipefail
FACTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$FACTORY/config.yml"
# "|" is the delimiter: the replacement text itself contains "/"
setmode() { sed -i "s|^mode: .*|mode: $1|" "$CFG"; }

case "${1:-pause}" in
  pause)
    if [ "$(bash "$FACTORY/scripts/stop.sh" status)" = "paused" ]; then echo "already paused"; exit 0; fi
    setmode paused
    echo "mode: paused"
    echo "in flight (task_cancel each, then t3_thread_send is not needed):"
    found=0
    for t in "$FACTORY"/tickets/T-*.md; do
      [ -f "$t" ] || continue
      live="$(awk 'NR==1{next} /^---$/{exit} {print}' "$t" | sed -n 's/^live_task: *//p' | head -1)"
      if [ -n "$live" ]; then
        echo "  $(basename "$t" .md)  $live"
        found=1
      fi
    done
    [ "$found" = 0 ] && echo "  (none)"
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg d "mode=paused" \
      '{ts:$ts,ticket:"",role:"router",event:"factory-paused",detail:$d}' >>"$FACTORY/ledger.jsonl"
    ;;
  resume) setmode auto; echo "mode: auto" ;;
  status) sed -n 's/^mode: *//p' "$CFG" | head -1 | awk '{print $1}' ;;
  *) echo "usage: stop.sh [pause|resume|status]" >&2; exit 2 ;;
esac
