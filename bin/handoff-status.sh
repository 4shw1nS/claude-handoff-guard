#!/usr/bin/env bash
# Status-line command. Does three things, in this order:
#
#   1. RECORDS the real signals. Claude Code publishes context% and the rate-limit
#      percentages to the status line only — hooks never see them.
#   2. PRINTS the ticker from those live signals ("Handoff: true/false (max%)").
#   3. TRIGGERS generation when the threshold is crossed.
#
# (3) matters because the Stop hook only fires after an assistant turn. A session that
# crosses the threshold and then sits idle would never get a handoff written — exactly the
# "about to hit the rate limit" case this tool exists for. The status line keeps rendering
# while idle, so it can close that gap. The expensive transcript read is gated by
# STATUS_CHECK_INTERVAL_SECS, and the generator is spawned detached so rendering never blocks.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

guard_is_child && exit 0

: "${STATUSLINE_TRIGGER:=true}"          # set false to leave generation to the Stop hook
: "${STATUS_CHECK_INTERVAL_SECS:=60}"    # min seconds between transcript reads from here

input=$(cat 2>/dev/null || true)
session=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)

# ---- 1. Record the authoritative signals -------------------------------------
write_signals "$session" "$input" || true

ctx_pct=$(to_int "$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)")
h5_pct=$(to_int "$(printf '%s' "$input"  | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)")
d7_pct=$(to_int "$(printf '%s' "$input"  | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)")

# ---- 2. Decide what to show --------------------------------------------------
# Prefer the live numbers we just read. Only fall back to the monitor's status file when
# this payload carries no percentages — that file is refreshed on assistant turns, so on an
# idle session it goes stale and used to show a verdict tens of minutes old.
pct=""; inplay="false"
if [ -n "$ctx_pct$h5_pct$d7_pct" ]; then
  pct=0
  for v in "${ctx_pct:-0}" "${h5_pct:-0}" "${d7_pct:-0}"; do
    [ "$v" -gt "$pct" ] && pct=$v
  done
  [ "$pct" -ge "$THRESHOLD_PCT" ] && inplay="true"
else
  statef="$STATE_DIR/status_${session}"
  [ -f "$statef" ] && IFS='|' read -r inplay pct < "$statef" 2>/dev/null
fi

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

# ---- 3. Trigger generation if the Stop hook can't ----------------------------
[ "$STATUSLINE_TRIGGER" = "true" ] || exit 0
[ "$inplay" = "true" ] || exit 0
check_due "$session" "$STATUS_CHECK_INTERVAL_SECS" || exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] && [ -n "$cwd" ] || exit 0

case "$HANDOFF_FILE" in
  /*) handoff_path="$HANDOFF_FILE" ;;
  *)  handoff_path="$cwd/$HANDOFF_FILE" ;;
esac

ctx=$(context_tokens "$transcript")
if reason=$(needs_handoff "$handoff_path" "$session" "$ctx") && acquire_gen_slot "$session"; then
  # Detached in a subshell so the child outlives this render and never blocks it.
  ( MAX_PCT="$pct" CTX_PCT="${ctx_pct:-0}" USE_PCT="${h5_pct:-0}" CTX_TOKENS="$ctx" \
    GEN_SESSION="$session" GEN_LOCK="$GEN_LOCK" \
    nohup "$DIR/handoff-gen.sh" "$transcript" "$cwd" </dev/null >/dev/null 2>&1 & )
  log "statusline triggered handoff-gen (max=${pct}%, reason: ${reason})"
fi
exit 0
