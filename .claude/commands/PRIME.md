---
description: One-time project reconnaissance for llm-docker — no generic project detection needed.
allowed-tools: Read, Glob, Grep, Bash
---

# PRIME (llm-docker)

This repo's shape is already known — you don't need to discover it. Use this
command to **refresh your mental model** and check nothing has drifted.

---

## What llm-docker is

- A bash-first install/run wrapper around `claude` and `opencode` inside
  Docker. Entry points: `cld`, `ocd` (linked to `/usr/local/bin` by
  `src/install.sh`).
- A Python framework under `src/builder-api/` for host-side build / run /
  log / WebSocket tunneling, called by the container via
  `host.docker.internal:6666`.
- macOS-first (AppleScript for multi-window layouts and new-terminal
  spawning), Linux-tolerant (fallbacks in cld/ocd for non-Darwin).

## Layout

```
llm-docker/
├── README.md, CHANGELOG.md, CLAUDE.md, .gitignore
├── logo.png, screenshot.png
├── logs/                   ← gitignored runtime log directory
├── .claude/                ← this directory (agents/commands/skills)
└── src/
    ├── install.sh          ← installer wizard (was repo root, now here)
    ├── cld, ocd            ← user-facing launchers
    ├── setup.sh, ascii.sh  ← shared helpers; sourced by install/cld/ocd
    ├── install_devpack.sh  ← INSTALL_* optional packs installer (runs inside container at build time)
    ├── Dockerfile, docker-entrypoint.sh
    ├── .env.example        ← secrets template (→ .env on install)
    ├── llm-docker.conf     ← committed non-secret config (user paths, sandbox, Claude tuning)
    ├── llm-container-claude-settings.json   ← fresh-session Claude permissions
    ├── llm-container-opencode-config.jsonc  ← OpenCode config template
    ├── multi-llm-docker.applescript
    └── builder-api/
        ├── server.py, config.py, security.py, build_queue.py
        ├── runtime.py, events.py, logs.py, ws.py, plugin.py, client.py
        ├── browser.js, run-local.sh, builder_api.applescript
        └── examples/       ← .builder-api.{toml,yml} + hello-world/
```

## Persistence (host)

- `~/.llm-docker/claude/.claude/` — sessions, slots, credentials
- `~/.llm-docker/claude/.config/` — secondary Claude config
- `~/.llm-docker/claude/.claude.json` — top-level user config
- `~/.llm-docker/opencode/.config/opencode/` — user config, modes, agents
- `~/.llm-docker/opencode/.local/share/opencode/` — auth + sessions
- `~/.llm-docker/opencode/.cache/opencode/` — plugin cache
- **Everything else inside the container is ephemeral.**

## Workflow checks (run these; trust files over assumptions)

1. Confirm the layout is intact: `Glob "src/**/*.py"` and `Glob "src/*.sh"`.
   If files are missing vs. the tree above, note it.
2. `.env.example` + `llm-docker.conf` present at `src/`? `ls src/.env.example src/llm-docker.conf`.
3. `install.sh` at `src/`? `ls src/install.sh`.
4. Is a builder-api daemon currently running? `lsof -i :6666 2>/dev/null ||
   echo "no daemon"`.

## Project rules (read these — they apply to every action)

- `CLAUDE.md` at root: **do not run docker without permission**, **do not
  run `src/install.sh` or `src/setup.sh`**, **never delete contents of the workspace
  mount inside the container** (it writes back to host).
- `.claude/settings.local.json` deny list: no `rm`, no `docker` lifecycle
  commands, no `git` state-changing ops. Work through files; describe the
  one-liner if the user needs to run it themselves.

## When this has been run

The agent should now know enough to implement plans, adapt scripts, or add
builder-api modules without asking "what is this project?" again.
