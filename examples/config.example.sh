# claude-handoff-guard configuration.
# install.sh copies this to ~/.claude/handoff-guard/config.sh (only if not already present).
# Every value is optional — anything you leave out falls back to the built-in default.

# ---- Threshold ----
THRESHOLD_PCT=70              # start generating the handoff at this % of the larger signal

# ---- Signals ----
# When handoff-status.sh is in your status line, the guard uses Claude Code's OWN
# percentages (context%, 5-hour%, 7-day%) and everything below is unused. Check `src=` in
# guard.log: "statusline"/"hook" = real numbers, "ctx-est"/"ccusage" = estimating.
SIGNALS_MAX_AGE_SECS=900     # ignore recorded status-line signals older than this

# ---- FALLBACK: context-window signal ----
# Only used when the real context% is unavailable. The default is wrong on 1M-context
# models — it will read roughly 5x too high. Set it to your actual window.
CONTEXT_LIMIT=200000         # 200000 standard; 1000000 for a 1M-context model

# ---- FALLBACK: subscription usage signal (APPROXIMATE, via ccusage) ----
ENABLE_USAGE_CHECK=true      # set false to watch only the context window
# Rough token budget for one rolling 5-hour usage block on your plan. This is a GUESS:
# subscription limits are message/quota based, not a published token count. On a real
# session the default read 35% when the true figure was 86%. Calibrate it (see README) or
# — much better — wire up the status line and ignore it entirely.
BLOCK_TOKEN_LIMIT=19000000
USAGE_CACHE_TTL=90           # seconds to cache the (slow) ccusage lookup between turns

# ---- Generation ----
# Model used to write the handoff. Default is Opus 4.6 for the highest-fidelity
# summaries (ideal for a rate-limit handoff you want to trust). To save on cost,
# switch to a cheaper model such as claude-haiku-4-5 — see README "Choosing GEN_MODEL".
GEN_MODEL=claude-opus-4-6
REGEN_DELTA_TOKENS=15000     # debounce: only regenerate once context grows this much
HANDOFF_FILE=HANDOFF.md      # written into the project's working directory

# ---- Reliability ----
GEN_TIMEOUT_SECS=240         # kill a generation that hangs longer than this
RETRY_COOLDOWN_SECS=120      # min seconds between generation attempts (stops failure loops)
MIN_HANDOFF_BYTES=300        # output shorter than this is rejected, not written
GEN_MAX_TURNS=3              # headroom; the generator runs with tools disabled anyway
KEEP_BACKUP=true             # keep the last good handoff as HANDOFF.md.bak

# ---- State ----
# Where debounce markers and guard.log live. Do NOT put this under $TMPDIR — macOS reaps
# /var/folders periodically, which silently wipes the debounce state and the log.
# STATE_DIR="$HOME/.claude/handoff-guard/state"
