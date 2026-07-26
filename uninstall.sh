#!/usr/bin/env bash
# Removes the claude-handoff-guard hooks from settings.json. Leaves scripts/config on disk.
set -euo pipefail
DEST="${CLAUDE_HANDOFF_HOME:-$HOME/.claude/handoff-guard}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
command -v jq >/dev/null 2>&1 || { echo "error: jq required"; exit 1; }
[ -f "$SETTINGS" ] || { echo "no settings file at $SETTINGS"; exit 0; }

tmp=$(mktemp)
jq --arg d "$DEST" '
  (if .hooks then
    .hooks |= with_entries(
      .value |= map(select((.hooks[0].command // "") | startswith($d) | not))
    )
    | .hooks |= with_entries(select(.value | length > 0))
  else . end)
  # Drop the status line only if it is ours; leave any other status line untouched.
  | (if ((.statusLine.command // "") | startswith($d)) then del(.statusLine) else . end)
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
echo "Removed handoff-guard hooks + status line from $SETTINGS. Scripts remain in $DEST."
