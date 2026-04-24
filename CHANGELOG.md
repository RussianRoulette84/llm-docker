# v2.0 (2026-04-24)

Huge update. Big refactor. Many cool features.

## Setup & Install
- 📦 **One-command installer** (`install.sh`): Creates dirs, walks the user through workspace bind-mount config + API keys + behavior toggles, builds image, links `cld`/`ocd` to PATH. Works via `curl` pipe.

## New `cld` / `ocd` flags
- added `--clean` flag to remove leftover llm-docker containers before launch
- added `cld --danger` flag to run Claude unrestricted
- added `--build` flag to force a fresh image rebuild
- added `--slot N` flag for tagged session save/restore (N parallel chats per project)
- added `--delay <sec>` flag to space out window openings in multi-window launches
- added `-a` / `--api` flag to spawn builder-api in a separate terminal

## Claude
- `.claude/settings.local.json` with extensive allow/deny list as an extra security layer
- **security**: minor Claude `deny` permission tweaks

## Boot prompt
- per-project `BOOT.md`: if present in the workdir, its contents are injected as the first-message prompt on fresh sessions. Falls back to the old "Read ./CLAUDE.md …" default when only `CLAUDE.md` exists.

## Mounts
- `DOCKER_DIR` default flipped from `/root` to `/root/Projects` so container paths mirror the host (`~/Projects/foo` → `/root/Projects/foo`) even when CWD is outside `WORKSPACE_DIR`
- `~/.tmux.conf` (host) → `/root/.tmux.conf` (ro) — auto-bound if the file exists; your keybindings follow you in
- `~/.p10k.zsh` (host) → `/root/.p10k.zsh` (ro) — auto-bound if the file exists; suppresses the Powerlevel10k config wizard on every new shell / tmux pane
- `README.md` → `/opt/llm-docker/README.md` (ro) — source of the banner's version string

## Refactor
- 📁 **`docker-compose`**: removed
- all non-sensitive settings moved from `.env` to `llm-docker.conf` (new)
- `logs` support (install, docker logs)
- 📁 **`src/`**: every source file moved out of the repo root into `src/`
- 📁 **`docs/`**: added with Claude/OpenCode documentation (2026-04-20)
- 📁 **`.claude/` and `CLAUDE.md`**: added (instead of `./agents` and `AGENTS.md`)

## Directory Mounting Security
- Persistent `~/Projects` workspace bind mount is **OPT-IN** via `WORKSPACE_DIR`/`DOCKER_DIR` in `.env`. Default: each `cld`/`ocd` invocation mounts ONLY the current directory — the LLM can't see sibling projects.
- Guard rails: `WORKSPACE_DIR` / `DOCKER_DIR` refuse `/`, `$HOME`, `/Users`, system dirs, and anything shallower than 3 segments. Server won't start with an unsafe pair.

## Persistence Mount Narrowing
- Replaced the broad `~/.llm-docker/claude:/root` bind with three targeted mounts (`.claude/`, `.config/`, `.claude.json`). Container's `/root` outside those is now ephemeral.
- Pre-existing clobber bug fixed: `docker-entrypoint.sh` no longer overwrites an existing `.claude.json` on every API-key run.

## Shell & UX
- OH-MY-ZSH is the default shell environment (autocomplete, fzf, p10k)
- custom `zprofile` added
- ASCII banner at container boot, version auto-pulled from `README.md`
- Docker-build spinner now summarizes BuildKit output (`installing apt packages`, `installing claude-code`, …) instead of dumping raw `RUN` commands

## TMUX godness
- customized for working with AI with many tmux setup variations (Team `-tt`, Recon `-tr`, Codeman `-tc`, claude-tmux `-tcl`)

### Multi-Session Management (slot system) <- Claude + OpenCode
- **Session restore**: `cld -c 4` / `ocd -c 4` opens 4 terminals and restores previous sessions. Bare `cld 4` / `ocd 4` starts fresh but still saves on exit.
- **Session slot system** (`cld --slot N` / `ocd --slot N`): each terminal gets a numbered slot that auto-saves and restores its session ID independently. N parallel chat chains per project.
- **Per-tool discovery**: cld diffs `.claude/projects/*.jsonl` snapshots at start/exit; ocd queries the OpenCode sqlite DB (`session WHERE directory=... AND time_created > baseline`). Same UX, different backends.
- `cld --slot 1 -c` → resume slot 1's last Claude session. `ocd --slot 1 -c` → same for OpenCode.
- Graceful cleanup via background watchdog (cld); trap-based save on clean exit (ocd).

## Container-Exit Behavior
- [BUG FIX] now it properly kills containers on terminal close, CMD+Q, or crash.
- `EXIT_TO_DOCKER` in `.env`: when `true`, exiting Claude/OpenCode drops to a bash shell INSIDE the container for post-mortem / poking around. Default `false` keeps the old "exit tool → exit container → back to host" flow.

## Multi-Window layout on macOS (extra)
- **Pro multi-window layout (macOS)** (`src/multi-llm-docker.applescript`): `cld 4`, `cld 8 -c` — auto-detects monitors and arranges terminals in 2-column grids. Skips middle monitor on 3+ screen setups.

## Builder API (optional) - IN-PROGRESS
- Full host-side daemon in `src/builder-api/`: build queue + long-poll status + log tailing + JSONL event feed + runtime control + WebSocket live streaming + browser-console tunnel.
- Security: single predefined build command + `allowed_args` whitelist, `execvp`-only execution, project-root-scoped paths, password auth, failed-auth rate limit, queue cap, request-read timeout, drop-oldest WS back-pressure, CORS scoped to `/log`.
- Config: declarative `.builder-api.{toml,yml,json}` per project. Optional Python plugin drop-in for custom endpoints.
- Launch from `cld --api` / `ocd -a` (spawns server in a new Terminal on macOS; backgrounds on Linux).

## SSH support (optional) - IN-PROGRESS
- Communicate with Claude inside Docker through SSH (useful for Claude orchestrating apps, like `Quake 3 IDE` for macOS or even VSCode). Public-key auth only (passwords disabled).
- Slot-based SSH host ports: `cld --slot N` → 8884 + (N - 1), so parallel containers don't collide on one port.

# v1.2 (2026-03-03)

- **Claude Code support**: New `cld` wrapper for Claude Code CLI in Docker; persistent data in `~/.llm-docker/claude`.
- **Entrypoint**: `docker-entrypoint.sh` switches between OpenCode and Claude based on `TOOL`.
- **ENV-driven config**: Docker Compose reads `.env` for `WORKSPACE_DIR`, `TOOL`, sandbox settings, etc.
- **Node 24**: Base image updated from Node 22 to Node 24.
- **Config**: `opencode.config.jsonc` tweaks; `.env.example` expanded with Claude Code options.

# v1.1 (2026-02-03)

- **Premium Branding**: New badges, logo, and professional README overhaul.
- **Better Routing**: Full support for path arguments and flag passthrough.
- **Saner Exits**: Immediate container exit on completion or Ctrl+C.
