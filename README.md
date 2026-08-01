# claude-handoff-guard

Auto-generate a **resume-anywhere handoff document** for long Claude Code sessions.

It watches two signals every turn — how full the **context window** is (exact) and how
much of your **rolling usage window** is spent (approximate, via [`ccusage`](https://github.com/ryoppippi/ccusage)) —
and as soon as the larger one crosses **70%**, it starts writing and continuously
updating a `HANDOFF.md` in your project. When you (or a teammate) open a fresh session,
the handoff is injected automatically so you pick up where you left off **without
replaying the whole conversation**.

No daemon, no polling loop. It's driven by Claude Code hooks, so it only runs while
you're actually working.

---

## How it works

```
Status line ──────► handoff-status.sh  records the REAL context% / 5h% / 7d% (the sensor)
                                       and shows "Handoff: true/false (max%)"

Stop hook (after every turn) ──► handoff-monitor.sh
                                    1. read the recorded real percentages
                                    2. max(context%, 5-hour%, 7-day%) ≥ 70%?
                                          └─► handoff-gen.sh  (background, debounced)

PreCompact hook ──► handoff-gen.sh   guaranteed final snapshot before context is compacted
SessionStart hook ─► handoff-resume.sh  injects HANDOFF.md into the next session
```

- **`handoff-monitor.sh`** — the cheap gate. Below threshold it exits in milliseconds.
  Above it, it fires the generator in the background (so your turn never blocks) and
  **debounces** so it only regenerates after context grows `REGEN_DELTA_TOKENS`.

> ### The status line is the sensor, not decoration
>
> Claude Code publishes the authoritative numbers — `context_window.used_percentage`,
> `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` — **to the
> status line only**. Hooks never receive them. So `handoff-status.sh` records them each
> render and `handoff-monitor.sh` reads them back.
>
> **If the ticker isn't wired up, the guard falls back to estimating** from `CONTEXT_LIMIT`
> and `BLOCK_TOKEN_LIMIT`, and those estimates can be wrong in *both* directions — a real
> session measured 16% context (1M window, but `CONTEXT_LIMIT=200000` said 68%) and a real
> 86% of the 5-hour limit that the `ccusage`/`BLOCK_TOKEN_LIMIT` estimate put at 35%. The
> guard then sits at "false" while you're minutes from a rate limit. Run
> `handoff-doctor.sh` — it tells you which source is in play.
- **`handoff-gen.sh`** — extracts the recent conversation text from the transcript and
  asks a model (default `claude-opus-4-6`) to write/refresh `HANDOFF.md` with fixed
  sections: goal · status · decisions · files touched · next steps · open questions · how to resume.
  The nested `claude -p` call is **hermetic** — `--safe-mode --tools "" --strict-mcp-config
  --no-session-persistence` — so it can't inherit your hooks (no recursion), can't be
  derailed by your plugins/skills/`CLAUDE.md`, can't touch your files, and can't leave
  stray transcripts behind. Output is taken from `--output-format json` and **validated**
  before it is written; a failed generation leaves the previous `HANDOFF.md` intact.
- **`handoff-resume.sh`** — on session start, if a **valid** `HANDOFF.md` exists it's injected
  as context (falling back to `HANDOFF.md.bak`). An incomplete file is never injected.
- **`handoff-doctor.sh`** — self-test: checks deps, hooks, config, transcript discovery and
  the token signals, and with `--generate` performs one real generation. Run it instead of
  waiting to hit 70% to find out whether the guard actually works.
- **`handoff-status.sh`** — the status-line ticker. Reads a tiny per-session state file the
  monitor refreshes each turn and prints **`Handoff: true`** (green, once the larger signal
  has crossed 70% and the handoff is being maintained) or **`Handoff: false`** (dimmed)
  — with the current max % alongside. No transcript parsing on render, so it's instant.

> **Status line is a single value.** Claude Code allows only one status-line command.
> `install.sh` sets it **only if you don't already have one** — if you do, it's left
> untouched and the installer prints how to call `handoff-status.sh` from your existing
> status-line script and append its output.

---

## Layout

```
claude-handoff-guard/
├── install.sh              # installer (copies scripts, wires up settings.json)
├── uninstall.sh            # removes the hooks + status line it added
├── bin/                    # scripts Claude Code invokes (hooks + status line)
│   ├── handoff-monitor.sh  #   Stop hook — per-turn gate
│   ├── handoff-gen.sh      #   generator (also the PreCompact hook)
│   ├── handoff-resume.sh   #   SessionStart hook
│   ├── handoff-status.sh   #   status-line ticker
│   └── handoff-doctor.sh   #   self-test (`--generate` for a live end-to-end check)
├── lib/
│   └── common.sh           # shared config + signal math
└── examples/
    ├── config.example.sh   # copied to ~/.claude/handoff-guard/config.sh on install
    └── settings.snippet.json  # manual-install reference
```

## Install

Requirements: `jq`, `claude` (Claude Code CLI), and Node/`npx` if you want the usage-window signal.

```bash
git clone https://github.com/4shw1nS/claude-handoff-guard.git
cd claude-handoff-guard
./install.sh
```

This copies the scripts to `~/.claude/handoff-guard/`, creates `config.sh` from the
example, and registers the three hooks in `~/.claude/settings.json` (idempotent — safe
to re-run). Restart Claude Code (or `/hooks`) to load them.

Prefer to wire it up by hand? See `examples/settings.snippet.json`.

Uninstall: `./uninstall.sh` (removes the hooks; leaves your scripts/config on disk).

---

## Configure

Edit `~/.claude/handoff-guard/config.sh`:

| Setting | Default | Meaning |
|---|---|---|
| `THRESHOLD_PCT` | `70` | Start writing the handoff at this % of the largest signal |
| `SIGNALS_MAX_AGE_SECS` | `900` | Ignore recorded status-line signals older than this |
| `CONTEXT_LIMIT` | `200000` | **Fallback only.** Context size in tokens, used when the real context% isn't available |
| `ENABLE_USAGE_CHECK` | `true` | **Fallback only.** Estimate the usage window via `ccusage` when the real 5h% isn't available |
| `BLOCK_TOKEN_LIMIT` | `19000000` | **Fallback only.** Token budget for one 5h block — a guess; see the calibration note |
| `USAGE_CACHE_TTL` | `90` | Seconds to cache the (slow) `ccusage` lookup |
| `GEN_MODEL` | `claude-opus-4-6` | Model used to write the handoff (see "Choosing GEN_MODEL" below) |
| `REGEN_DELTA_TOKENS` | `15000` | Only regenerate after context grows this much |
| `HANDOFF_FILE` | `HANDOFF.md` | File written into the project cwd |
| `GEN_TIMEOUT_SECS` | `240` | Kill a generation that hangs longer than this |
| `RETRY_COOLDOWN_SECS` | `120` | Min seconds between generation attempts (stops failure loops) |
| `MIN_HANDOFF_BYTES` | `300` | Output shorter than this is rejected, not written |
| `KEEP_BACKUP` | `true` | Keep the last good handoff as `HANDOFF.md.bak` |
| `STATE_DIR` | `~/.claude/handoff-guard/state` | Debounce markers + log. **Don't put this under `$TMPDIR`** — macOS reaps it |

### Choosing GEN_MODEL

The default is **`claude-opus-4-6`** — the highest-fidelity summaries, so the handoff
you rely on across a rate-limit boundary captures nuance and next steps accurately. This
is the right default when the handoff *is* your safety net.

> 💡 **Prefer to save on cost? Default to Haiku.** Set `GEN_MODEL=claude-haiku-4-5` in
> `config.sh`. Handoff generation is a summarization task Haiku handles well, and because
> it runs repeatedly (every ~15k tokens past 70%) a cheaper model keeps the overhead — and
> the usage it draws from the same subscription — negligible. Opus buys fidelity; Haiku
> buys cost. `claude-sonnet-5` sits in between.

### Calibrating the fallback signals (only if the ticker isn't wired up)

With `handoff-status.sh` in your status line there is **nothing to calibrate** — the guard
uses Claude Code's own percentages. `guard.log` records which source it used:

```
ctx=137361tok(16%) 5h=86% 7d=8% max=86% src=statusline session=…
ctx=137361tok(68%) 5h=35% 7d=0% max=68% src=ctx-est+ccusage session=…   ← estimating, and wrong
```

If you can't wire up the status line, tune the fallbacks: set `CONTEXT_LIMIT` to your real
window (`1000000` on 1M-context models — the default `200000` will read ~5× too high), and
pick `BLOCK_TOKEN_LIMIT` by comparing `/usage` against `guard.log` until the logged `5h%`
tracks it. Subscription limits are quota based, not a published token number, so this is
always an approximation. Alternatively set `ENABLE_USAGE_CHECK=false` and rely on context alone.

---

## Troubleshooting

Start with the doctor — it checks everything the hooks depend on:

```bash
cd <a project you've used>
~/.claude/handoff-guard/bin/handoff-doctor.sh            # fast, free
~/.claude/handoff-guard/bin/handoff-doctor.sh --generate # one real generation
```

Then `tail ~/.claude/handoff-guard/state/guard.log`.

**`HANDOFF.md` contains `Error: Reached max turns (1)` (or is ~29 bytes).**
Fixed in the current version; you were on an older one. The generator used to call
`claude -p --max-turns 1` with the *full* environment inherited — your hooks, plugins,
skills, MCP servers and `CLAUDE.md`. When that nested run decided to use a tool, the tool
call consumed its single allowed turn and the CLI printed `Error: Reached max turns (1)`
**on stdout** (exit code 1). The old generator only checked that the output was non-empty,
never the exit code, so it wrote the error string into `HANDOFF.md` — and `SessionStart`
then injected that into the next session as its "handoff". Re-run `install.sh`; the file
will be regenerated automatically on the next turn past the threshold.

**The handoff never updates after the first write.**
Also fixed. The debounce marker was written *before* generating, so a failed attempt still
counted and suppressed retries for the next `REGEN_DELTA_TOKENS`. The marker now advances
only after a valid document lands, and a missing/invalid handoff is repaired on the next
turn (rate-limited by `RETRY_COOLDOWN_SECS`).

**Status line says `Handoff: FAILED`.**
The last generation failed. The reason is in `guard.log` and in
`state/gen_status_<session>`. Your previous `HANDOFF.md` was left untouched.

**`Handoff: false` while `/usage` says you're near the 5-hour limit.**
The guard is estimating instead of reading the real number. Check `src=` in `guard.log`:
`src=statusline` or `src=hook` means it's using Claude Code's own percentages; anything
containing `ctx-est` or `ccusage` means it's guessing. Wire `handoff-status.sh` into your
status line (see "The status line is the sensor") and run `handoff-doctor.sh` to confirm.

**Nothing happens at all / `guard.log` shows `ctx=0`.**
`ctx=0` means the transcript's most recent assistant record carried no usage numbers, so
the threshold could never be crossed. The current version scans back for the last record
with a non-zero prompt size. If it still reads 0, run the doctor — the transcript format
may have changed (see `context_tokens()` in `lib/common.sh`).

---

## Notes & caveats

- **Cost:** each handoff update is one short `claude -p` call, debounced so expect only a
  handful of updates in the back half of a long session. On the default `claude-opus-4-6`
  each update is a few cents; on `claude-haiku-4-5` it's fractions of a cent. Either way it
  counts against the same subscription usage — see "Choosing GEN_MODEL" to trade fidelity
  for cost.
- **`ccusage` JSON shape** can change between versions. If `usage%` logs as `0%` while
  `/usage` clearly isn't, adjust the `jq` selector in `usage_tokens()` in `lib/common.sh`.
- **Transcript fields** (`input_tokens`, `cache_read_input_tokens`, …) reflect Claude
  Code's current transcript format; if a future version renames them, update `context_tokens()`.
- Everything writes `HANDOFF.md` into the **project working directory** — add it to
  `.gitignore` in your own repos if you don't want to commit it (also `HANDOFF.md.bak`).
- **The generated handoff is a summary of an untrusted transcript.** The generator runs
  with no tools and treats the transcript as data, but the resulting `HANDOFF.md` is
  injected into your next session as context — skim it like you would any generated file.
- Logs and state: `~/.claude/handoff-guard/state/` (`guard.log`).

## License

MIT — see `LICENSE`.
