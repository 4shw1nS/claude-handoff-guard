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
Stop hook (after every turn) ──► handoff-monitor.sh
                                    1. context%  = last-message tokens / CONTEXT_LIMIT   (exact)
                                    2. usage%    = ccusage active block / BLOCK_TOKEN_LIMIT (approx)
                                    3. max(context%, usage%) ≥ 70%?
                                          └─► handoff-gen.sh  (background, debounced)

PreCompact hook ──► handoff-gen.sh   guaranteed final snapshot before context is compacted
SessionStart hook ─► handoff-resume.sh  injects HANDOFF.md into the next session
Status line ──────► handoff-status.sh  shows "Handoff: true/false" — true once ≥70%
```

- **`handoff-monitor.sh`** — the cheap gate. Below threshold it exits in milliseconds.
  Above it, it fires the generator in the background (so your turn never blocks) and
  **debounces** so it only regenerates after context grows `REGEN_DELTA_TOKENS`.
- **`handoff-gen.sh`** — extracts the recent conversation text from the transcript and
  asks a model (default `claude-opus-4-6`) to write/refresh `HANDOFF.md` with fixed
  sections: goal · status · decisions · files touched · next steps · open questions · how to resume.
- **`handoff-resume.sh`** — on session start, if `HANDOFF.md` exists it's injected as context.
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
│   └── handoff-status.sh   #   status-line ticker
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
| `THRESHOLD_PCT` | `70` | Start writing the handoff at this % of the larger signal |
| `CONTEXT_LIMIT` | `200000` | Context size in tokens (`1000000` on the 1M beta) |
| `ENABLE_USAGE_CHECK` | `true` | Also watch the rolling usage window via `ccusage` |
| `BLOCK_TOKEN_LIMIT` | `19000000` | Token budget for one 5h usage block — **an estimate, calibrate it** |
| `USAGE_CACHE_TTL` | `90` | Seconds to cache the (slow) `ccusage` lookup |
| `GEN_MODEL` | `claude-opus-4-6` | Model used to write the handoff (see "Choosing GEN_MODEL" below) |
| `REGEN_DELTA_TOKENS` | `15000` | Only regenerate after context grows this much |
| `HANDOFF_FILE` | `HANDOFF.md` | File written into the project cwd |

### Choosing GEN_MODEL

The default is **`claude-opus-4-6`** — the highest-fidelity summaries, so the handoff
you rely on across a rate-limit boundary captures nuance and next steps accurately. This
is the right default when the handoff *is* your safety net.

> 💡 **Prefer to save on cost? Default to Haiku.** Set `GEN_MODEL=claude-haiku-4-5` in
> `config.sh`. Handoff generation is a summarization task Haiku handles well, and because
> it runs repeatedly (every ~15k tokens past 70%) a cheaper model keeps the overhead — and
> the usage it draws from the same subscription — negligible. Opus buys fidelity; Haiku
> buys cost. `claude-sonnet-5` sits in between.

### Calibrating the usage-window signal (important)

The **context** signal is exact. The **usage-window** signal is not: Claude subscription
limits (Pro included) are quota/message based, not a published token number, so
`BLOCK_TOKEN_LIMIT` is a stand-in you tune to your plan:

1. Work normally for a while with the guard installed.
2. Compare Claude Code's `/usage` screen against `guard.log` (`tail -f "${TMPDIR:-/tmp}/claude-handoff-guard/guard.log"`).
3. Pick `BLOCK_TOKEN_LIMIT` so that when `/usage` nears its cap, the logged `usage%` nears 100%.

On **Pro**, if you'd rather not bother, set `ENABLE_USAGE_CHECK=false` and rely on the
exact context signal alone — that already covers the "pick up where we left off" goal.

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
  `.gitignore` in your own repos if you don't want to commit it.
- Logs: `${TMPDIR:-/tmp}/claude-handoff-guard/guard.log`.

## License

MIT — see `LICENSE`.
