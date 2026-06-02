# v2.5 (2026-06-02)

One password per macOS boot covers every project. Container sees every secret your shell has. Default install is lean.

## llm-docker cage

- [NEW] Launch `cld` (or `ocd`) from any project folder — env-gorilla now loads the cage-wide `llm-docker` secrets AND that project's own secrets in ONE go, no extra password or fingerprint prompts compared to launching from llm-docker itself. Same for the builder-api when you pass `-a`. Powered by env-gorilla v0.12's new merge mode.
- [NEW] Every variable in your launching shell flows into the container — not a hardcoded list. Add a new secret to your vault, it just shows up.
- [BUG] `cld` was silently asking for the master password on every launch even when secrets were cached. The pre-check that detected per-project profiles was the culprit. Killed. No more phantom prompts.
- [CHANGE] Same env-passthrough now applies to `ocd` (OpenCode launcher) — was still on the old 8-secret allowlist. Brought to parity with `cld`.
- [CHANGE] The `~/.zprofile` bind-mount and auto-sourcing into spawned shells were causing trouble and got disabled. Side effect: PATH for tools installed under `~/.config/composer/vendor/bin` (Envoy) doesn't auto-inherit anymore.

## Setup & Install

- [BUG] `./install.sh` had a wrong helper-library path and crashed at boot — fixed.
- [CHANGE] Lean defaults: media, security, ruby, cpp, llvm/clang, ns, vanilla tmux all off in `llm-docker.conf` unless you opt in.

### Dev logs

- [NEW] `src/cld`, `src/ocd`, `src/builder-api/run-local.sh` all switched from nested `env-gorilla A -- env-gorilla B -- ...` to a single `env-gorilla A,B -- ...` call (env-gorilla v0.12 comma syntax). One merged chip-blob → one Touch ID per launch instead of two.
- [BUG] `src/cld` was calling `env-gorilla --list 2>/dev/null | grep -qw -- "$_proj_name"` as a profile-existence pre-check. `--list` itself invokes `ask_master_pw`, and its stderr was redirected — so the prompt was invisible but `read -rs pw` still consumed master-pw input from the TTY every launch. Removed; env-gorilla now warns-and-continues on missing profiles, no pre-check needed.
- [CHANGE] `src/cld` and `src/ocd` both compute `_profiles="llm-docker,<basename>"` if the project's basename differs from `llm-docker`, else just `llm-docker`. Single `exec env-gorilla "$_profiles" -- "$0" "$@"`.
- [CHANGE] `src/cld` `run_claude_container` already had a blanket `env`-output scan replacing the 8-line `-e ANTHROPIC_API_KEY` allowlist. `src/ocd` `run_opencode_container` now uses the identical scan. Names validated against `^[A-Za-z_][A-Za-z0-9_]*$`, 12 patterns blocklisted (PATH, HOME, TMPDIR, PWD, OLDPWD, SHELL, USER, LOGNAME, HOSTNAME, SHLVL, LD_*, DYLD_*, LLM_DOCKER_ENV_GORILLA).
- [TWEAK] `docker-entrypoint.sh` — `. /root/.zprofile` sourcing AND `exec zsh -l` drop-to-shell commented out.
- [TWEAK] `Dockerfile` baseline `.zshrc` no longer sources `$HOME/.zprofile`; bind-mount comments removed.
- [TWEAK] `ocd` — dropped the `docker/zprofile:/root/.zprofile:ro` bind.
- [BUG] `install.sh` — `$SCRIPT_DIR/src/lib/ywizz/ywizz.sh` → `$SCRIPT_DIR/lib/ywizz/ywizz.sh` (extra `src/`).
- [BUG] `src/lib/ywizz/task.sh` had a half-edited line with an unclosed quote + `#BUG HERE FICX ME` debug copy — restored the working `printf` call.
- [CHANGE] `llm-docker.conf` defaults flipped to `false`: `INSTALL_MEDIA`, `INSTALL_SECURITY`, `INSTALL_RUBY`, `INSTALL_CPP`, `INSTALL_LLVM_CLANG`, `INSTALL_NS`, `INSTALL_TMUX_VANILLA`.
- [CHANGE] s3c-gorilla bundled into this repo at `s3c-gorilla/` (env-gorilla v0.12 with comma syntax).

# v2.4 (2026-05-13)

Builder API tightened so a project can't author its own host commands anymore. Plus the chromium-leak fix, a working monorepo story, and a pile of small polish.

## Builder API — security

- [CHANGE] Every command Claude can run on your Mac now lives in a single host file: `~/.llm-docker/builder-api.toml`. Per-project tomls are no longer read. One file to audit, no project can sneak a new command past you.
- [CHANGE] The plugin feature is gone. It let a project drop a Python file that ran with full host access — too much trust for a sandbox. No replacement; the surface is closed.
- [CHANGE] Editing the host toml no longer takes effect automatically — kill the daemon and `cld` will relaunch it. Why: an in-container agent could otherwise talk you into running a script that silently widened what it's allowed to run.
- [NEW] Mark destructive jobs with `mutates_filesystem = true`. Callers then have to send an explicit confirmation header on top of the password — so a contract-test loop can't accidentally fire `prettier --write` and reformat 300 files before you can cancel.
- [NEW] Pin a script's sha256 in the toml with `command_hash`. The daemon refuses to run it if anyone touches the file.
- [NEW] `{{container}}` token in job args — resolves at request time to whichever Docker container belongs to this project. Lets `docker exec` wrapper jobs survive container restarts.
- [NEW] Per-job `cwd = "<subdir>"` for monorepos. Frontend in `angular/`, api in `api/`, both share the same daemon.
- [NEW] Unknown fields or stale `plugin = ...` keys in the toml now warn loudly at startup instead of being silently ignored. Catches typos the moment the daemon boots.

## Builder API — reliability

- [BUG] Killed browser jobs no longer leave a 1 GB chromium running. The whole bash → node → chromium chain dies together.
- [BUG] Cancelling a build now waits until the job has actually stopped before replying, instead of returning the moment the kill signal was sent. The reply also tells you how it exited.
- [BUG] Cancelled jobs were showing as "failed" in the history. Now they show as "cancelled".
- [BUG] Jobs running in a subdir (`cwd = "api"` + `command = "vendor/bin/phpunit"`) were failing with "command not found". They find the binary now.
- [NEW] Cancel the running job without killing the daemon.

## Builder API — visuals

- [BUG] Builder-api pane was blank in narrow iTerm splits. Now shows a compact ASCII frame.
- [BUG] After exiting Claude and relaunching, `cld -a` was opening a fresh builder-api pane instead of reusing the existing one. Now finds the pane by which port the daemon is on.
- [NEW] Daemon prints every job it knows about at startup, right under the banner. First thing you see when it boots.
- [TWEAK] Project name highlighted in pink so two projects' panes are easy to tell apart at a glance.

## llm-docker cage

- [BUG] After `cld --build`, the next launch was crashing with `sleep: invalid time interval`. The smart-rebuild was accidentally baking the build's temporary entrypoint into the image. Fixed.
- [NEW] `cld --rebuild-force` — full rebuild from the Dockerfile when you want a clean slate. `--build` is now the fast smart-rebuild.
- [TWEAK] First time you use a tmux flag (`-tr`, `-tc`, `-tcl`), the matching install flag flips on in your config and the image smart-rebuilds. No more full rebuild for a tmux flavor switch.

## Browsing

- [NEW] Chromium is now pre-installed in the image, so Playwright works on first launch without a 60-second download. Also works on Linux arm64 (which Playwright's default channel doesn't support).
- [TWEAK] Headful + headless chromium are gated behind `INSTALL_BROWSING=true` in `llm-docker.conf`.

## PHP toolchain

- [NEW] PHP 8.3, Composer, and Laravel Envoy now ship in the image (`INSTALL_PHP=true` + `INSTALL_PHP_ENVOY=true`, both on by default). Run `envoy run deploy` from inside the container with nothing installed on the Mac. ~80 MB on the image.

## Shell & UX

- [NEW] True-color terminals: `COLORTERM=truecolor` is set on every container launch, so claude / opencode / any modern TUI gets the 24-bit palette.
- [BUG] Commands installed under `~/.config/composer/vendor/bin` (Envoy, etc.) were "command not found" in Claude's Bash tool even though they worked in interactive shells. Every child shell now inherits the full PATH. (Note: rolled back in v2.5 — see v2.5 entry.)

## Examples / templates

- [CHANGE] Old bundled examples replaced with two clean public starters: `python-example/` (FastAPI + pytest) and `php-example/` (PHP built-in + PHPUnit). Both ship with the 5 standard MCP servers pre-wired and a README walking the integration.

### Dev logs

- [TWEAK] `src/builder-api/config.py` rewritten — drops per-repo file discovery, parses the layered host schema, resolves `[jobs.*]` ∪ `[language.<lang>.jobs.*]` ∪ `[project.<name>.jobs.*]` for the daemon's project at boot.
- [TWEAK] Hot-reload subsystem deleted: `src/builder-api/hot_reload.py` trashed, `ConfigWatcher` import + `_apply_reload` callback + watcher start/stop removed from `server.py`. Daemon's `Config` is immutable for the process lifetime.
- [TWEAK] `server.py main()` parses `--project <name>` / `--config <path>`; `run-local.sh` derives `<name>` from `$(basename "$project_dir")`; `cld` / `ocd` pass it through.
- [TWEAK] `cld` / `ocd` read project port from `[project.<name>].port` in the host toml via an inline awk parser, falling back to `llm-docker.conf` then 6666.
- [TWEAK] `cld` / `ocd` add `--label "llm-docker-project=$CWD_BASE"` on every `docker run` so the daemon's `{{container}}` substitution can find the per-project container via `docker ps --filter label=...`.
- [TWEAK] `builder_api.applescript` gained `findSessionByPort()` (lsof → ps → match iTerm tty); old title-only lookup kept as fallback.
- [TWEAK] Deleted `src/builder-api/plugin.py`, the dead `.builder-api.toml` at repo root, and `src/builder-api/examples/*`; migrated `lint-shell` + `syntax-py` into the starter template's `[project.llm-docker]` block.
- [TWEAK] `command_hash` is now a table — `{ path = "<rel-path>", sha256 = "sha256:<64-hex>" }` — so wrapper jobs (`command = "docker"`, `args = [..., "<script>"]`) pin the wrapped script, not the volatile docker binary.
- [TWEAK] `POST /build` returns 410 Gone with a pointer to `POST /job/<name>`. Legacy `enqueue()` + `_validate_args()` removed from `build_queue.py`; `BuildCfg.command` + `allowed_args` dropped from `config.py`.
- [TWEAK] `/queue` history shrunk from ~3 KB per entry to ~200 B by dropping log tails (full log still at `/build_status?id=<id>`); added `total_history` count.
- [TWEAK] `resolve_command()` now tries `<project_root>/<cwd>/<command>` first, then `<project_root>/<command>`, with `resolve()`-based symlink-escape rejection on both. `verify_command_hash()` passes `job.cwd` through.
- [TWEAK] `cancel_current()` blocks on `entry._done.wait(timeout=15.0)` after `_kill_process_group`, so the API contract matches reality.
- [TWEAK] `mutates_filesystem` gate enforced in `server._ep_job_post` between dryrun and enqueue; returns 428 + `{error, job, reason, fix}` when the header is missing.
- [TWEAK] `banner.show_banner()` signature accepts the job-name list (was: count); wraps to terminal width with 4-space hang for continuation lines.
- [TWEAK] New starter template at `src/builder-api/builder-api.host.toml.example`.
- [TWEAK] `src/docker/docker-entrypoint.sh` sources `/root/.zprofile` before the `TOOL=` dispatch, so claude / opencode and every spawned shell start with the full PATH.
- [TWEAK] `install_devpack.sh` PHP block: PHP 8.3 from packages.sury.org, Composer via upstream installer, Envoy via `composer global require laravel/envoy` with `COMPOSER_ALLOW_SUPERUSER=1` + post-condition check. `src/docker/zprofile` adds `$HOME/.config/composer/vendor/bin` to PATH.
- [TWEAK] Added `PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright` to Dockerfile + idempotent install in `install_devpack.sh`.
- [TWEAK] Added `.Trash-*` to `.gitignore`.
- [TWEAK] Imported develop branch into master (merge of sleep-bug fix + v2.3 security pass).

# v2.3 (2026-05-07)

## Stability

- **`cld` no longer crashes Docker Desktop when launched in many terminals at once.** With 30+ open terminals, parallel `cld` calls were all firing `open -a Docker` simultaneously. The second/third launch event arrives mid-startup and Docker Desktop dies with `NSInternalInconsistencyException: Unrecognized event type 0` (an AppKit thread-safety bug in Docker's Go bridge, hits hardest on macOS Sequoia 15.6+). Wrapped the whole "is Docker up? if not, start it and wait" block in a `flock` on `/tmp/cld-docker-start.lock` so only one `cld` ever launches Docker; the rest wait, then no-op when they re-check inside the lock. Requires `flock` (`brew install flock`); without it `cld` warns once and falls back to the old racy behavior so it still runs.

## Security

Hardening pass focused on closing two bind-mount escape paths a compromised or prompt-injected project could otherwise walk into:

- **Builder API plugin gate** (`src/builder-api/config.py`): declaring `plugin = "..."` in a project's `.builder-api.toml` now requires `BUILDER_API_ALLOW_PLUGINS=1` in the daemon's environment. Without it, the daemon refuses to start with a `ConfigError` pointing to the variable. Plugins run unrestricted Python in the daemon process on the host — this forces a deliberate human step before any project (or a Claude inside one) can pivot to host code execution by dropping a `builder_plugin.py` and editing the toml. Existing users with a plugin: export the env var in `run-local.sh`'s shell or in `.env`.
- Added `deny`: `Read/Edit/Write(**/llm-docker/**)` so projects can't read or modify the cage source from inside the container.
- Added container-escape denies: `*nsenter*`, `*docker.sock*`.
- Fixed malformed `WebFetch(domain:github.com/sst/opencode)` → `WebFetch(domain:github.com)` — domain patterns ignore the path component,
so the `/sst/opencode` part was silently doing nothing.
- Added `Monitor`, `Task*`, `ToolSearch` to the default allow list.
- **Repo's own `.claude/settings.local.json`** got the same hardening so working in this repo follows the same boundary the template ships
to projects.

# v2.2 (2026-05-06)

## Builder API 

Tested and works with Job templates. You can connect this API to your project MCP that Claude Code uses.

- **`[jobs.<name>]` blocks** with pattern-validated parameters, length caps, optional integrity pin.
- **Hot-reload**: edit config, daemon picks it up in ~1.5s.
- **Dedupe window**: same op twice in 5s collapses onto one job.
- **`?dryrun=1`**: returns what would run, without running.
- **`GET /jobs`** introspection with `config_mtime` for cache invalidation.
- **Locked error shapes** (400 / 404 / 412).
- Examples bundled: Node, PHP+compose, sample game project.

# MiSC
- [BUG FIX] launchers crashed on default macOS bash with `bad substitution`. Swapped for portable.
- [NEW/OPTIONAL] **env-gorilla auto-injection**: no local secrets file → reach for `env-gorilla` if installed. Works
for `cld`, `ocd`, and the builder-api launcher.

## Daemon stability

- [BUG FIX] Ctrl-C now actually exits (was deadlocking).
- [BUG FIX] finished builds crashed the response (deep-copy on a lock).
- [BUG FIX] empty argument whitelist now means "none allowed", not "any allowed".

## Onboarding doc + examples + repo-level config

- **`docs/00-LLM-DOCKER.md`**: read-this-first doc.
- Per-stack example configs (Node / PHP+compose / sample game).
- Repo-level config with two dev sanity-check jobs.

# v2.1 (2026-04-25)

## New
- **Browsing stack**: New `INSTALL_BROWSING` build-time flag (default `true` in `llm-docker.conf`). When on:
  - apt-installs `chromium-headless-shell` (no-systemd headless build for HyperFrames + automation) and `chromium` (full headful browser for Xvfb / X11 setups). A `policy-rc.d` shim is dropped during install so chromium's `invoke-rc.d`-based post-install doesn't dpkg-exit-1 inside non-systemd containers.
- **hyperframes** is added by default because it's so cool (if INSTALL_BROWSING==true)
- **Smart `--build` + new `--rebuild-force`**:
  - `cld --build` / `ocd --build` no longer wipes the image. Instead it spins a temp container off the existing image, copies the latest `install_cli.sh` + `install_devpack.sh` + `llm-docker.conf` in, re-runs them with skip-if-installed guards, and `docker commit`s the result. Heavy stuff (5×Go installs for security tooling, recon/claude-tmux cargo builds, codeman, omz/p10k clones, ferox/nikto, npm globals) gets skipped when already present — so flipping a single `INSTALL_*` flag rebuilds in seconds instead of half an hour.
  - `cld --rebuild-force` / `ocd --rebuild-force` is the old `--build` behavior: `docker rmi` + full `docker build` from the Dockerfile. Use when smart-rebuild cruft is piling up or you've edited the Dockerfile itself.
  - `install_cli.sh` and `install_devpack.sh` are now idempotent: every Go install / cargo install / curl|bash installer / git clone / npm-global / hyperframes skill add checks for an existing binary, marker file, or directory before doing work.

## Bug fixes
- `llm-docker/src/llm-container-claude-settings.json` was for my local setup accidentally. Now it's no restrictions.
- **Honest build progress bar**: the docker-build spinner's percentage is now driven by counting actual completion markers in the build log (apt's `Setting up <pkg>`, npm's `added N packages`, pip/gem's `Successfully installed`, cargo's `Installing /…`, git's `Resolving deltas: 100%`) divided by a pre-computed total of install ops parsed from the Dockerfile + `SW_*_APT` arrays + the enabled `INSTALL_*` flags. No more wall-time guesses; no more "90% then back to 60%" jumps.

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
