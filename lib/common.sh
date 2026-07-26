#!/usr/bin/env bash
# Shared helpers for claude-handoff-guard.
# Sourced by every hook script. Loads user config, then fills in defaults.

GUARD_HOME="${CLAUDE_HANDOFF_HOME:-$HOME/.claude/handoff-guard}"
[ -f "$GUARD_HOME/config.sh" ] && . "$GUARD_HOME/config.sh"

# ---- Defaults (only applied if config.sh didn't set them) ----
: "${THRESHOLD_PCT:=70}"          # start writing the handoff at this % of the larger signal
: "${CONTEXT_LIMIT:=200000}"      # context-window size in tokens (200k std, 1000000 = 1M beta)
: "${ENABLE_USAGE_CHECK:=true}"   # also watch the rolling usage window via ccusage
: "${BLOCK_TOKEN_LIMIT:=19000000}" # rough token budget for one 5h block (ESTIMATE — tune it)
: "${USAGE_CACHE_TTL:=90}"        # seconds to cache the (slow) ccusage lookup
: "${GEN_MODEL:=claude-opus-4-6}"  # model used to write the handoff (see README: Haiku is cheaper)
: "${REGEN_DELTA_TOKENS:=15000}"  # debounce: only regenerate after context grows this much
: "${HANDOFF_FILE:=HANDOFF.md}"   # file written into the project cwd
: "${STATE_DIR:=${TMPDIR:-/tmp}/claude-handoff-guard}"

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s [handoff-guard] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
    >> "$STATE_DIR/guard.log" 2>/dev/null || true
}

# Integer percentage a/b, floor. Safe when b<=0.
pct_of() {
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0<=0) print 0; else printf "%d", (a*100)/b }'
}

# Effective context tokens from the last assistant message in a transcript.
context_tokens() {
  local t="$1" u
  [ -n "$t" ] && [ -f "$t" ] || { echo 0; return; }
  u=$(tail -n 4000 "$t" 2>/dev/null \
      | jq -c 'select(.type=="assistant") | .message.usage // empty' 2>/dev/null \
      | tail -n1)
  [ -z "$u" ] && { echo 0; return; }
  printf '%s' "$u" | jq '((.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0)+(.output_tokens//0))' 2>/dev/null || echo 0
}

# Tokens used in the current rolling usage block (via ccusage), cached briefly.
# NOTE: ccusage is a community tool; if its JSON shape changes, adjust the jq below.
usage_tokens() {
  [ "$ENABLE_USAGE_CHECK" = "true" ] || { echo 0; return; }
  command -v npx >/dev/null 2>&1 || { echo 0; return; }
  local cache="$STATE_DIR/usage_tokens.cache" now mtime age json tok
  now=$(date +%s)
  if [ -f "$cache" ]; then
    mtime=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [ "$age" -lt "$USAGE_CACHE_TTL" ]; then cat "$cache"; return; fi
  fi
  json=$(npx -y ccusage@latest blocks --active --json 2>/dev/null)
  tok=$(printf '%s' "$json" | jq '
      ( .blocks // [] ) as $b
      | ( ( [ $b[] | select(.isActive==true) ] | .[0] )
          // ( [ $b[] | select(.isGap!=true) ] | last )
          // {} )
      | ( .totalTokens
          // .tokenCounts.total
          // (( .tokenCounts.inputTokens // 0 ) + ( .tokenCounts.outputTokens // 0 ))
          // 0 )
    ' 2>/dev/null)
  [ -z "$tok" ] && tok=0
  printf '%s' "$tok" > "$cache" 2>/dev/null || true
  printf '%s' "$tok"
}
