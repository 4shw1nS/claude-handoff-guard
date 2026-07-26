# claude-handoff-guard configuration.
# install.sh copies this to ~/.claude/handoff-guard/config.sh (only if not already present).
# Every value is optional — anything you leave out falls back to the built-in default.

# ---- Threshold ----
THRESHOLD_PCT=70              # start generating the handoff at this % of the larger signal

# ---- Context-window signal (EXACT) ----
CONTEXT_LIMIT=200000         # 200000 for Pro/standard; 1000000 if you run the 1M-context beta

# ---- Subscription usage signal (APPROXIMATE, via ccusage) ----
ENABLE_USAGE_CHECK=true      # set false to watch only the context window
# Rough token budget for one rolling 5-hour usage block on your plan. This is an ESTIMATE:
# Pro limits are message/quota based, not a published token count. Calibrate it (see README):
# watch guard.log next to the /usage screen and pick a number so that when /usage nears its
# cap, use% here nears 100.
BLOCK_TOKEN_LIMIT=19000000
USAGE_CACHE_TTL=90           # seconds to cache the (slow) ccusage lookup between turns

# ---- Generation ----
# Model used to write the handoff. Default is Opus 4.6 for the highest-fidelity
# summaries (ideal for a rate-limit handoff you want to trust). To save on cost,
# switch to a cheaper model such as claude-haiku-4-5 — see README "Choosing GEN_MODEL".
GEN_MODEL=claude-opus-4-6
REGEN_DELTA_TOKENS=15000     # debounce: only regenerate once context grows this much
HANDOFF_FILE=HANDOFF.md      # written into the project's working directory
