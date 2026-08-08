#!/usr/bin/env bash
# Generate a handoff for the current project RIGHT NOW, on demand.
#
#   handoff-now.sh                 # newest transcript for $PWD
#   handoff-now.sh <transcript>    # a specific transcript
#
# Bypasses every automatic gate: AUTO_GENERATE, GEN_CEILING_PCT, the threshold, the
# debounce and the cooldown. This is the escape hatch for running with AUTO_GENERATE=false
# — the guard then costs nothing until you ask for a handoff.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

cwd="$PWD"
transcript="${1:-}"

if [ -z "$transcript" ]; then
  slug=$(printf '%s' "$cwd" | sed 's#[/._]#-#g')
  pdir="$HOME/.claude/projects/$slug"
  [ -d "$pdir" ] || { echo "error: no transcripts for this project ($pdir)"; exit 1; }
  transcript=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -n1)
fi
[ -n "$transcript" ] && [ -f "$transcript" ] || { echo "error: no transcript found"; exit 1; }

case "$HANDOFF_FILE" in
  /*) handoff_path="$HANDOFF_FILE" ;;
  *)  handoff_path="$cwd/$HANDOFF_FILE" ;;
esac

echo "Generating $handoff_path"
echo "  from  : $(basename "$transcript")"
echo "  model : $GEN_MODEL"

# A manual run must not be blocked by, or interfere with, an automatic one: its own lock,
# and MANUAL_GEN=1 to bypass the spend gate.
lock="$STATE_DIR/gen_manual.lock"
rmdir "$lock" 2>/dev/null || true
mkdir "$lock" 2>/dev/null || true

MANUAL_GEN=1 MAX_PCT="on demand" GEN_SESSION="manual" GEN_LOCK="$lock" \
  "$DIR/handoff-gen.sh" "$transcript" "$cwd"

if handoff_is_valid "$handoff_path"; then
  echo "Done — $(wc -c < "$handoff_path" | tr -d ' ') bytes"
  head -n1 "$handoff_path"
  exit 0
fi
echo "Failed. Last log lines:"
tail -n 3 "$STATE_DIR/guard.log" 2>/dev/null | sed 's/^/  /'
exit 1
