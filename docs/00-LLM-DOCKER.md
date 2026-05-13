# 00 — LLM-DOCKER: Read this first

> If you're a new contributor, a future Claude session, or me a year from now,
> this is the orientation doc. It's the one place that explains the **mental
> model** before you start hitting buttons. Reference docs (README.md,
> src/builder-api/README.md, CHANGELOG.md) cover the *what*. This covers the
> *why* and the *how do I*.

## 1. What llm-docker is, in one paragraph

llm-docker runs Claude Code (`cld`) and OpenCode (`ocd`) inside a Docker
container so the agent can't `rm -rf /` your host or read your keychain. The
container is built from `node:24` + `src/Dockerfile` + a stack of opt-in
install layers (`src/docker/install_cli.sh`, `src/docker/install_devpack.sh`).
Sessions, API keys, and per-tool config live on the **host** at `~/.llm-docker/`
and are bind-mounted in, so a `docker rmi` doesn't lose your chat history.
Your `~/Projects/` folder is bind-mounted too — that's the only host path the
agent can touch.

## 2. Three things you need to internalise

These are the load-bearing concepts. Everything else is detail.

### 2.1 Three execution surfaces, not one

```
        HOST (your Mac/Linux)              CONTAINER (Docker)
  ┌────────────────────────────────┐  ┌────────────────────────────┐
  │ /usr/local/bin/cld   ──launches──▶ docker-entrypoint.sh         │
  │ /usr/local/bin/ocd                │   ▼                         │
  │ src/builder-api/server.py         │ claude / opencode CLI       │
  │ env-gorilla (KeePassXC unlock)    │                             │
  └────────────────────────────────┘  └────────────────────────────┘
                  ▲                                  │
                  └────── HTTP ──────────────────────┘
                  host.docker.internal:6666 (builder-api)
```

- **`cld` / `ocd`** are HOST shell scripts. They `exec` env-gorilla, read
  `src/.env` + `src/llm-docker.conf`, then `docker run` the container.
  *Bug here? Edit `src/cld` or `src/ocd`. No rebuild needed.*
- **`docker-entrypoint.sh`** runs INSIDE the container. Bind-mounted from
  `src/docker/docker-entrypoint.sh` (read-only), so edits take effect on
  next launch. *No rebuild needed.*
- **`builder-api`** runs ON THE HOST as a Python daemon. The container calls
  it via `host.docker.internal:6666`. *Edit `src/builder-api/*.py`, restart
  the daemon. No rebuild needed.*

When something doesn't work, **first identify which surface owns the bug**.
Most "the agent can't do X" issues are host-side script bugs, not container
problems.

### 2.2 Two config files, never confuse them

| File | Purpose | Tracked in git? |
|---|---|---|
| `src/.env` | **Secrets** — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `BUILDER_API_PASSWORD`, `LLM_DOCKER_SSH_AUTHORIZED_KEYS` | NO (`.gitignore`'d). Seeded from `src/.env.example` by `setup.sh`. |
| `src/llm-docker.conf` | **Build flags + runtime knobs** — `INSTALL_*` (build-time), `WORKSPACE_DIR`, `SANDBOX_ENABLED`, `INTERNET_ACCESS`, `LLM_DOCKER_SSH_ENABLED`, etc. | YES. Edit in place. |

`cld` / `ocd` source both at every launch. `.env` wins on key collisions. Both
are passed to the container via `docker --env-file`.

### 2.3 Two flavours of rebuild

```
cld --build         # SMART: re-runs install scripts INSIDE existing image,
                    # `docker commit`s the result. Skips already-installed
                    # tools (Go binaries, cargo, npm globals, ferox, nikto,
                    # codeman). FAST. Use after editing install_*.sh or
                    # flipping an INSTALL_* flag.

cld --rebuild-force # FULL: docker rmi + docker build from Dockerfile.
                    # SLOW. Use when smart-rebuild cruft has piled up
                    # (months of layered commits) or you edited the
                    # Dockerfile itself.
```

**You almost never need `--rebuild-force`.** Smart rebuild is the default
maintenance path.

## 3. Daily workflow — common commands

```bash
# Most common: launch claude in CWD with default settings
cld

# Continue your last session in this dir
cld -c

# Multi-pane team mode (1 lead + 3 agents in one container)
cld -tt           # default: 1+3 stacked
cld -tt 4         # 2x2 grid
cld -tt 2         # side-by-side

# Start the host-side builder-api daemon at the same time
cld -a

# Force a smart rebuild (after editing install_devpack.sh, conf flags, etc.)
cld --build

# Wipe leftover containers from prior sessions
cld --clean

# Pass through to claude unchanged
cld -- --permission-mode plan
cld -- --resume <uuid>

# Slot system: N parallel chats per project
cld --slot 1            # tag this session as slot 1
cld -c --slot 1         # resume slot 1's last
cld 4                   # open 4 windows, slots 1-4 (macOS only)
cld -c 4                # open 4 windows, each restoring its slot
```

`ocd` accepts the same grammar — same flags, same slots. Use `ocd` for
OpenCode instead of Claude Code.

**`-s` is intentionally NOT a slot alias.** OpenCode's native CLI uses `-s
<uuid>` for `--session`, and we keep passthrough open via `--`. Use `--slot
N` for slots in both launchers.

## 4. Configuration cheat sheet

| What you want | Where to edit | Rebuild? |
|---|---|---|
| Add an API key | `src/.env` | No |
| Add an SSH pubkey | `src/.env` (`LLM_DOCKER_SSH_AUTHORIZED_KEYS`) | No |
| Turn on a build-time toolkit (security, ruby, browsing, etc.) | `src/llm-docker.conf` (`INSTALL_*=true`) | **Yes** — `cld --build` |
| Enable / disable SSH | `src/llm-docker.conf` (`LLM_DOCKER_SSH_ENABLED`) | Yes (first time, to bake openssh-server) |
| Change `WORKSPACE_DIR` (persistent host mirror) | `src/llm-docker.conf` | No |
| Toggle internet block | `src/llm-docker.conf` (`INTERNET_ACCESS=false`) | No (forces bridge networking on next launch) |
| Auto-start builder-api on every launch | `src/llm-docker.conf` (`BUILDER_API_AUTOSTART=true`) | No |

The wizard at `src/install.sh` walks you through all of this on first
install. Re-running it is fine (idempotent).

## 5. Sessions, slots, persistence

Both `cld` and `ocd` persist session history across container rebuilds —
slot files, SQLite DBs, JSONL logs all live on the host under
`~/.llm-docker/`. Wipe the container; every chat survives.

```
~/.llm-docker/
├── claude/
│   ├── .claude/                  ← ~/.claude inside container
│   │   ├── projects/<workdir>/   ← session JSONL files
│   │   ├── slot_1.id             ← slot 1's last-session UUID
│   │   ├── slot_2.id
│   │   └── settings.local.json   ← Claude permissions (template-seeded)
│   ├── .config/
│   └── .claude.json
└── opencode/
    ├── .config/opencode/         ← OpenCode config
    ├── .local/share/opencode/    ← OpenCode SQLite + slot_N.id
    │   └── opencode.db
    └── .cache/opencode/
```

**Slot rules:** each slot tracks its own "last session" independently.
`cld -c --slot 1` always reopens slot 1's last chat, even if slots 2-4 have
newer activity. Slot files are written on graceful exit (background watchdog
on Claude, signal trap on OpenCode), so even CMD+Q / crash preserves them.

**Parallel-launch caveat:** if you run `ocd --slot 1` and `ocd --slot 2`
from the same directory simultaneously, both share the SQLite DB and the
last-exiter's session may overwrite the earlier slot save. Avoid by using
separate workdirs per slot.

## 6. Tmux modes — when to use which

| Flag | Mode | Use when |
|---|---|---|
| (none) | direct shell | one chat, one window |
| `-t` | tmux-wrapped single session | want to detach/reattach with `Ctrl+b d` |
| `-tt [N]` | **team mode** — N panes in one container, shared FS | parallel agents on the same project |
| `-tr` | gavraz/recon dashboard | session-list TUI; opt-in via `INSTALL_TMUX_RECON` |
| `-tc` | Ark0N/Codeman web UI on `:3000` | mobile/SSH web access; opt-in via `INSTALL_TMUX_CODEMAN` |
| `-tcl` | nielsgroen/claude-tmux popup | quick popup overlay; opt-in via `INSTALL_TMUX_CLAUDE` |

`-t` / `-tt` / `-tr` / `-tc` / `-tcl` are mutually exclusive. The opt-in ones
auto-flip the conf flag and trigger a smart rebuild on first use.

In team mode (`-tt`) the **last pane** runs `claude --model haiku` (orange
border) — the cheap/fast runner slot for grep, lint, log-tails.

## 7. Builder API (host-side daemon)

The host-side daemon at `src/builder-api/` lets the container spawn host
processes (builds, tests, restarts) without baking your toolchain into the
image. One daemon per project, each on its own port from `[project.<n>].port`
in the host config; reachable from inside the container at
`host.docker.internal:<port>`.

**Config lives on the host only** at `~/.llm-docker/builder-api.toml`.
Per-project `.builder-api.toml` files are NOT read — the daemon refuses
to load anything from a project's working tree (security boundary).

**Schema:** three layers compose into the daemon's effective job table.

```toml
# 1. Global — every project sees these
[jobs.git-status]
command = "git"
args    = ["status", "--short"]

# 2. Language pack — opted into via `languages = [...]` in the project block
[language.php.jobs.phpunit-filter]
command = "vendor/bin/phpunit"
args    = ["--filter", "{test}"]
[language.php.jobs.phpunit-filter.placeholders.test]
regex   = "^[A-Za-z][A-Za-z0-9_:]*$"
required = true

# 3. Project — overrides + extras
[project.my-app]
root      = "~/Projects/my-app"
port      = 6701
languages = ["php", "compose"]
  [project.my-app.runtime]
    enabled       = true
    start_command = "php -S 0.0.0.0:8000 -t public"
  [project.my-app.jobs.deploy]
    command = "scripts/deploy.sh"
```

Resolution: later layers replace earlier ones by job name. `GET /jobs` returns
only the resolved set for THIS daemon's project. Copy
`src/builder-api/builder-api.host.toml.example` to get started.

**Endpoints (locked):**

| Method | Path | Purpose |
|---|---|---|
| GET | `/jobs` | Job catalog for this project (incl. `config_mtime`, `project`, `languages`) |
| POST | `/job/<name>` | Run a resolved job; `{params, agent_id}` body |
| GET | `/build_status?id=&wait=N` | Long-poll status (max 60s), `log_tail` on finish |
| GET | `/queue` | `{current, pending[], history[], total_history}` |
| DELETE | `/queue/<id>` | Cancel a pending build |
| DELETE | `/current/cancel` | Cancel the running build (kills entire process group) |
| POST | `/run` / `/stop` | Start/restart or stop the `[project.<n>.runtime]` process |
| GET | `/status` | Runtime PID + uptime + current build snapshot |
| GET | `/logs?file=&n=` | Tail an alias |
| GET | `/events?type=&since=&n=` | JSONL event feed |
| GET | `/ws` | Live event WebSocket |
| POST | `/log` | Browser-console tunnel (CORS-allowed) |
| POST | `/build` | **Removed** (410 Gone). Use `/job/<name>`. |

`?dryrun=1` on `POST /job/<name>` returns the resolved argv without
enqueueing. Auth: `X-Builder-API-Password: <pw>` header OR `?key=<pw>`
query string. Loopback bind reads are unauthenticated by default; non-loopback
forces password + `auth_reads = true`. Plugin support was removed entirely.

**Validation error shapes (locked):** 400 `validation_failed`, 404
`unknown_job`, 410 endpoint removed, 412 `command_hash_mismatch`, 412
`command_not_found`. See `src/builder-api/README.md` for full schema.

**Starter template:** `src/builder-api/builder-api.host.toml.example` —
global jobs + python/php/node/compose language packs + sample
`[project.<name>]` blocks. Copy to `~/.llm-docker/builder-api.toml` and
edit; the daemon reads only that host file.

**Cool boot output:** the daemon's terminal renders an ASCII banner +
color-coded event tail (▲ server_started, + build_enqueued, ▸ build_started,
✓ build_finished, ↻ config_reloaded). HTTP access logs dim into the
background; 4xx/5xx surface in red.

**Hot-reload:** the daemon polls `~/.llm-docker/builder-api.toml` mtime
every ~1.5s and re-resolves THIS daemon's project view. New jobs/aliases
apply to next enqueue. In-flight builds keep their snapshotted command +
timeout. Bind / port / runtime changes require a daemon restart.

## 8. env-gorilla integration

If you use [s3c-gorilla](https://github.com/RussianRoulette84/s3c-gorilla)
for KeePassXC-backed secret injection, `cld`, `ocd`, and `run-local.sh`
auto-detect it and re-exec themselves through `env-gorilla llm-docker --`
when:

- `USER=yaro` (always inject, gorilla overrides `.env`), OR
- `.env` is missing AND `env-gorilla` is on PATH (fallback for any user)

The re-exec is gated by an `LLM_DOCKER_ENV_GORILLA=1` env var to prevent
infinite loops. If you don't have env-gorilla installed, `setup_env()` seeds
`.env` from `.env.example` and you edit it directly.

For builder-api's `run-local.sh`, the re-exec uses `bash "$0" "$@"` rather
than bare `"$0"` — the script is intentionally non-executable (mode 0644)
and env-gorilla can't `exec()` it directly otherwise.

## 9. Codebase map — where to find what

```
llm-docker/
├── README.md                       ← user-facing reference
├── CHANGELOG.md                    ← version history
├── docs/                           ← deep-dives (you're reading 00 right now)
│   ├── anthropic/                  ← upstream Claude Code reference
│   ├── opencode/                   ← upstream OpenCode reference
│   └── tmux/                       ← tmux-specific docs
└── src/
    ├── cld                         ← HOST script: claude launcher
    ├── ocd                         ← HOST script: opencode launcher
    ├── install.sh                  ← one-shot installer wizard
    ├── setup.sh                    ← shared helpers (config, image, smart rebuild)
    ├── llm-docker.conf             ← build flags + runtime knobs (tracked)
    ├── .env.example                ← secrets template (.env is gitignored)
    ├── Dockerfile                  ← container image definition
    ├── docker/
    │   ├── docker-entrypoint.sh    ← runs inside container at start
    │   ├── install_cli.sh          ← claude-code + opencode + skills
    │   ├── install_devpack.sh      ← apt/cargo/go/gem/npm toolkits (gated by INSTALL_*)
    │   ├── zprofile                ← root's container shell init
    │   └── colorize.sh             ← banner gradient renderer
    ├── builder-api/                ← HOST-side Python daemon
    │   ├── server.py               ← HTTP routing + AppContext
    │   ├── config.py               ← host-toml schema loader + project view resolver
    │   ├── jobs.py                 ← [jobs.*] templates + validation + sha256
    │   ├── build_queue.py          ← FIFO worker, dedupe, snapshot-per-entry
    │   ├── hot_reload.py           ← mtime watcher
    │   ├── banner.py               ← boot ASCII + colored event tail
    │   ├── events.py               ← JSONL feed + live subscribe
    │   ├── runtime.py              ← /run /stop long-lived process control
    │   ├── security.py             ← AuthGate + rate limit + size caps
    │   ├── ws.py                   ← WebSocket
    │   ├── client.py               ← Python helper for in-container callers
    │   ├── run-local.sh            ← per-project launcher (passes --project)
    │   └── builder-api.host.toml.example  ← starter host config template
    ├── ascii/llm-docker.txt        ← shared banner art
    ├── lib/ywizz/                  ← TUI helpers (theme, prompts, animations)
    └── multi-llm-docker.applescript ← macOS multi-window grid layout
```

## 10. Adding features — common extensions

### Add a new CLI tool to the container

1. Append to the appropriate `SW_*_APT` / `_NPM` / `_GEM` array in
   `src/docker/install_devpack.sh` (or the always-on tools at the top of
   `src/Dockerfile` if it's a base-image dep).
2. If it's gated, add an `INSTALL_*` flag in `src/llm-docker.conf`.
3. Run `cld --build` (smart rebuild — re-runs the install scripts inside
   the existing image and commits).
4. Re-launch `cld` to verify.

### Add a tmux helper (recon-style)

1. Set `INSTALL_TMUX_<NAME>=true` in `src/llm-docker.conf`.
2. Add the install logic to `src/docker/install_devpack.sh` gated on the
   flag (with skip-if-installed idempotency — see existing recon/codeman
   blocks).
3. Add a launcher case in `src/cld` (and `src/ocd` if applicable).
4. Wire it through `src/docker/docker-entrypoint.sh` so the container
   actually launches it.
5. Document in README + CHANGELOG.

### Add a builder-api job to your project

```toml
[jobs.<name>]
command   = "..."                   # absolute path, ./relative, or PATH lookup
args      = ["--flag", "{value}"]   # placeholders MUST be standalone array elements
timeout_s = 60                      # default 60
sha256    = "<hex>"                 # optional integrity pin
[jobs.<name>.placeholders.value]
regex     = "^[A-Za-z]+$"            # required
max_len   = 200                      # default 200
required  = true                     # default true
```

Save → daemon hot-reloads within ~2s → `POST /job/<name>` is live.

## 11. Troubleshooting — known failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `sleep: invalid time interval 'Read ./CLAUDE.md...'` on launch | Smart rebuild committed an image with `ENTRYPOINT=["sleep"]` (pre-fix bug, fixed in v2.2). | `cld --rebuild-force` once. |
| `Permission denied` exec'ing `run-local.sh` via env-gorilla | Script is 0644 (non-executable). | Already fixed: re-exec uses `bash "$0" "$@"`. |
| `[builder-api] CONFIG ERROR: host config not found` | No `~/.llm-docker/builder-api.toml`. | `cp src/builder-api/builder-api.host.toml.example ~/.llm-docker/builder-api.toml` and edit. |
| `[builder-api] CONFIG ERROR: no [project.<name>]` | Daemon launched with `--project <X>` but the host toml has no matching block. | Add `[project.<X>] root=... port=...` to the host toml. |
| `cld --tt 3` does nothing useful | `--tt` (double dash) doesn't match the case statement. | Use `-tt 3` (single dash). |
| Smart rebuild's "fallback to full build" is silently a no-op | Pre-existing bug: `setup_image` skips when image exists. | If `cld --build` fails, run `cld --rebuild-force`. |
| Mac daemon doesn't pick up Python edits | Hot-reload only watches `~/.llm-docker/builder-api.toml`, not Python source. | `pkill -f builder-api/server.py` then re-launch via `cld -a` (or `python3 src/builder-api/server.py --project <name>`). |

## 12. Hard rules (from project CLAUDE.md)

These apply to anyone editing this repo, including AI agents:

- **Never use `rm`.** Use `trash` (host) or `send2trash` API. The bind-mounted
  `~/Projects/` folder writes back to host — a misplaced `rm -rf` is
  catastrophic.
- **Never delete contents of mirrored folders.** Inside-container deletes
  show up on host immediately.
- **Never run `install.sh` from inside the container.** It's host-side.
- **Never manage docker (`docker run/stop/rm`) without explicit permission.**
  Operator-only.
- **Question mark rule:** if the message is a question (`?`), text-only
  response is fine — no tool calls required.
- **Reporting rule:** every task-completing response must end with the
  4-line summary block (`Request / Done / Concerns / Success / Next steps`).
  Multiple agents run in parallel; without it the operator can't tell who
  did what.

## 13. Where to go next

- **README.md** — full reference for users (flags, env vars, mount table,
  SSH, builder-api summary).
- **src/builder-api/README.md** — full builder-api API reference (validation
  shapes, /jobs schema, hot-reload behavior, sha256 pinning, examples).
- **CHANGELOG.md** — version-by-version delta. v2.2 lands the `[jobs.*]`
  templates + cool banner; v2.1 adds smart rebuild + browsing stack; v2.0
  is the big refactor.
- **CLAUDE.md** (project root) — the hard rules + boot sequence for AI
  agents.
- **`.claude/PARALLEL_AGENTS.md`** — orchestrator routing for multi-agent
  workflows. (May not exist yet — was referenced in CLAUDE.md as TODO.)

If you're stuck, the agents in `.claude/agents/` are subagent prompts —
useful examples of how this project leverages Claude in roles beyond chat.

---

*Last updated: v2.2 (2026-05-05). When you make a meaningful change to
how llm-docker boots / configures / rebuilds, update this doc and the
CHANGELOG.*
