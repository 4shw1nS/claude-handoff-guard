#!/usr/bin/env bash
# Stop hook: runs after every assistant turn. Cheap gate.
# Reads context% (exact) and usage% (approx). If the larger crosses THRESHOLD_PCT,
# fires the (debounced) generator in the background. Always exits 0 so it never
# blocks the session.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

input=$(cat 2>/dev/null || true)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // "default"' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

ctx=$(context_tokens "$transcript")
ctx_pct=$(pct_of "$ctx" "$CONTEXT_LIMIT")
use=$(usage_tokens)
use_pct=$(pct_of "$use" "$BLOCK_TOKEN_LIMIT")

max_pct=$ctx_pct
[ "$use_pct" -gt "$max_pct" ] && max_pct=$use_pct
log "ctx=${ctx}(${ctx_pct}%) usage=${use}(${use_pct}%) max=${max_pct}% session=${session}"

# Publish state for the status-line ticker (INPLAY|MAXPCT), refreshed every turn.
inplay=false
[ "$max_pct" -ge "$THRESHOLD_PCT" ] && inplay=true
printf '%s|%s' "$inplay" "$max_pct" > "$STATE_DIR/status_${session}" 2>/dev/null || true

if [ "$max_pct" -ge "$THRESHOLD_PCT" ]; then
  statef="$STATE_DIR/last_gen_${session}.tok"
  last=0; [ -f "$statef" ] && last=$(cat "$statef" 2>/dev/null || echo 0)
  if [ ! -f "$statef" ] || [ $(( ctx - last )) -ge "$REGEN_DELTA_TOKENS" ]; then
    printf '%s' "$ctx" > "$statef"
    MAX_PCT="$max_pct" CTX_PCT="$ctx_pct" USE_PCT="$use_pct" \
      "$DIR/handoff-gen.sh" "$transcript" "$cwd" >/dev/null 2>&1 &
    log "triggered handoff-gen (max=${max_pct}%)"
  fi
fi
exit 0
