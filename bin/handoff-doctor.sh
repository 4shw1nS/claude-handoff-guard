#!/usr/bin/env bash
# Self-test. Run this instead of waiting to hit 70% to find out whether the guard works.
#
#   handoff-doctor.sh              # check config, hooks, transcript discovery
#   handoff-doctor.sh --generate   # ALSO do a real generation into a temp file (costs tokens)
#
# Exits non-zero if anything is broken.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

RED=$'\033[31m'; GREEN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
fails=0
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; fails=$((fails+1)); }
warn() { printf '  %s!%s %s\n' "$YEL" "$RESET" "$1"; }
info() { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }

echo
echo "claude-handoff-guard doctor"
echo "──────────────────────────────────────────────"

echo "Dependencies"
command -v jq     >/dev/null 2>&1 && ok "jq"     || bad "jq not on PATH (macOS: brew install jq)"
command -v claude >/dev/null 2>&1 && ok "claude ($(claude --version 2>/dev/null))" \
                                  || bad "claude not on PATH — generation can never run"
if [ "$ENABLE_USAGE_CHECK" = "true" ]; then
  command -v npx >/dev/null 2>&1 && ok "npx (for ccusage)" || warn "npx missing — usage signal will read 0"
fi

echo
echo "Config"
info "GUARD_HOME       = $GUARD_HOME"
info "STATE_DIR        = $STATE_DIR"
info "THRESHOLD_PCT    = $THRESHOLD_PCT"
info "CONTEXT_LIMIT    = $CONTEXT_LIMIT"
info "GEN_MODEL        = $GEN_MODEL"
info "HANDOFF_FILE     = $HANDOFF_FILE"
info "GEN_CEILING_PCT  = $GEN_CEILING_PCT"
if [ "$AUTO_GENERATE" = "true" ]; then
  ok "AUTO_GENERATE=true — the guard generates on its own"
else
  warn "AUTO_GENERATE=false — the guard will NEVER generate on its own"
  info "the ticker still tracks usage; run handoff-now.sh in a project to create one"
fi
if mkdir -p "$STATE_DIR" 2>/dev/null && [ -w "$STATE_DIR" ]; then ok "state dir writable"
else bad "state dir not writable: $STATE_DIR"; fi
case "$STATE_DIR" in
  /var/folders/*|/tmp/*) warn "state dir is under the system temp dir — macOS reaps it, debounce state will be lost" ;;
esac

echo
echo "Hooks"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
if [ -f "$SETTINGS" ]; then
  for pair in "Stop:handoff-monitor.sh" "PreCompact:handoff-gen.sh" "SessionStart:handoff-resume.sh"; do
    ev="${pair%%:*}"; scr="${pair##*:}"
    if jq -e --arg ev "$ev" --arg s "$scr" '
          [ (.hooks[$ev] // [])[] | (.hooks // [])[] | .command // empty ]
          | map(select(contains($s))) | length > 0
        ' "$SETTINGS" >/dev/null 2>&1
    then ok "$ev -> $scr"
    else bad "$ev hook for $scr not registered in $SETTINGS (run install.sh)"; fi
  done
else
  bad "no settings file at $SETTINGS"
fi

echo
echo "Current project"
cwd="$PWD"
info "cwd = $cwd"
case "$HANDOFF_FILE" in /*) hf="$HANDOFF_FILE" ;; *) hf="$cwd/$HANDOFF_FILE" ;; esac
if [ -f "$hf" ]; then
  if handoff_is_valid "$hf"; then ok "$HANDOFF_FILE present and valid ($(wc -c < "$hf" | tr -d ' ') bytes)"
  else bad "$HANDOFF_FILE present but INVALID ($(wc -c < "$hf" | tr -d ' ') bytes): $(head -c 80 "$hf" | tr '\n' ' ')"
       info "it will be regenerated automatically once you cross ${THRESHOLD_PCT}%"; fi
else
  info "no $HANDOFF_FILE yet (expected until you cross ${THRESHOLD_PCT}%)"
fi

# Transcript discovery mirrors how Claude Code slugifies a project path.
slug=$(printf '%s' "$cwd" | sed 's#[/._]#-#g')
pdir="$HOME/.claude/projects/$slug"
transcript=""
if [ -d "$pdir" ]; then
  transcript=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -n1)
fi
if [ -n "$transcript" ]; then
  ok "transcript found: $(basename "$transcript")"
  ctx=$(context_tokens "$transcript")
  if [ "$ctx" -gt 0 ]; then
    ok "context reads $ctx tokens (drives the regen debounce; $(pct_of "$ctx" "$CONTEXT_LIMIT")% of CONTEXT_LIMIT as fallback)"
  else
    bad "context reads 0 — the regen debounce and the fallback context signal won't work"
  fi
else
  warn "no transcript under $pdir (fine on a brand-new project)"
fi

echo
echo "Signals"
# The status line is the sensor: it is the only place Claude Code publishes the true
# context% and rate-limit%. Without it wired up, the guard falls back to token estimates.
SL_CMD=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)
if printf '%s' "$SL_CMD" | grep -q 'handoff-status.sh'; then
  ok "status line runs handoff-status.sh directly"
elif [ -n "$SL_CMD" ] && grep -qs 'handoff-status.sh' "${SL_CMD##* }" 2>/dev/null; then
  ok "status line ($(basename "${SL_CMD##* }")) calls handoff-status.sh"
else
  warn "handoff-status.sh is not in your status line — the guard cannot see the REAL"
  info "context% / 5h% / 7d% and will fall back to CONTEXT_LIMIT and BLOCK_TOKEN_LIMIT"
  info "estimates. Pipe the status-line JSON through: input=\$(cat); printf '%s' \"\$input\" | $DIR/handoff-status.sh"
fi

found_sig=0
for f in "$STATE_DIR"/signals_*; do
  [ -f "$f" ] || continue
  found_sig=1
  IFS='|' read -r c h d ts < "$f"
  age=$(( $(date +%s) - ${ts:-0} ))
  ok "recorded: ctx=${c:-?}% 5h=${h:-?}% 7d=${d:-?}% (${age}s ago, session $(basename "$f" | sed 's/^signals_//' | cut -c1-8))"
done
[ "$found_sig" -eq 1 ] || warn "no recorded signals yet — render the status line once (they appear after the next turn)"

if [ "$ENABLE_USAGE_CHECK" = "true" ] && command -v npx >/dev/null 2>&1; then
  u=$(usage_tokens)
  if [ "$u" -gt 0 ]; then info "fallback ccusage: $u tokens = $(pct_of "$u" "$BLOCK_TOKEN_LIMIT")% of BLOCK_TOKEN_LIMIT (only used if the real 5h% is unavailable)"
  else warn "fallback ccusage reads 0 — unavailable or its JSON shape changed"; fi
fi

# ---- Optional live generation ------------------------------------------------
if [ "${1:-}" = "--generate" ]; then
  echo
  echo "Live generation test"
  if [ -z "$transcript" ]; then
    bad "cannot test: no transcript for this project"
  else
    out="$STATE_DIR/doctor-handoff.md"
    rm -f "$out"
    info "generating with $GEN_MODEL (this costs tokens and takes ~10-60s)…"
    MAX_PCT="$(pct_of "$ctx" "$CONTEXT_LIMIT")" HANDOFF_FILE="$out" GEN_SESSION="doctor" \
      "$DIR/handoff-gen.sh" "$transcript" "$cwd" >/dev/null 2>&1
    if handoff_is_valid "$out"; then
      ok "generated a valid handoff ($(wc -c < "$out" | tr -d ' ') bytes) -> $out"
      info "first line: $(head -n1 "$out")"
    else
      bad "generation failed — see the log below"
      tail -n 5 "$STATE_DIR/guard.log" 2>/dev/null | sed 's/^/    /'
    fi
  fi
fi

echo
echo "Log: $STATE_DIR/guard.log"
echo "──────────────────────────────────────────────"
if [ "$fails" -eq 0 ]; then
  printf '%sAll checks passed.%s\n\n' "$GREEN" "$RESET"; exit 0
else
  printf '%s%d check(s) failed.%s\n\n' "$RED" "$fails" "$RESET"; exit 1
fi
