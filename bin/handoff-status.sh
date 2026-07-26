#!/usr/bin/env bash
# Status-line command: prints a "Handoff: true/false" ticker.
# Reads the per-session status file that handoff-monitor.sh refreshes each turn
# (INPLAY|MAXPCT). "true" once the larger signal has crossed THRESHOLD_PCT and the
# handoff is being maintained; "false" (dimmed) otherwise.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

input=$(cat 2>/dev/null || true)
session=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)

inplay="false"; pct=""
statef="$STATE_DIR/status_${session}"
[ -f "$statef" ] && IFS='|' read -r inplay pct < "$statef" 2>/dev/null

GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
if [ "$inplay" = "true" ]; then
  printf '%sHandoff: true%s' "$GREEN" "$RESET"
else
  printf '%sHandoff: false%s' "$DIM" "$RESET"
fi
[ -n "$pct" ] && printf ' %s(%s%%)%s' "$DIM" "$pct" "$RESET"
