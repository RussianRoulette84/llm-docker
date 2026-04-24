# OpenCode docs (vendored)

Cached snapshot of OpenCode's docs (`https://opencode.ai/docs/<slug>.md` —
raw markdown source served via the content-type `text/plain`). Fetched to
keep the handful we care about close at hand.

Refresh by re-running:

```sh
cd docs/opencode && \
  BASE=https://opencode.ai/docs && \
  curl -fsSL "$BASE/index.md" -o "index.md"; \
  for f in cli config commands modes agents providers models rules plugins keybinds; do \
    curl -fsSL "$BASE/$f.md" -o "$f.md"; \
  done
```

## Files

| File | Why it's here |
|---|---|
| [index.md](index.md)       | Landing page — high-level intro to OpenCode |
| [cli.md](cli.md)           | OpenCode CLI reference (the CLI `ocd` wraps) |
| [config.md](config.md)     | Config file format (JSONC) — directly relevant to `src/llm-container-opencode-config.jsonc` |
| [commands.md](commands.md) | Slash commands — maps to `.claude/commands/` conceptually (OpenCode has its own) |
| [modes.md](modes.md)       | Execution / interaction modes |
| [agents.md](agents.md)     | OpenCode's agent system |
| [providers.md](providers.md) | LLM provider config — how the `.env` keys (`OPENAI_API_KEY`, `ZAI_API_KEY`, `ANTHROPIC_API_KEY`) get wired |
| [models.md](models.md)     | Model selection (`ANTHROPIC_MODEL`, etc.) |
| [rules.md](rules.md)       | Rules / `AGENTS.md` loading — what OpenCode reads from the project root |
| [plugins.md](plugins.md)   | Plugin system |
| [keybinds.md](keybinds.md) | Keyboard shortcuts |

## What's NOT here (and why)

Skipped for this repo's concerns:
- `tui.md`, `themes.md`, `zen.md` — UI-only
- `share.md` — session sharing (not used here)
- `formatters.md` — we don't prescribe a formatter
- `windows-wsl.md` — macOS/Linux-only project
- `troubleshooting.md` — not worth caching; check online if stuck

## Source of truth

`https://opencode.ai/docs/` is authoritative. These are a snapshot —
refetch when you need current info, especially for providers/models.
