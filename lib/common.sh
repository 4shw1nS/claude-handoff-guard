#!/usr/bin/env bash
# Shared helpers for claude-handoff-guard.
# Sourced by every hook script. Loads user config, then fills in defaults.

GUARD_HOME="${CLAUDE_HANDOFF_HOME:-$HOME/.claude/handoff-guard}"

# config.sh uses plain assignments (THRESHOLD_PCT=70), so sourcing it would clobber any
# value passed in the environment. Snapshot the environment first and restore it after, so
# precedence is: environment > config.sh > built-in defaults. Without this, overrides like
# `HANDOFF_FILE=/tmp/x.md handoff-gen.sh` silently wrote to the configured path instead.
_HG_VARS="THRESHOLD_PCT CONTEXT_LIMIT ENABLE_USAGE_CHECK BLOCK_TOKEN_LIMIT USAGE_CACHE_TTL
          GEN_MODEL REGEN_DELTA_TOKENS HANDOFF_FILE GEN_TIMEOUT_SECS MIN_HANDOFF_BYTES
          GEN_MAX_TURNS KEEP_BACKUP RETRY_COOLDOWN_SECS STATE_DIR"
for _v in $_HG_VARS; do
  [ -n "${!_v+x}" ] && eval "_HG_ENV_${_v}=\${${_v}}"
done
[ -f "$GUARD_HOME/config.sh" ] && . "$GUARD_HOME/config.sh"
for _v in $_HG_VARS; do
  _e="_HG_ENV_${_v}"
  [ -n "${!_e+x}" ] && eval "${_v}=\${${_e}}"
  unset "$_e"
done
unset _HG_VARS _v _e

# ---- Defaults (only applied if config.sh didn't set them) ----
: "${THRESHOLD_PCT:=70}"          # start writing the handoff at this % of the larger signal
: "${CONTEXT_LIMIT:=200000}"      # context-window size in tokens (200k std, 1000000 = 1M beta)
: "${ENABLE_USAGE_CHECK:=true}"   # also watch the rolling usage window via ccusage
: "${BLOCK_TOKEN_LIMIT:=19000000}" # rough token budget for one 5h block (ESTIMATE — tune it)
: "${USAGE_CACHE_TTL:=90}"        # seconds to cache the (slow) ccusage lookup
: "${GEN_MODEL:=claude-opus-4-6}"  # model used to write the handoff (see README: Haiku is cheaper)
: "${REGEN_DELTA_TOKENS:=15000}"  # debounce: only regenerate after context grows this much
: "${HANDOFF_FILE:=HANDOFF.md}"   # file written into the project cwd
: "${GEN_TIMEOUT_SECS:=240}"      # kill a generation that hangs longer than this
: "${MIN_HANDOFF_BYTES:=300}"     # shorter than this => treat as a failed generation
: "${GEN_MAX_TURNS:=3}"           # headroom; the generator runs with tools disabled anyway
: "${KEEP_BACKUP:=true}"          # keep the previous good handoff as HANDOFF.md.bak
: "${RETRY_COOLDOWN_SECS:=120}"   # min seconds between generation attempts for a session

# State lives under the guard home, NOT $TMPDIR: macOS reaps /var/folders periodically,
# which silently wiped the debounce markers and the log between sessions.
: "${STATE_DIR:=$GUARD_HOME/state}"

mkdir -p "$STATE_DIR" 2>/dev/null || true

log() {
  printf '%s [handoff-guard] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
    >> "$STATE_DIR/guard.log" 2>/dev/null || true
}

# ---- Re-entrancy guard -------------------------------------------------------
# The generator shells out to `claude -p`. That child is a full Claude Code run, so it
# fires this same set of user hooks (Stop -> monitor -> gen -> claude -p -> ...) unless
# stopped. The child is launched with --safe-mode (hooks off) AND with this variable
# exported; either alone breaks the recursion, and we want both.
guard_is_child() { [ "${HANDOFF_GUARD_CHILD:-0}" = "1" ]; }

# Integer percentage a/b, floor. Safe when b<=0.
pct_of() {
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0<=0) print 0; else printf "%d", (a*100)/b }'
}

# "76.4" -> "76"; anything non-numeric -> "" (so callers can test with -n).
to_int() {
  local v="${1:-}"
  v="${v%%.*}"
  case "$v" in ''|null|*[!0-9]*) printf '' ;; *) printf '%s' "$v" ;; esac
}

# ---- Authoritative signals ---------------------------------------------------
# Claude Code hands the STATUS LINE the real numbers:
#   .context_window.used_percentage         — true context%, whatever the window size
#   .rate_limits.five_hour.used_percentage  — true 5-hour limit%
#   .rate_limits.seven_day.used_percentage  — true weekly limit%
# Hooks do not receive these, so handoff-status.sh records them here on every render and
# handoff-monitor.sh reads them back. This replaces two guesses: CONTEXT_LIMIT (wrong on a
# 1M-context session) and BLOCK_TOKEN_LIMIT (a hand-tuned stand-in for an unpublished cap).
: "${SIGNALS_MAX_AGE_SECS:=900}"   # ignore recorded signals older than this

# read_signals <session> -> echoes "ctx|five_hour|seven_day", empty fields when unknown.
read_signals() {
  local f="$STATE_DIR/signals_$1" now mtime
  [ -f "$f" ] || return 1
  now=$(date +%s)
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  [ "$(( now - mtime ))" -le "$SIGNALS_MAX_AGE_SECS" ] || return 1
  cut -d'|' -f1-3 < "$f"
}

# write_signals <session> <stdin-json> — called from the status line.
write_signals() {
  local session="$1" json="$2" c h d
  c=$(to_int "$(printf '%s' "$json" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)")
  h=$(to_int "$(printf '%s' "$json" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)")
  d=$(to_int "$(printf '%s' "$json" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)")
  [ -n "$c$h$d" ] || return 1
  printf '%s|%s|%s|%s' "$c" "$h" "$d" "$(date +%s)" > "$STATE_DIR/signals_${session}" 2>/dev/null || true
}

# Effective context tokens from a transcript.
# Uses the most recent assistant record reporting a NON-ZERO prompt size: the final record
# is routinely a zero-usage stub (stream end, hook-injected message, aborted turn), and
# reading it verbatim reported ctx=0 and skipped the threshold check entirely.
# Sidechain (sub-agent) records are excluded — their usage is not the main conversation.
context_tokens() {
  local t="$1" v
  [ -n "$t" ] && [ -f "$t" ] || { echo 0; return; }
  v=$(tail -n 4000 "$t" 2>/dev/null | jq -r '
        select(.type=="assistant")
        | select((.isSidechain // false) | not)
        | (.message.usage // empty)
        | ((.input_tokens // 0)
           + (.cache_read_input_tokens // 0)
           + (.cache_creation_input_tokens // 0))
        | select(. > 0)
      ' 2>/dev/null | tail -n1)
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
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
  case "$tok" in
    ''|*[!0-9]*) tok=0 ;;
  esac
  printf '%s' "$tok" > "$cache" 2>/dev/null || true
  printf '%s' "$tok"
}

# ---- Handoff validation ------------------------------------------------------
# A handoff is only usable if it actually looks like the document we asked for.
# Without this check the CLI's own error text ("Error: Reached max turns (1)") was
# written straight into HANDOFF.md and then injected into the next session as context.
handoff_is_valid() {
  local f="$1" n
  [ -f "$f" ] && [ -s "$f" ] || return 1
  n=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge "$MIN_HANDOFF_BYTES" ] || return 1
  # CLI / runtime error text, however it arrives.
  grep -qiE '^[[:space:]]*(Error|Execution error|Credit balance|Invalid API key)[[:space:]]*:' "$f" && return 1
  # Must carry the document shape we asked the model for.
  grep -q '^# '  "$f" || return 1
  grep -q '^## ' "$f" || return 1
  return 0
}

# Record the outcome of the last generation so the status line can surface it.
set_gen_status() {  # set_gen_status <session> <ok|fail> <detail>
  printf '%s|%s' "$2" "${3:-}" > "$STATE_DIR/gen_status_$1" 2>/dev/null || true
}
