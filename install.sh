#!/usr/bin/env bash
# Installs claude-handoff-guard: copies scripts to ~/.claude/handoff-guard and registers
# the Stop / PreCompact / SessionStart hooks in ~/.claude/settings.json (idempotent).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDE_HANDOFF_HOME:-$HOME/.claude/handoff-guard}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (macOS: brew install jq)"; exit 1; }
command -v claude >/dev/null 2>&1 || echo "warning: 'claude' not on PATH — generation will no-op until it is."

mkdir -p "$DEST"
cp -R "$SRC/bin" "$SRC/lib" "$DEST/"
chmod +x "$DEST/bin/"*.sh
if [ -f "$DEST/config.sh" ]; then
  echo "kept existing $DEST/config.sh"
else
  cp "$SRC/examples/config.example.sh" "$DEST/config.sh"
  echo "created $DEST/config.sh (edit to tune)"
fi

MON="$DEST/bin/handoff-monitor.sh"
GEN="$DEST/bin/handoff-gen.sh"
RES="$DEST/bin/handoff-resume.sh"
STATUS="$DEST/bin/handoff-status.sh"

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

tmp=$(mktemp)
jq --arg mon "$MON" --arg gen "$GEN" --arg res "$RES" '
  .hooks //= {}
  | .hooks.Stop        = (((.hooks.Stop        // []) + [{hooks:[{type:"command", command:$mon}]}]) | unique_by(.hooks[0].command))
  | .hooks.PreCompact  = (((.hooks.PreCompact  // []) + [{hooks:[{type:"command", command:$gen}]}]) | unique_by(.hooks[0].command))
  | .hooks.SessionStart= (((.hooks.SessionStart// []) + [{hooks:[{type:"command", command:$res}]}]) | unique_by(.hooks[0].command))
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# Status-line ticker. statusLine is a single object (not an array), so only set it
# when the user hasn't already configured one — never clobber an existing status line.
existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS")
if [ -z "$existing_sl" ]; then
  tmp=$(mktemp)
  jq --arg s "$STATUS" '.statusLine = {type:"command", command:$s}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  SL_MSG="registered (\"Handoff: true/false\" ticker)"
elif [ "$existing_sl" = "$STATUS" ]; then
  SL_MSG="already registered"
else
  SL_MSG="LEFT ALONE — you already have a status line (see note below)"
  EXISTING_SL_NOTE="$existing_sl"
fi

echo
echo "Installed."
echo "  scripts    : $DEST"
echo "  hooks      : registered in $SETTINGS (Stop, PreCompact, SessionStart)"
echo "  statusline : $SL_MSG"
echo "  config     : $DEST/config.sh"
echo "  log        : \${TMPDIR:-/tmp}/claude-handoff-guard/guard.log"
if [ -n "${EXISTING_SL_NOTE:-}" ]; then
  echo
  echo "Your existing status line was kept:"
  echo "    $EXISTING_SL_NOTE"
  echo "To add the Handoff ticker, call this from your status-line script and append its"
  echo "output (pass the same stdin JSON through):"
  echo "    input=\$(cat); printf '%s' \"\$input\" | $STATUS"
fi
echo
echo "Restart Claude Code (or /hooks reload) to pick up the new hooks."
