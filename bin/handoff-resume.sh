#!/usr/bin/env bash
# SessionStart hook: if a HANDOFF.md exists in the project, inject it as context so a
# fresh/resumed session picks up where the last one left off.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
hf="$cwd/$HANDOFF_FILE"
[ -f "$hf" ] || exit 0

content=$(cat "$hf" 2>/dev/null)
[ -n "$content" ] || exit 0

jq -n --arg c "A handoff document from a previous session exists (${HANDOFF_FILE}). Use it to resume this work without replaying history:

${content}" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
