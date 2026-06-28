# v2.9 (2026-06-19)

## API
- [NEW] Live config reload. No restart needed.
- [BUG] Build logs no longer leak the previous job's output.
- [TWEAK] Build long-poll tells you which timed out: the wait, or the build.

## API — visuals
- [TWEAK] Status panel moved to top-right of the split and auto-sizes to actual content height — no more 15-empty-row gap.
- [BUG] Running `cld -a` twice for the same project no longer creates a duplicate right panel; existing pane is reused.
- [BUG] First-typed line in the right pane no longer comes out as `?bash` (was an iTerm timing issue with multi-pane splits).

## cld & ocd
- [NEW] `cld -c` and `ocd -c` now resume the session that started in THIS iTerm pane — not the most-recent session globally. Each pane gets its own session pin.
- [NEW] `--refresh-env` flag — wipes env-gorilla's cached secret blob before re-exec so newly-added KeePassXC keys actually reach the container.
- [CHANGE] `--dangerously-skip-permissions` is ON by default. `--safe` (or `--no-danger` / `--no-dg`) turns it off.

## Jobs
- [NEW] iOS simulator app restart (terminate + relaunch booted-sim app, no rebuild).
- [NEW] Marketing-site build + deploy via Envoy (Eleventy projects).
- [NEW] Named deploy aliases for the `deploy?platform=*` verbs — for clients that can't send query params.
- [NEW] Clean dependency reinstall (`npm ci --include=dev`) — heals half-gutted `node_modules`.
- [NEW] Redis service jobs (start / stop / restart / status / tail via brew services). Also wired as a `redis` platform on the `up` / `down` / `restart` verbs.
- [CHANGE] Multi-subproject repos with a `src/` layout supported — project-shard paths can prefix cleanly.

### Dev logs
- [NEW] `server.py:_start_config_watch()` — polls api_config mtimes every 1.5s. `_reload_config()` swaps `cfg`, emits `config_reloaded` (added/removed/verbs_changed), reprints banner. Parse fail → `config_reload_failed`, prior `cfg` kept.
- [CHANGE] `build_queue.py` — `BuildEntry.log_start_offset` snapshotted before launch. `_tail_text(start_offset=…)` scopes reads. `wait()` returns `poll_timed_out` + `build_timed_out`; legacy `timed_out` aliased.
- [NEW] `compose-exec` — regex enum `^(verify|phpinfo|redis-ping|mysql-version|tail-errors|php-lint-changed)$`. Service hard-coded `workspace`. `bash -c … "$1".sh -- {snippet}` shape.
- [NEW] Per-terminal session tracking in cld + ocd. TSV maps `(terminal_id, project_path, session_id)` keyed by `ITERM_SESSION_ID` → `TMUX_PANE` → `tty`. cld scans newest `*.jsonl`; ocd queries `opencode.db`.
- [NEW] `--refresh-env` strips itself from `$@` before re-exec to avoid loops; runs `env-gorilla --clear "$_profiles"` first.
- [BUG] `builder_api.applescript`: each pane's `write text` must run IMMEDIATELY after its split. Multi-pane setup writes builder-api first, then 0.5s delay, then status pane on the second split.
- [BUG] Bash-level orphan-kill removed from cld; moved into applescript's post-reuse-check path. Reuse-by-port skips `reuseCmd` when daemon is alive (just focuses pane).
- [NEW] cld-status calls `osascript … set rows` on its own iTerm session via `ITERM_SESSION_ID` after each render.
- [CHANGE] `verb.up` / `verb.down` / `verb.restart` `platforms` lists extended with `"redis"`.
- [TWEAK] Prompt-submit hook rewritten to `printf '%b\n'` with multi-line reminder content.

# v2.8 (2026-06-19)

Generic commands across every project, per-project settings, and a live status panel.

## API — verbs
- [NEW] One command vocabulary across all projects: `up`, `down`, `restart`, `build`, `lint`, `test`, `logs`, `status`, `deploy`. Each takes a platform (`ios`, `android`, `web`, `api`, `mobile`, `desktop`) and the right tool fires for that project. Wrong platform? Clear list of what's actually supported.
- [NEW] `GET /jobs` returns a `verbs` block listing the platforms each project actually implements, so clients can offer the right options up front instead of trial-and-error.
- [CHANGE] Job dispatch treats verbs as routers: a verb job has no command of its own; its leaves (one per platform) carry the actual command, regex-validated placeholders, hash pin, and mutation gate. Security stack unchanged — only the resolution step is new.

## API — config layout
- [NEW] Per-project settings now live in their own files. Editing one project can't break another.
- [NEW] `tomlify.sh` installer (in `src/builder-api/`) — one command copies everything into place. Run with no args to install all, or pass a project name. Non-interactive overwrites — no `cp -i` prompt.
- [CHANGE] Repo layout: `api_config/builder-api.toml` (base) + `api_config/<name>.toml` (shards). Same shape on the host at `~/.llm-docker/api_config/`.
- [CHANGE] Shards may only contain `[project.<name>]` tables. Declaring `[jobs.*]`, `[language.*]`, `[verb.*]`, or `[defaults]` in a shard is a startup error.
- [CHANGE] Cross-shard duplicate jobs are a startup error (with both filenames named), not silent last-wins.

## API — security
- [NEW] Shard symlinks rejected outright. World-writable shards rejected. Group-writable warned.
- [NEW] Shard filename `<name>.toml` must match the `[project.<name>]` key inside.
- [NEW] Mutation gate now accepts `?confirm=yes` on the URL as an alternative to the `X-Mutation-Confirmed: yes` header — for HTTP proxies and MCP wrappers that can't set custom headers. Header still preferred.

## API — visuals
- [TWEAK] Right side panel reprints itself when you resize the pane or terminal. Banner + event tail always match the current width.
- [TWEAK] Live event tail no longer shows successful HTTP requests under load. Build events still surface; 4xx / 5xx HTTP still surface in red. `BUILDER_API_HTTP_VERBOSE=1` brings the old chatter back.
- [TWEAK] Right pane width slimmer (40 columns). Outer iTerm window keeps its existing size when the pane opens.

## llm-docker cage
- [BUG] `cld -a` was sometimes opening a panel that immediately died with "address already in use", because the port lookup only read the base toml and missed the per-project shards. Reads shard first now.
- [BUG] When the API port is already bound by another terminal's daemon, `cld -a` / `ocd -a` now detect it and skip opening a new pane (the existing one is still serving). Before, a redundant pane would open and immediately fail.
- [BUG] `ocd` couldn't safely run in parallel with `cld` against the same Docker Desktop. Simultaneous `open -a Docker` calls would crash Docker on macOS Sequoia. Both tools now serialize through the same file lock.
- [NEW] `cld-status` script — slim live status panel. Per running container: 5-min CPU sparkline, memory bar, network rates, uptime, process count, Claude session size as a context-usage proxy. Footer counts Chromium and Playwright processes. Adjustable refresh + sparkline width.

### Dev logs
- [NEW] `src/builder-api/config.py` — `_merge_project_shards()` globs `~/.llm-docker/api_config/*.toml` (excluding `builder-api.toml`), validates each, deep-merges into `raw["project"]`. `_parse_verbs()` parses `[verb.*]` into `VerbSpec`. `Config` gains `verbs` + `shard_paths` fields.
- [NEW] `src/builder-api/jobs.py` — `_parse_hub_job()` parses jobs whose body is a `platforms` sub-table. `Job.platforms` carries the per-platform leaf map. `Job.is_hub` is the dispatch flag. Nested hubs rejected; mixing hub + leaf fields rejected.
- [NEW] `src/builder-api/server.py` — `_ep_job_post()` dispatches hub jobs by `?platform=...`, returns `400 missing_param` / `400 platform_not_declared` / `404 verb_not_implemented` with the exact list of implemented platforms. `_ep_jobs()` exposes the verbs block. Mutation gate also accepts `?confirm=yes`. SIGWINCH clears + reprints the banner on resize. `log_message()` suppresses 2xx from stderr unless `BUILDER_API_HTTP_VERBOSE=1`.
- [NEW] `src/cld-status` — Python stdlib only, polls `docker stats` every 5s, sparklines + mem bars + net rates + uptime + pids + ctx size proxy. SIGINT exits cleanly. `--interval`, `--width` flags.
- [NEW] `src/builder-api/tomlify.sh` — installer for `api_config/`. Sub-commands: `<name>`, `base`, `all` (default), `list`. Uses `install -m 0644`. Prints the blue LLM-DOCKER ascii banner at start.
- [CHANGE] `src/builder-api/run-local.sh` first action is now `printf '\033[2J\033[H'` (screen clear). Replaces the AppleScript-prepended `clear;` that sometimes triggered the zsh `?clear` glob bug.
- [CHANGE] `src/cld` + `src/ocd` port resolution reads `~/.llm-docker/api_config/<name>.toml` first, base second, `BUILDER_API_PORT` env third, default 6666 last. Both probe `lsof -ti :$port` before spawning and skip cleanly if anything is bound.
- [CHANGE] `src/ocd` ported `flock`-based Docker-launch serialization from `src/cld`. Shared lock at `/tmp/cld-docker-start.lock`.
- [CHANGE] `src/builder-api/builder_api.applescript` — split path snapshots the outer iTerm window bounds, applies `set columns to winCols`, then restores bounds. `winCols` cut to 40. `clear;` removed from the typed cmd.
- [CHANGE] Repo layout: `api_config/builder-api.toml` (base) + `api_config/{llm-docker,purpletech,slav-ai}.toml` (shards). The legacy `projects/` directory and root-level `builder-api.toml` are gone.
- [TWEAK] CLAUDE.md gains a "No auto daemon restart in examples" rule: install commands never chain `&& cld -c -a`. Yaro picks the restart timing himself across multiple terminals.
- [TWEAK] Banner subtitle rebranded "Builder API" → "LLM-docker API". Internal env vars + Python identifiers + paths under `src/builder-api/` keep their names for back-compat.

# v2.7 (2026-06-16)

Two `cld -a` papercuts gone: Docker Desktop now starts even when its app lives in a subfolder, and the API side panel no longer resizes your iTerm window.

## llm-docker cage
- [BUG] `cld` hung at "Waiting for Docker to start..." when Docker.app lived in a subfolder like `/Applications/Utilities/`. `open -a Docker` was silently failing to find it. Now falls back to a Spotlight + filesystem search and opens Docker from wherever it actually is.
- [BUG] `cld -a` was resizing your iTerm window when it added the API side pane. The split reuses the existing window's width now — your main pane keeps the same screen size.

### Dev logs
- [BUG] `src/cld` + `src/ocd` — added an `open -a Docker` fallback chain (`mdfind -name Docker.app` → `find /Applications -maxdepth 4 -name Docker.app`), then `open <absolute path>`. Hard-fails with a clear error if nothing found.
- [CHANGE] `src/builder-api/builder_api.applescript` — split branch no longer calls `set columns to winCols` on the new session. That line was telling iTerm to force the pane to 43 cols, which grew the outer window to accommodate.
- [NEW] Checked-in reference `builder-api.toml` at the repo root — a complete real-world example of the host config (global jobs + language packs + three projects with their security-bounded job lists). New users can copy it to `~/.llm-docker/builder-api.toml` and edit, instead of authoring from scratch.

# v2.6 (2026-06-05)

`cld -a` no longer asks for a second fingerprint. API jobs list now color-codes by family and packs cleaner in narrow panes. Update check throttled to once a day.

## llm-docker cage
- [BUG] `cld -a` was asking for a second Touch ID when opening the API Terminal panel. Zero extra fingerprints now — the secrets from your first prompt are handed off to the new window directly.
- [NEW] Update check throttled to once per 24h. Use `UPDATE_FORCE=1 cld` to force a check immediately.
- [BUG] First-ever `cld -a` on macOS was silently skipping the secret handoff because BSD `mktemp` doesn't accept template suffixes after the `X`'s. Fixed.

## API — visuals
- [TWEAK] Jobs list under the boot banner now color-codes by prefix family (db-*, sa-*, django-*, lounge-*, etc.) and packs at most 2 jobs per row, so related jobs group visually instead of forming a 3-4-wide wall.

### Dev logs
- [CHANGE] API panel handoff now passes the secrets file as `$2` to `run-local.sh` instead of prepending `source <handoff>; rm -f <handoff>; bash …` to the iTerm-typed command. Some zsh setups (custom bracketed-paste widgets) prefix the first pasted char with `?` and broke the chain; passing as a positional arg side-steps it entirely.
- [NEW] `_write_secret_handoff` helper added to `src/cld` + `src/ocd` — writes a mode-0600 short-lived file under `/tmp/s3c-gorilla/`, allowlist excludes host-path / loader-hijack vars (PATH / HOME / LD_* / DYLD_* / LLM_DOCKER_ENV_GORILLA).
- [CHANGE] `src/builder-api/run-local.sh` accepts an optional handoff path as `$2`, sources + deletes it before the env-gorilla sentinel check.
- [TWEAK] Update-check marker lives at `/root/.claude/.last_update_check` (host-persisted via the claude bind mount); touched only on a successful npm update so a flaky network doesn't lock you out for a day.

# v2.5 (2026-06-02)

One password per macOS boot covers every project. Container sees every secret your shell has. Default install is lean.

## llm-docker cage
- [NEW] Launch `cld` (or `ocd`) from any project folder — env-gorilla now loads the cage-wide `llm-docker` secrets AND that project's own secrets in ONE go, no extra password or fingerprint prompts compared to launching from llm-docker itself. Same for the API when you pass `-a`. Powered by env-gorilla v0.12's new merge mode.
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

API tightened so a project can't author its own host commands anymore. Plus the chromium-leak fix, a working monorepo story, and a pile of small polish.

## API — security
- [CHANGE] Every command Claude can run on your Mac now lives in a single host file: `~/.llm-docker/builder-api.toml`. Per-project tomls are no longer read. One file to audit, no project can sneak a new command past you.
- [CHANGE] The plugin feature is gone. It let a project drop a Python file that ran with full host access — too much trust for a sandbox. No replacement; the surface is closed.
- [CHANGE] Editing the host toml no longer takes effect automatically — kill the daemon and `cld` will relaunch it. An in-container agent could otherwise talk you into running a script that silently widened what it's allowed to run.
- [NEW] Mark destructive jobs with `mutates_filesystem = true`. Callers then have to send an explicit confirmation header on top of the password — so a contract-test loop can't accidentally fire `prettier --write` and reformat 300 files before you can cancel.
- [NEW] Pin a script's sha256 in the toml with `command_hash`. The daemon refuses to run it if anyone touches the file.
- [NEW] `{{container}}` token in job args — resolves at request time to whichever Docker container belongs to this project. Lets `docker exec` wrapper jobs survive container restarts.
- [NEW] Per-job `cwd = "<subdir>"` for monorepos. Frontend in `angular/`, api in `api/`, both share the same daemon.
- [NEW] Unknown fields or stale `plugin = ...` keys in the toml now warn loudly at startup instead of being silently ignored.

## API — reliability
- [BUG] Killed browser jobs no longer leave a 1 GB chromium running. The whole bash → node → chromium chain dies together.
- [BUG] Cancelling a build now waits until the job has actually stopped before replying, instead of returning the moment the kill signal was sent. The reply also tells you how it exited.
- [BUG] Cancelled jobs were showing as "failed" in the history. Now they show as "cancelled".
- [BUG] Jobs running in a subdir (`cwd = "api"` + `command = "vendor/bin/phpunit"`) were failing with "command not found". They find the binary now.
- [NEW] Cancel the running job without killing the daemon.

## API — visuals
- [BUG] API pane was blank in narrow iTerm splits. Now shows a compact ASCII frame.
- [BUG] After exiting Claude and relaunching, `cld -a` was opening a fresh API pane instead of reusing the existing one. Now finds the pane by which port the daemon is on.
- [NEW] Daemon prints every job it knows about at startup, right under the banner. First thing you see when it boots.
- [TWEAK] Project name highlighted in pink so two projects' panes are easy to tell apart at a glance.

## llm-docker cage
- [BUG] After `cld --build`, the next launch was crashing with `sleep: invalid time interval`. The smart-rebuild was accidentally baking the build's temporary entrypoint into the image. Fixed.
- [NEW] `cld --rebuild-force` — full rebuild from the Dockerfile when you want a clean slate. `--build` is now the fast smart-rebuild.
- [TWEAK] First time you use a tmux flag (`-tr`, `-tc`, `-tcl`), the matching install flag flips on in your config and the image smart-rebuilds. No more full rebuild for a tmux flavor switch.

## Browsing
- [NEW] Chromium is now pre-installed in the image, so Playwright works on first launch without a 60-second download. Also works on Linux arm64 (which Playwright's default channel doesn't support).
- [TWEAK] Headful + headless chromium gated behind `INSTALL_BROWSING=true` in `llm-docker.conf`.

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
- [BUG] `cld` no longer crashes Docker Desktop when launched in many terminals at once. With 30+ open terminals, parallel `cld` calls were all firing `open -a Docker` simultaneously. The second/third launch event arrives mid-startup and Docker Desktop dies with `NSInternalInconsistencyException: Unrecognized event type 0` (an AppKit thread-safety bug in Docker's Go bridge, hits hardest on macOS Sequoia 15.6+). Wrapped the whole "is Docker up? if not, start it and wait" block in a `flock` on `/tmp/cld-docker-start.lock` so only one `cld` ever launches Docker; the rest wait, then no-op when they re-check inside the lock. Requires `flock` (`brew install flock`); without it `cld` warns once and falls back to the old racy behavior so it still runs.

## Security
Hardening pass focused on closing two bind-mount escape paths a compromised or prompt-injected project could otherwise walk into:

- [CHANGE] API plugin gate (`src/builder-api/config.py`): declaring `plugin = "..."` in a project's `.builder-api.toml` now requires `BUILDER_API_ALLOW_PLUGINS=1` in the daemon's environment. Without it, the daemon refuses to start with a `ConfigError` pointing to the variable. Plugins run unrestricted Python in the daemon process on the host — this forces a deliberate human step before any project (or a Claude inside one) can pivot to host code execution by dropping a `builder_plugin.py` and editing the toml. Existing users with a plugin: export the env var in `run-local.sh`'s shell or in `.env`.
- [CHANGE] Added `deny`: `Read/Edit/Write(**/llm-docker/**)` so projects can't read or modify the cage source from inside the container.
- [CHANGE] Added container-escape denies: `*nsenter*`, `*docker.sock*`.
- [BUG] Fixed malformed `WebFetch(domain:github.com/sst/opencode)` → `WebFetch(domain:github.com)` — domain patterns ignore the path component, so the `/sst/opencode` part was silently doing nothing.
- [CHANGE] Added `Monitor`, `Task*`, `ToolSearch` to the default allow list.
- [CHANGE] Repo's own `.claude/settings.local.json` got the same hardening so working in this repo follows the same boundary the template ships to projects.

# v2.2 (2026-05-06)

## API
Tested and works with Job templates. You can connect this API to your project MCP that Claude Code uses.

- [NEW] `[jobs.<name>]` blocks with pattern-validated parameters, length caps, optional integrity pin.
- [NEW] Hot-reload: edit config, daemon picks it up in ~1.5s.
- [NEW] Dedupe window: same op twice in 5s collapses onto one job.
- [NEW] `?dryrun=1`: returns what would run, without running.
- [NEW] `GET /jobs` introspection with `config_mtime` for cache invalidation.
- [NEW] Locked error shapes (400 / 404 / 412).
- [NEW] Examples bundled: Node, PHP+compose, sample game project.

## Misc
- [BUG] Launchers crashed on default macOS bash with `bad substitution`. Swapped for portable.
- [NEW] env-gorilla auto-injection: no local secrets file → reach for `env-gorilla` if installed. Works for `cld`, `ocd`, and the API launcher.

## Daemon stability
- [BUG] Ctrl-C now actually exits (was deadlocking).
- [BUG] Finished builds crashed the response (deep-copy on a lock).
- [BUG] Empty argument whitelist now means "none allowed", not "any allowed".

## Onboarding doc + examples + repo-level config
- [NEW] `docs/00-LLM-DOCKER.md`: read-this-first doc.
- [NEW] Per-stack example configs (Node / PHP+compose / sample game).
- [NEW] Repo-level config with two dev sanity-check jobs.

# v2.1 (2026-04-25)

## New
- [NEW] Browsing stack: New `INSTALL_BROWSING` build-time flag (default `true` in `llm-docker.conf`). When on: apt-installs `chromium-headless-shell` (no-systemd headless build for HyperFrames + automation) and `chromium` (full headful browser for Xvfb / X11 setups). A `policy-rc.d` shim is dropped during install so chromium's `invoke-rc.d`-based post-install doesn't dpkg-exit-1 inside non-systemd containers.
- [NEW] hyperframes is added by default because it's so cool (if INSTALL_BROWSING==true).
- [NEW] Smart `--build` + new `--rebuild-force`:
  - `cld --build` / `ocd --build` no longer wipes the image. Instead it spins a temp container off the existing image, copies the latest `install_cli.sh` + `install_devpack.sh` + `llm-docker.conf` in, re-runs them with skip-if-installed guards, and `docker commit`s the result. Heavy stuff (5×Go installs for security tooling, recon/claude-tmux cargo builds, codeman, omz/p10k clones, ferox/nikto, npm globals) gets skipped when already present — so flipping a single `INSTALL_*` flag rebuilds in seconds instead of half an hour.
  - `cld --rebuild-force` / `ocd --rebuild-force` is the old `--build` behavior: `docker rmi` + full `docker build` from the Dockerfile. Use when smart-rebuild cruft is piling up or you've edited the Dockerfile itself.
  - `install_cli.sh` and `install_devpack.sh` are now idempotent: every Go install / cargo install / curl|bash installer / git clone / npm-global / hyperframes skill add checks for an existing binary, marker file, or directory before doing work.

## Bug fixes
- [BUG] `llm-docker/src/llm-container-claude-settings.json` was for my local setup accidentally. Now it's no restrictions.
- [TWEAK] Honest build progress bar: the docker-build spinner's percentage is now driven by counting actual completion markers in the build log (apt's `Setting up <pkg>`, npm's `added N packages`, pip/gem's `Successfully installed`, cargo's `Installing /…`, git's `Resolving deltas: 100%`) divided by a pre-computed total of install ops parsed from the Dockerfile + `SW_*_APT` arrays + the enabled `INSTALL_*` flags. No more wall-time guesses; no more "90% then back to 60%" jumps.

# v2.0 (2026-04-24)

Huge update. Big refactor. Many cool features.

## Setup & Install
- [NEW] One-command installer (`install.sh`): Creates dirs, walks the user through workspace bind-mount config + API keys + behavior toggles, builds image, links `cld`/`ocd` to PATH. Works via `curl` pipe.

## New cld / ocd flags
- [NEW] `--clean` flag to remove leftover llm-docker containers before launch.
- [NEW] `cld --danger` flag to run Claude unrestricted.
- [NEW] `--build` flag to force a fresh image rebuild.
- [NEW] `--slot N` flag for tagged session save/restore (N parallel chats per project).
- [NEW] `--delay <sec>` flag to space out window openings in multi-window launches.
- [NEW] `-a` / `--api` flag to spawn API in a separate terminal.

## Claude
- [NEW] `.claude/settings.local.json` with extensive allow/deny list as an extra security layer.
- [CHANGE] Security: minor Claude `deny` permission tweaks.

## Boot prompt
- [NEW] Per-project `BOOT.md`: if present in the workdir, its contents are injected as the first-message prompt on fresh sessions. Falls back to the old "Read ./CLAUDE.md …" default when only `CLAUDE.md` exists.

## Mounts
- [CHANGE] `DOCKER_DIR` default flipped from `/root` to `/root/Projects` so container paths mirror the host (`~/Projects/foo` → `/root/Projects/foo`) even when CWD is outside `WORKSPACE_DIR`.
- [NEW] `~/.tmux.conf` (host) → `/root/.tmux.conf` (ro) — auto-bound if the file exists; your keybindings follow you in.
- [NEW] `~/.p10k.zsh` (host) → `/root/.p10k.zsh` (ro) — auto-bound if the file exists; suppresses the Powerlevel10k config wizard on every new shell / tmux pane.
- [NEW] `README.md` → `/opt/llm-docker/README.md` (ro) — source of the banner's version string.

## Refactor
- [CHANGE] `docker-compose` removed.
- [CHANGE] All non-sensitive settings moved from `.env` to `llm-docker.conf` (new).
- [NEW] `logs` support (install, docker logs).
- [CHANGE] Every source file moved out of the repo root into `src/`.
- [NEW] Added `docs/` with Claude/OpenCode documentation.
- [NEW] Added `.claude/` and `CLAUDE.md` (instead of `./agents` and `AGENTS.md`).

## Directory Mounting Security
- [NEW] Persistent `~/Projects` workspace bind mount is OPT-IN via `WORKSPACE_DIR`/`DOCKER_DIR` in `.env`. Default: each `cld`/`ocd` invocation mounts ONLY the current directory — the LLM can't see sibling projects.
- [NEW] Guard rails: `WORKSPACE_DIR` / `DOCKER_DIR` refuse `/`, `$HOME`, `/Users`, system dirs, and anything shallower than 3 segments. Server won't start with an unsafe pair.

## Persistence Mount Narrowing
- [CHANGE] Replaced the broad `~/.llm-docker/claude:/root` bind with three targeted mounts (`.claude/`, `.config/`, `.claude.json`). Container's `/root` outside those is now ephemeral.
- [BUG] Pre-existing clobber bug fixed: `docker-entrypoint.sh` no longer overwrites an existing `.claude.json` on every API-key run.

## Shell & UX
- [NEW] OH-MY-ZSH is the default shell environment (autocomplete, fzf, p10k).
- [NEW] Custom `zprofile` added.
- [NEW] ASCII banner at container boot, version auto-pulled from `README.md`.
- [TWEAK] Docker-build spinner now summarizes BuildKit output (`installing apt packages`, `installing claude-code`, …) instead of dumping raw `RUN` commands.

## TMUX godness
- [NEW] Customized for working with AI with many tmux setup variations (Team `-tt`, Recon `-tr`, Codeman `-tc`, claude-tmux `-tcl`).

### Multi-Session Management (slot system) — Claude + OpenCode
- [NEW] Session restore: `cld -c 4` / `ocd -c 4` opens 4 terminals and restores previous sessions. Bare `cld 4` / `ocd 4` starts fresh but still saves on exit.
- [NEW] Session slot system (`cld --slot N` / `ocd --slot N`): each terminal gets a numbered slot that auto-saves and restores its session ID independently. N parallel chat chains per project.
- [NEW] Per-tool discovery: cld diffs `.claude/projects/*.jsonl` snapshots at start/exit; ocd queries the OpenCode sqlite DB (`session WHERE directory=... AND time_created > baseline`). Same UX, different backends.
- [NEW] `cld --slot 1 -c` → resume slot 1's last Claude session. `ocd --slot 1 -c` → same for OpenCode.
- [NEW] Graceful cleanup via background watchdog (cld); trap-based save on clean exit (ocd).

## Container-Exit Behavior
- [BUG] Now properly kills containers on terminal close, CMD+Q, or crash.
- [NEW] `EXIT_TO_DOCKER` in `.env`: when `true`, exiting Claude/OpenCode drops to a bash shell INSIDE the container for post-mortem / poking around. Default `false` keeps the old "exit tool → exit container → back to host" flow.

## Multi-Window layout on macOS (extra)
- [NEW] Pro multi-window layout (macOS) (`src/multi-llm-docker.applescript`): `cld 4`, `cld 8 -c` — auto-detects monitors and arranges terminals in 2-column grids. Skips middle monitor on 3+ screen setups.

## API (optional) — IN-PROGRESS
- [NEW] Full host-side daemon in `src/builder-api/`: build queue + long-poll status + log tailing + JSONL event feed + runtime control + WebSocket live streaming + browser-console tunnel.
- [NEW] Security: single predefined build command + `allowed_args` whitelist, `execvp`-only execution, project-root-scoped paths, password auth, failed-auth rate limit, queue cap, request-read timeout, drop-oldest WS back-pressure, CORS scoped to `/log`.
- [NEW] Config: declarative `.builder-api.{toml,yml,json}` per project. Optional Python plugin drop-in for custom endpoints.
- [NEW] Launch from `cld --api` / `ocd -a` (spawns server in a new Terminal on macOS; backgrounds on Linux).

## SSH support (optional) — IN-PROGRESS
- [NEW] Communicate with Claude inside Docker through SSH (useful for Claude orchestrating apps, like `Quake 3 IDE` for macOS or even VSCode). Public-key auth only (passwords disabled).
- [NEW] Slot-based SSH host ports: `cld --slot N` → 8884 + (N - 1), so parallel containers don't collide on one port.

# v1.2 (2026-03-03)

- [NEW] Claude Code support: New `cld` wrapper for Claude Code CLI in Docker; persistent data in `~/.llm-docker/claude`.
- [NEW] Entrypoint: `docker-entrypoint.sh` switches between OpenCode and Claude based on `TOOL`.
- [CHANGE] ENV-driven config: Docker Compose reads `.env` for `WORKSPACE_DIR`, `TOOL`, sandbox settings, etc.
- [CHANGE] Base image updated from Node 22 to Node 24.
- [CHANGE] Config: `opencode.config.jsonc` tweaks; `.env.example` expanded with Claude Code options.

# v1.1 (2026-02-03)

- [NEW] Premium branding: New badges, logo, and professional README overhaul.
- [NEW] Better routing: Full support for path arguments and flag passthrough.
- [TWEAK] Saner exits: Immediate container exit on completion or Ctrl+C.
