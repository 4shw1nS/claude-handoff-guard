#!/usr/bin/env bash
# Stop hook: runs after every assistant turn. Cheap gate.
# Reads context% (exact) and usage% (approx). If the larger crosses THRESHOLD_PCT,
# fires the (debounced, locked) generator in the background. Always exits 0 so it never
# blocks the session.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

guard_is_child && exit 0   # the generator's own `claude -p` must not re-trigger us

input=$(cat 2>/dev/null || true)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
cd "$cwd" 2>/dev/null || true

# ctx tokens are still needed for the debounce delta, regardless of which signal we trust.
ctx=$(context_tokens "$transcript")

# ---- Signals -----------------------------------------------------------------
# Prefer the real percentages Claude Code publishes (recorded by handoff-status.sh, and
# read straight from the hook payload if a future version starts including them). Only
# fall back to the token-budget estimates when neither is available — those need
# CONTEXT_LIMIT and BLOCK_TOKEN_LIMIT to be calibrated, and when they aren't the guard
# reads the wrong number in both directions (e.g. 68% ctx on a 1M window that is really
# 14%, and 53% on a 5-hour block that is really 76%).
ctx_pct=$(to_int "$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)")
h5_pct=$(to_int "$(printf '%s' "$input"  | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)")
d7_pct=$(to_int "$(printf '%s' "$input"  | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)")
src=""
[ -n "$ctx_pct$h5_pct$d7_pct" ] && src="hook"

if [ -z "$src" ] && sig=$(read_signals "$session"); then
  IFS='|' read -r ctx_pct h5_pct d7_pct <<<"$sig"
  src="statusline"
fi

if [ -z "$ctx_pct" ]; then
  ctx_pct=$(pct_of "$ctx" "$CONTEXT_LIMIT"); src="${src:+$src+}ctx-est"
fi
if [ -z "$h5_pct" ]; then
  use=$(usage_tokens)
  h5_pct=$(pct_of "$use" "$BLOCK_TOKEN_LIMIT"); src="${src:+$src+}ccusage"
fi
: "${d7_pct:=0}"

max_pct=$ctx_pct
[ "$h5_pct" -gt "$max_pct" ] && max_pct=$h5_pct
[ "$d7_pct" -gt "$max_pct" ] && max_pct=$d7_pct
log "ctx=${ctx}tok(${ctx_pct}%) 5h=${h5_pct}% 7d=${d7_pct}% max=${max_pct}% src=${src} session=${session}"

# Publish state for the status-line ticker (INPLAY|MAXPCT), refreshed every turn.
inplay=false
[ "$max_pct" -ge "$THRESHOLD_PCT" ] && inplay=true
printf '%s|%s' "$inplay" "$max_pct" > "$STATE_DIR/status_${session}" 2>/dev/null || true

[ "$inplay" = "true" ] || exit 0
if ! auto_gen_allowed "$max_pct"; then
  [ "$AUTO_GENERATE" = "true" ] && log "above GEN_CEILING_PCT=${GEN_CEILING_PCT}% (max=${max_pct}%) — not generating"
  exit 0
fi

case "$HANDOFF_FILE" in
  /*) handoff_path="$HANDOFF_FILE" ;;
  *)  handoff_path="$cwd/$HANDOFF_FILE" ;;
esac

# ---- Should we generate? (shared with the status-line trigger) ---------------
# A missing or invalid handoff is repaired immediately rather than waiting for the context
# to grow another delta — that includes files a pre-fix version corrupted.
why=$(needs_handoff "$handoff_path" "$session" "$ctx") || exit 0
acquire_gen_slot "$session" || exit 0

MAX_PCT="$max_pct" CTX_PCT="$ctx_pct" USE_PCT="$h5_pct" CTX_TOKENS="$ctx" \
GEN_SESSION="$session" GEN_LOCK="$GEN_LOCK" \
  "$DIR/handoff-gen.sh" "$transcript" "$cwd" >/dev/null 2>&1 &
log "triggered handoff-gen (max=${max_pct}%, reason: ${why})"
exit 0
