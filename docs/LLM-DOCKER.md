# LLM-DOCKER: read this first

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
and are bind-mounted in, so a `docker rmi` doesn't lose your chat history. The
current project folder is bind-mounted read-write; the wider workspace mirror
is bind-mounted read-only so the agent can't wipe sibling projects.

## 2. Three things you need to internalise

Load-bearing concepts. Everything else is detail.

### 2.1 Three execution surfaces, not one

```
        HOST (your Mac/Linux)              CONTAINER (Docker)
  ┌────────────────────────────────┐  ┌────────────────────────────┐
  │ src/cld / src/ocd     ──launches──▶ docker-entrypoint.sh        │
  │ src/builder-api/server.py         │   ▼                         │
  │ env-gorilla (KeePassXC unlock)    │ claude / opencode CLI       │
  └────────────────────────────────┘  └────────────────────────────┘
                  ▲                                  │
                  └────── HTTP ──────────────────────┘
                  host.docker.internal:<port>  (builder-api, per project)
```

- **`cld` / `ocd`** are HOST shell scripts. Their heavy logic lives in
  `cld.run.sh` / `ocd.run.sh` (shared runtime) and `src/setup/*.sh` (modules).
  They `exec` env-gorilla if vault mode is on, read `src/.env` +
  `src/llm-docker.conf`, then `docker run` the container. *Bug here? Edit
  the source. No rebuild needed.*
- **`docker-entrypoint.sh`** runs INSIDE the container. Bind-mounted from
  `src/docker/docker-entrypoint.sh` (read-only), so edits take effect on
  next launch. *No rebuild needed.*
- **`builder-api`** runs ON THE HOST as a Python daemon. The container calls
  it via `host.docker.internal:<port>`. *Edit `src/builder-api/*.py`, restart
  the daemon. No rebuild needed.*

When something doesn't work, **first identify which surface owns the bug**.
Most "the agent can't do X" issues are host-side script bugs, not container
problems.

### 2.2 Two config files, never confuse them

| File | Purpose | Tracked in git? |
|---|---|---|
| `src/.env` | **Secrets** — obfuscated env-var names to defeat scanners: `_4NTHR0P1C_H4NDLE`, `_0P3N4I_H4NDLE`, `Z41_H4NDLE`, `BUILDER_API_P4SS`, `LLM_D0CKER_SHH_4UTH_PBLKZ`, `LLM_D0CKER_SHH_SRV_*_B64` (host keys), `LLMD0CKER_SHH_3D25519_PVYT_B64` (outbound), `G1TL4B_LLMD0CKER_TEKKEN`, `PG_P4SS`, `CDMN_H4NDLE` / `CDMN_P4SS` (Codeman), `LLM_D0CKER_SHH_CFG_B64` (config fallback). Full rename map at the top of `.env.example`. | NO (`.gitignore`'d). Seeded from `src/.env.example` by `setup_env`. Enforced `chmod 600` on every write. |
| `src/llm-docker.conf` | **Build flags + runtime knobs** — `INSTALL_*` (build-time), `WORKSPACE_DIR`, `DOCKER_DIR`, `SANDBOX_ENABLED`, `INTERNET_ACCESS`, `IS_S3C_GORILLA_ENABLED`, `LLM_D0CKER_SHH_EN4BLED`, `LLM_DOCKER_SSH_HOST_PORT`, `BUILDER_API_AUTOSTART`. | YES. Edit in place. |

Both are passed to the container via `docker --env-file`. In vault mode,
secrets ALSO flow via env-gorilla injection → `-e VAR` for each shell var
(cld/ocd/smoke test pass every non-blocklisted var through).

### 2.3 Two flavours of rebuild

```
cld --build         # SMART: re-runs install scripts INSIDE existing image,
                    # `docker commit`s the result. Skips already-installed
                    # tools (Go binaries, cargo, npm globals, chromium,
                    # tmux helpers). FAST. Use after editing install_*.sh
                    # or flipping an INSTALL_* flag.

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

# Multi-pane team mode (1 lead + N agents in one container)
cld -tt           # default: 1+3 stacked
cld -tt 4         # 2x2 grid
cld -tt 2         # side-by-side

# Start the host-side builder-api daemon at the same time
cld -a            # 3-pane split: status / api / verbose console

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

# Force vault refresh (re-read KeePass, ignore cached chip-blob)
cld --refresh-env
```

`ocd` accepts the same grammar — same flags, same slots. Use `ocd` for
OpenCode instead of Claude Code.

**`-s` is intentionally NOT a slot alias.** OpenCode's native CLI uses `-s
<uuid>` for `--session`, and we keep passthrough open via `--`. Use `--slot
N` for slots in both launchers.

## 4. Configuration cheat sheet

| What you want | Where | Rebuild? |
|---|---|---|
| Add / change an API key | Vault mode: KeePassXC entry `ENV/llm-docker` .env attachment. Plain mode: `src/.env`. Run installer to pre-fill from vault. | No |
| Add an SSH pubkey (inbound) | Re-run installer step 6a; picks from `~/.ssh/*.pub` or paste. | No |
| Add / rotate outbound SSH key | Re-run installer step 6b; can also provision remote llmdocker user. | No |
| Turn on a build-time toolkit (ruby, browsing, media, php, tmux helpers) | `src/llm-docker.conf` (`INSTALL_*=true`) | **Yes** — `cld --build` |
| Enable / disable SSH inbound | `src/llm-docker.conf` (`LLM_D0CKER_SHH_EN4BLED`) | Yes (first time, to bake openssh-server) |
| Change `WORKSPACE_DIR` (persistent host mirror) | `src/llm-docker.conf` | No |
| Toggle internet block | `src/llm-docker.conf` (`INTERNET_ACCESS=false`) | No (forces bridge networking on next launch) |
| Auto-start builder-api on every launch | `src/llm-docker.conf` (`BUILDER_API_AUTOSTART=true`) | No |
| Switch vault ↔ .env mode | `src/llm-docker.conf` (`IS_S3C_GORILLA_ENABLED=true/false`) or re-run installer step 3 | No |

The wizard at `src/install.sh` walks you through all of this. Re-running it
is fine (idempotent) — every prompt pre-fills from `.env` OR the vault
(labelled `(from env-gorilla vault — Enter to keep)` etc.). In vault mode the
installer auto-wraps itself through env-gorilla after step 3 says YES.

## 5. Sessions, slots, persistence

Both `cld` and `ocd` persist session history across container rebuilds —
slot files, SQLite DBs, JSONL logs all live on the host under
`~/.llm-docker/`. Wipe the container; every chat survives. **Session keying
is by folder basename** — moving `~/Projects/foo` to `~/work/foo` still
finds the same chats.

```
~/.llm-docker/
├── claude/
│   ├── .claude/                        ← /root/.claude inside container
│   │   ├── projects/<basename-key>/    ← session JSONL files
│   │   ├── slot_1.id                   ← slot 1's last-session UUID
│   │   ├── slot_2.id
│   │   └── settings.local.json         ← Claude permissions (git-tracked source of truth)
│   ├── .config/
│   └── .claude.json
├── opencode/
│   ├── .config/opencode/               ← OpenCode config
│       ├── .local/share/opencode/          ← OpenCode SQLite + slot_N.id
    │   (live copy on Docker volume "llm-docker-opencode-data"; the host
    │    dir below is the disaster-recovery mirror — see opencode-db.sh)
│   │   └── opencode.db
│   └── .cache/opencode/
├── ssh/                                ← SSHD host keys mount (populated from vault at launch)
└── api_config/                         ← builder-api host config + per-project shards
    ├── builder-api.toml                ← base file (defaults, verb vocab, language packs)
    └── <project>.toml                  ← per-project shard (opt-in)
```

**Slot rules:** each slot tracks its own "last session" independently.
`cld -c --slot 1` always reopens slot 1's last chat, even if slots 2-4 have
newer activity. Slot files are written on graceful exit (background watchdog
on Claude, signal trap on OpenCode), so even CMD+Q / crash preserves them.

**Parallel-launch caveat:** running `ocd --slot 1` and `ocd --slot 2` from
the same directory simultaneously has both share the SQLite DB; the
last-exiter's session may overwrite the earlier slot save. Use separate
workdirs per slot.

**Deletion safety:** the container mounts your current project rw AND the
wider workspace mirror ro. Inside-container `rm` is intercepted by
`/usr/local/bin/rm` (see `src/docker/rm-guard.sh`) — protected roots refuse
outright; everything else routes to the macOS Trash via the builder-api or
`trash-cli` as fallback. Non-shell delete tools (python `os.remove`, node
`fs.unlinkSync`, `busybox rm`, `find -delete`, direct syscalls) bypass this
shim — it's one onion layer, not a complete wall.

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
image. One daemon per project, each on its own port; reachable from inside
the container at `host.docker.internal:<port>`.

**Config lives on the host only** at `~/.llm-docker/api_config/`. TWO kinds
of TOML files there:

1. **Base:** `~/.llm-docker/api_config/builder-api.toml` — global `[defaults]`,
   `[verb.<name>]` vocabulary, `[jobs.<name>]` globals (git-status, tree,
   trash), `[language.<lang>.jobs.<name>]` opt-in packs (python / php /
   node / compose).
2. **Per-project shard:** `~/.llm-docker/api_config/<name>.toml` — verb
   implementations + named jobs for one project. Loaded when the project
   basename matches.

Per-project `.builder-api.toml` files inside the project tree are NOT read —
the daemon refuses to load anything from container-writable paths (security
boundary). Plugin support was removed entirely.

**Schema:**

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

Resolution: later layers replace earlier ones by job name. `GET /jobs`
returns only the resolved set for THIS daemon's project.

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

`?dryrun=1` on `POST /job/<name>` returns the resolved argv without
enqueueing. Auth: `X-Builder-API-Password: <pw>` header OR `?key=<pw>` query
string. Loopback bind reads are unauthenticated by default; non-loopback
forces password + `auth_reads = true`.

**Validation error shapes (locked):** 400 `validation_failed`, 404
`unknown_job`, 410 endpoint removed, 412 `command_hash_mismatch`, 412
`command_not_found`.

**Soft-skip for projects with no config:** running `cld -a` from a project
with NO `[project.<name>]` block prints one WARNING line and skips the
daemon spawn (no scary CONFIG ERROR in the panel). Container itself still
launches normally.

**Panel layout (`cld -a`):** 3-pane split — cld-status (blue title, CPU
sparkline + slot map), builder-api (purple title, banner + jobs + event
tail), cld-verbose (pink title, request/response tunnel). Event tail
auto-shrinks to fit small panes.

**Hot-reload:** the daemon polls the resolved config's mtime every ~1.5s
and re-resolves. New jobs / aliases apply to next enqueue. In-flight builds
keep their snapshotted command + timeout. Bind / port / runtime changes
require a daemon restart.

## 8. env-gorilla integration

If you use [s3c-gorilla](https://github.com/RussianRoulette84/s3c-gorilla)
for KeePassXC-backed secret injection, THIS is where each surface auto-wraps
itself through `env-gorilla llm-docker,<project>` — a comma-separated
profile list so a single Touch ID covers cage + project secrets.

**Auto-wrap sites** (guarded by `LLM_DOCKER_ENV_GORILLA=1` sentinel — set
once to prevent infinite re-exec loops):

- **`cld` / `ocd`** → `src/setup/preflight.sh`
- **`install.sh`** → `src/install.d/03-env.sh` (only after user says YES to
  vault mode in step 3, so first-timers can opt out cleanly)
- **`install_test.sh`** — post-install health check
- **`smoke_test.sh`** — SSH end-to-end test
- **`src/builder-api/run-local.sh`** — daemon launcher

**Trigger conditions** (any true):
- `IS_S3C_GORILLA_ENABLED=true` in `llm-docker.conf` (explicit opt-in), OR
- `USER=yaro` (personal shortcut — always inject), OR
- `.env` missing (fallback for any user)

Every re-exec uses `bash "$0"` (not bare `"$0"`) so scripts without exec bit
still work.

**Secret prompt pre-fill priority** (used by installer at steps 5 / 6a /
7 / 8, via `src/setup/prefill.sh`):

1. Vault mode active + var in shell env → **vault wins** (freshest)
2. `.env` file → fallback
3. Shell env → last-resort catch-all

Every prompt shows its source in the label: `(from env-gorilla vault —
Enter to keep)` or `(from .env — Enter to keep)`.

**Dot-directory guard:** `~/.llm-docker` and other hidden dirs are stripped
of their leading dot before profile lookup — so `cld` run from `~/.llm-docker`
loads just `llm-docker`, not `llm-docker,.llm-docker` (which would trigger a
"missing .llm-docker profile" warning).

**Vault opt-in, binary missing:** if `IS_S3C_GORILLA_ENABLED=true` but
`env-gorilla` isn't installed, launches don't fail — they fall back to
`.env` (or just launch and let Claude/OpenCode `/login`). A single dim
warning prints only on a fresh launch with no `.env`; continue/resume
(`-c`) launches stay silent. The installer's step 3 offers to run the
s3c-gorilla installer for you.

## 9. Codebase map — where to find what

```
llm-docker/
├── README.md                              ← user-facing reference
├── CHANGELOG.md                           ← version history
├── CLAUDE.md                              ← project rules + boot sequence (AI agents)
├── docs/                                  ← deep-dives (you're reading LLM-DOCKER.md right now)
│   ├── SETUP-PROJECT-API.md               ← how to wire a project into builder-api
│   ├── anthropic/                         ← upstream Claude Code reference
│   ├── opencode/                          ← upstream OpenCode reference
│   ├── tmux/                              ← tmux-specific docs
│   └── llm-docker-screenshots/
├── plans/                                 ← per-work-item plans (ephemeral)
├── scripts/
│   ├── ci/                                ← 9 CI scripts — see section 11
│   ├── git-hooks/                         ← pre-commit_private-terms.sh
│   └── tools/                             ← install-git-hooks.sh
└── src/
    ├── cld / ocd                          ← HOST launcher scripts (both re-exec through env-gorilla)
    ├── cld.run.sh / ocd.run.sh            ← shared runtime — heavy docker-run logic
    ├── cld-status                         ← blue CPU/slot dashboard for -a panel
    ├── cld-verbose                        ← pink verbose console for -a panel
    ├── install.sh                         ← installer driver — sources install.d/*.sh in order
    ├── install.d/                         ← install steps (each numbered)
    │   ├── 01-docker.sh / 02-dirs.sh / 03-env.sh / 04-workspace.sh
    │   ├── 05-apikeys.sh                  ← API key prompts (uses _prefill_key)
    │   ├── 06a-ssh-inbound.sh             ← macOS → container SSH server
    │   ├── 06b-ssh-outbound.sh            ← container → your servers (+ provisioner)
    │   ├── 07-builderapi.sh / 08-tmux.sh / 09-devpacks.sh / 10-image.sh
    │   ├── 11-link.sh / 99-complete.sh    ← final linking + paste-block + health check offer
    ├── setup.sh                           ← module loader; sources src/setup/*.sh
    ├── setup/                             ← shared helper modules
    │   ├── config.sh                      ← _read_env_var, _source_all_config, dir setup
    │   ├── preflight.sh                   ← env-gorilla re-exec (for cld/ocd)
    │   ├── docker.sh / docker_log.sh
    │   ├── launcher.sh                    ← _maybe_start_api (builder-api panel spawn)
    │   ├── identity.sh                    ← session-by-basename resolver
    │   ├── log.sh                         ← _log / _log_silent
    │   ├── banner.sh / image.sh
    │   ├── safe_delete.sh                 ← shared trash-then-refuse helper
    │   ├── mask.sh                        ← _mask_secret_display (abc*******123)
    │   ├── clipboard.sh                   ← _copy_to_clipboard (pbcopy/xclip/wl-copy)
    │   └── prefill.sh                     ← _prefill_key (vault > .env priority)
    ├── llm-docker.conf                    ← build flags + runtime knobs (tracked)
    ├── .env.example                       ← secrets template (obfuscated var names)
    ├── Dockerfile                         ← container image definition
    ├── docker/
    │   ├── docker-entrypoint.sh           ← runs inside container at start
    │   ├── entrypoint-lib.sh              ← helpers (co-mounted)
    │   ├── setup-ssh.sh                   ← in-container sshd + agent + host key decode
    │   ├── install_cli.sh                 ← claude-code + opencode + skills + mcp servers
    │   ├── install_devpack.sh             ← apt/cargo/go/gem/npm toolkits (gated by INSTALL_*)
    │   ├── rm-guard.sh                    ← /usr/local/bin/rm → trash routing
    │   ├── zprofile                       ← root's container shell init
    │   └── colorize.sh                    ← banner gradient renderer
    ├── builder-api/
    │   ├── server.py                      ← HTTP routing + BuilderHandler class
    │   ├── app_context.py                 ← AppContext (config + events + queue + runtime)
    │   ├── config.py                      ← host-toml schema loader + project view resolver
    │   ├── config_models.py               ← BuildCfg / RuntimeCfg / EventsCfg / SecurityCfg
    │   ├── jobs.py / jobs_parse.py / jobs_models.py / jobs_errors.py
    │   ├── build_queue.py                 ← FIFO worker, dedupe, snapshot-per-entry
    │   ├── banner.py                      ← boot ASCII + terminal-height-aware event tail
    │   ├── security.py                    ← AuthGate + rate limit + size caps
    │   ├── http_handler.py / ws.py        ← HTTP + WebSocket handlers
    │   ├── client.py                      ← Python helper for in-container callers
    │   ├── run-local.sh                   ← per-project launcher (passes --project)
    │   ├── builder_api.applescript        ← iTerm 3-pane split spawner (macOS)
    │   ├── close_api_panes.applescript
    │   ├── api_config/                    ← starter host-config templates (base + shards)
    │   ├── tests/                         ← pytest unit tests (config/jobs/security)
    │   └── quake_api/                     ← historical v1.0 origin (frozen)
    ├── tools/
    │   ├── provision-llmdocker.sh         ← remote-server llmdocker user setup (portable)
    │   └── README.md
    ├── ascii/llm-docker.txt               ← shared banner art
    ├── lib/ywizz/                         ← TUI helpers (theme, prompts, animations)
    ├── examples/                          ← per-language MCP server templates
    ├── smoke_test.sh                      ← SSH end-to-end smoke
    └── install_test.sh                    ← post-install health check
```

## 10. Adding features — common extensions

### Add a new CLI tool to the container

1. Append to the appropriate `SW_*_APT` / `_NPM` / `_GEM` / `_GO` array in
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
command   = "..."                     # absolute path, ./relative, or PATH lookup
args      = ["--flag", "{value}"]     # placeholders MUST be standalone array elements
timeout_s = 60                        # default 60
sha256    = "<hex>"                   # optional integrity pin
[jobs.<name>.placeholders.value]
regex     = "^[A-Za-z]+$"              # required
max_len   = 200                        # default 200
required  = true                       # default true
```

Save → daemon hot-reloads within ~2s → `POST /job/<name>` is live.

### Add a new installer step

1. Drop `src/install.d/NN-<name>.sh` (numeric prefix picks its slot in
   the pipeline).
2. Add it to `src/install.sh`'s step list.
3. Add it to `scripts/ci/check-modules.sh`'s `STEPS=` string (CI verifies
   the concatenation still parses + no forward-refs).
4. Add it to `scripts/ci/check-install-dry.sh`'s `STEPS=` string (smoke
   test sources every step under stubs).

### Add a shared helper module

Drop `src/setup/<name>.sh`, register it in `src/setup.sh`'s explicit
module list, done. Functions become available to every install.d step
and to `cld`/`ocd`.

## 11. CI safety net

`scripts/ci/*.sh` — nine scripts, run any / all before pushing:

| Script | What it checks |
|---|---|
| `no-rm.sh` | Bans bare `rm` in runtime shell scripts (some paths exempted) |
| `check-modules.sh` | setup.sh exports the pinned function contract; install.d concatenates cleanly; no forward-refs |
| `check-py.sh` | `py_compile` + AST undefined-name audit + `import server` smoke |
| `check-py-tests.sh` | Runs pytest against `src/builder-api/tests/` (skipped if pytest missing) |
| `check-size.sh` | Hard-fails on NEW files > 500 lines; grandfathered offenders stay advisory |
| `check-launcher-softskip.sh` | 10 unit tests for `_project_shard_lookup` (soft-skip probe) |
| `check-install-dry.sh` | Source-tests every install.d step under stubbed TUI + docker |
| `check-safe-delete.sh` | 5 tests for the shared trash helper |
| `check-todos.sh` | Advisory: lists all `TODO(...)` comments across the tree |

Plus one git hook + installer:

- `scripts/git-hooks/pre-commit_private-terms.sh` — blocks commits that ADD
  private-project names to public files. Path whitelist (`docs/`, `plans/`,
  `memory/`, `CLAUDE.md`) + per-file opt-out marker
  (`# private-terms: allowed`).
- `scripts/tools/install-git-hooks.sh` — idempotent symlink installer.

## 12. Troubleshooting — known failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `[builder-api] CONFIG ERROR: no [project.<name>]` in the api panel | `cld -a` from a project with no config block | Now soft-skipped: prints one WARNING + skips daemon spawn. Add a shard file `~/.llm-docker/api_config/<name>.toml` (or a `[project.<name>]` block in the base) to enable. |
| Installer wants to regen SSHD host keys every time | Old code checked only `.env`; vault-stored keys were invisible. | Fixed — installer now checks vault first, `.env` fallback. `FORCE_REGEN=1` forces regen when you actually want fresh keys. |
| SSH smoke test fails with empty `authorized_keys` | Vault-injected env vars weren't reaching `docker run` — only `--env-file .env` was passed. | Fixed — smoke test now copies cld's `EXTRA_ENV` pattern (iterate env, `-e VAR` for each). Also auto-wraps itself through env-gorilla in vault mode. |
| `safe_delete: failed to trash /var/folders/...` mid-install | macOS `brew install trash` doesn't accept `--` as end-of-options. | Fixed — helper no longer passes `--`. Callers absolute-path any `-`-prefixed target. |
| `env-gorilla: loading ENV/llm-docker,.llm-docker …` warning | Running cld from `~/.llm-docker` treated `.llm-docker` as a project name. | Fixed — dot-strip in preflight; `~/.llm-docker` resolves to just the cage profile. |
| `Permission denied` exec'ing a script via env-gorilla | Non-executable script; env-gorilla can't `exec()` it directly. | All 5 re-exec sites use `bash "$0" "$@"` — works regardless of the file's exec bit. |
| `--build` fallback silently no-ops | Legacy `setup_image` short-circuits when image exists. | If `cld --build` doesn't rebuild what you expect, run `cld --rebuild-force`. |
| Python edits don't take effect | Hot-reload only watches the host `builder-api.toml`, not Python source. | `pkill -f builder-api/server.py` then re-launch via `cld -a`. |
| `sleep: invalid time interval 'Read ./CLAUDE.md...'` on launch | Ancient smart-rebuild bug (fixed in v2.2). | `cld --rebuild-force` once. |
| `docker/00-LLM-DOCKER.md not found` | Legacy path — this doc is now `docs/LLM-DOCKER.md`. | Update your bookmark. |

## 13. Hard rules (from project CLAUDE.md)

These apply to anyone editing this repo, including AI agents:

- **Never use `rm`.** Use `trash` (host) or `safe_delete` (installer) or
  the container's `/usr/local/bin/rm` shim (routes to Trash). The
  bind-mounted project folder writes back to host — a misplaced `rm -rf`
  is catastrophic.
- **Never delete contents of mirrored folders.** Inside-container deletes
  show up on host immediately (unless caught by rm-guard).
- **Never run `install.sh` from inside the container.** It's host-side.
- **Never manage docker (`docker run/stop/rm`) without explicit permission.**
  Operator-only.
- **Never commit private project names to this public repo.** The
  pre-commit hook blocks it. Reword generically or use the opt-out marker
  in docs/plans.
- **Never write secrets to `.env` in plain — vault mode preferred.** `.env`
  is enforced `chmod 600` on every install-time write.
- **Question mark rule:** if the message is a question (`?`), text-only
  response is fine — no tool calls required.
- **Reporting rule:** every task-completing response ends with a footer
  (`Request / Done / Success / Concerns / Optimizations / Hacks / Next
  steps`). Multiple agents run in parallel; without it the operator can't
  tell who did what.

## 14. Where to go next

- **README.md** — full reference for users (flags, env vars, mount table,
  SSH, builder-api summary).
- **src/builder-api/README.md** — full builder-api API reference (validation
  shapes, `/jobs` schema, hot-reload behavior, sha256 pinning, examples).
- **docs/SETUP-PROJECT-API.md** — how to wire a project into builder-api
  (per-project shard TOML, MCP servers, `.env.example` layout).
- **CHANGELOG.md** — version-by-version delta.
- **CLAUDE.md** (project root) — the hard rules + boot sequence for AI
  agents.
- **plans/** — active + archived per-work-item plans (multi-phase execution
  records; check here for what's in-flight).

If you're stuck, the agents in `.claude/agents/` are subagent prompts —
useful examples of how this project leverages Claude in roles beyond chat.

---

*Last updated: v4.0.0 (2026-09-12). When you make a meaningful change to
how llm-docker boots / configures / rebuilds, update this doc and the
CHANGELOG.*
