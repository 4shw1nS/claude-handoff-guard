#!/usr/bin/env bash
# Generator: writes/updates HANDOFF.md from the recent conversation using $GEN_MODEL.
# Called two ways:
#   1) by handoff-monitor.sh with args:  handoff-gen.sh <transcript> <cwd>
#   2) by the PreCompact hook with the hook JSON on stdin (no args)
# In both cases it always (re)generates — debouncing lives in the monitor.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

transcript=""; cwd=""
if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
  transcript="$1"; cwd="${2:-$PWD}"
else
  input=$(cat 2>/dev/null || true)
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
fi
[ -n "$cwd" ] || cwd="$PWD"
[ -n "$transcript" ] && [ -f "$transcript" ] || { log "gen: no transcript; abort"; exit 0; }
command -v claude >/dev/null 2>&1 || { log "gen: 'claude' not on PATH; abort"; exit 0; }
cd "$cwd" 2>/dev/null || true

max_pct="${MAX_PCT:-?}"

# Pull recent human-readable conversation text out of the JSONL transcript.
convo=$(tail -n 800 "$transcript" 2>/dev/null | jq -r '
  select(.type=="user" or .type=="assistant")
  | (.message.role // .type) as $role
  | (.message.content) as $c
  | ( if ($c|type)=="string" then $c
      elif ($c|type)=="array" then
        ( [ $c[]
            | if .type=="text" then .text
              elif .type=="tool_use" then "[tool: \(.name)]"
              elif .type=="tool_result" then "[tool result]"
              else empty end ] | join("\n") )
      else "" end ) as $t
  | if ($t|length) > 0 then "\($role): \($t)" else empty end
' 2>/dev/null | tail -c 60000)

existing=""
[ -f "$HANDOFF_FILE" ] && existing=$(cat "$HANDOFF_FILE" 2>/dev/null)

read -r -d '' prompt <<EOF || true
You are maintaining a HANDOFF document so a NEW Claude Code session can resume this
work WITHOUT reading the full conversation. Update or rewrite the handoff below using
the recent conversation. Be tight and factual. Preserve still-accurate detail from the
existing handoff; fold in what changed. Output ONLY the markdown document — no preamble.

Use exactly these sections:
# Handoff — <short task title>
_Auto-updated at ~${max_pct}% session usage_
## Current goal
## Status / what's done
## Key decisions & constraints
## Files & locations touched
## Next steps (ordered, actionable)
## Open questions / blockers
## How to resume
<one line telling the next session what to do first>

--- EXISTING HANDOFF (may be empty) ---
${existing}

--- RECENT CONVERSATION (oldest to newest) ---
${convo}
EOF

out=$(printf '%s' "$prompt" | claude -p --model "$GEN_MODEL" --max-turns 1 2>>"$STATE_DIR/guard.log")
if [ -n "$out" ]; then
  printf '%s\n' "$out" > "$HANDOFF_FILE"
  log "wrote ${cwd}/${HANDOFF_FILE} ($(printf '%s' "$out" | wc -c | tr -d ' ') bytes, max=${max_pct}%)"
else
  log "gen: empty output from claude -p"
fi
exit 0
