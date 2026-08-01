#!/usr/bin/env bash
# Status-line command: prints a "Handoff: true/false" ticker.
# Reads the per-session status file that handoff-monitor.sh refreshes each turn
# (INPLAY|MAXPCT). "true" once the larger signal has crossed THRESHOLD_PCT and the
# handoff is being maintained; "false" (dimmed) otherwise. If the last generation
# failed it says so in red — silence used to be indistinguishable from success.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

input=$(cat 2>/dev/null || true)
session=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)

# The status line is the only place Claude Code publishes the true context% and rate-limit%
# — hooks never see them. Record them here so handoff-monitor.sh can read the real numbers
# instead of estimating from token budgets. This is why the ticker must stay wired up.
write_signals "$session" "$input" || true

inplay="false"; pct=""
statef="$STATE_DIR/status_${session}"
[ -f "$statef" ] && IFS='|' read -r inplay pct < "$statef" 2>/dev/null

gen_state=""; gen_detail=""
genf="$STATE_DIR/gen_status_${session}"
[ -f "$genf" ] && IFS='|' read -r gen_state gen_detail < "$genf" 2>/dev/null

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
if [ "$gen_state" = "fail" ]; then
  printf '%sHandoff: FAILED%s' "$RED" "$RESET"
elif [ "$inplay" = "true" ]; then
  printf '%sHandoff: true%s' "$GREEN" "$RESET"
  [ "$gen_state" = "ok" ] && printf ' %s@%s%s' "$DIM" "$gen_detail" "$RESET"
else
  printf '%sHandoff: false%s' "$DIM" "$RESET"
fi
[ -n "$pct" ] && printf ' %s(%s%%)%s' "$DIM" "$pct" "$RESET"
