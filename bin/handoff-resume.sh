#!/usr/bin/env bash
# SessionStart hook: if a VALID HANDOFF.md exists in the project, inject it as context so a
# fresh/resumed session picks up where the last one left off.
# Validation matters here: a corrupted handoff (an older version wrote the CLI's own
# "Error: Reached max turns (1)" text into it) would otherwise be injected verbatim as
# the new session's starting context.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

guard_is_child && exit 0

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

case "$HANDOFF_FILE" in
  /*) hf="$HANDOFF_FILE" ;;
  *)  hf="$cwd/$HANDOFF_FILE" ;;
esac

src="$hf"; note=""
if ! handoff_is_valid "$hf"; then
  if handoff_is_valid "${hf}.bak"; then
    src="${hf}.bak"; note=" (recovered from ${HANDOFF_FILE}.bak — the current file was incomplete)"
    log "resume: $hf invalid, injecting ${hf}.bak instead"
  else
    [ -f "$hf" ] && log "resume: $hf failed validation ($(wc -c < "$hf" | tr -d ' ') bytes); not injecting"
    exit 0
  fi
fi

content=$(cat "$src" 2>/dev/null)
[ -n "$content" ] || exit 0

jq -n --arg c "A handoff document from a previous session exists (${HANDOFF_FILE})${note}. Use it to resume this work without replaying history:

${content}" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
