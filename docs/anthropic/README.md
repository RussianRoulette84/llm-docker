# Claude Code docs (vendored)

Cached snapshot of the Claude Code docs that matter for this repo. Fetched
from `https://code.claude.com/docs/en/<name>.md`. Refresh by re-running:

```sh
cd docs/anthropic && \
  BASE=https://code.claude.com/docs/en && \
  for f in permissions settings permission-modes memory commands skills \
           sub-agents hooks cli-reference sandboxing; do \
    curl -fsSL "$BASE/$f.md" -o "$f.md"; \
  done
```

## Files

| File | Why it's here |
|---|---|
| [permissions.md](permissions.md)             | Allow / deny rule syntax, Tool(pattern) grammar — touches `.claude/settings.local.json` we spent time tuning |
| [settings.md](settings.md)                   | Settings file hierarchy (global / project / `.local`) + full option reference |
| [permission-modes.md](permission-modes.md)   | plan / ask / edit / bypass modes; what each changes about prompting |
| [memory.md](memory.md)                       | How `CLAUDE.md` (the file at the repo root) is loaded + scoped |
| [commands.md](commands.md)                   | Slash-commands — maps to `.claude/commands/*.md` |
| [skills.md](skills.md)                       | Skills — maps to `.claude/skills/<name>/SKILL.md` |
| [sub-agents.md](sub-agents.md)               | Sub-agents — maps to `.claude/agents/*.md` |
| [hooks.md](hooks.md)                         | Pre/PostToolUse hooks + the `hooks` block in settings |
| [cli-reference.md](cli-reference.md)         | Flags and env vars the `claude` CLI accepts (the CLI `cld` wraps) |
| [sandboxing.md](sandboxing.md)               | Claude Code's native sandbox model — overlaps with what this repo's Docker container does |

## How to read

These are vendored copies. The authoritative source is the URL above —
when in doubt (especially for newer features that post-date the snapshot
date), refetch.
