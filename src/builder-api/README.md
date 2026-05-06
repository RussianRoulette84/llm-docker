# builder-api

A minimal, project-agnostic HTTP daemon for letting a sandboxed Docker
container ask the host to build code, run a long-lived process, tail logs,
and read structured events.

It's designed for the llm-docker setup: your Claude/OpenCode container
calls `http://host.docker.internal:6666/build` instead of trying to run
`make` inside a container that doesn't have your toolchain.

## Quick start

```sh
cd ~/Projects/my-project
cp /path/to/llm-docker/src/builder-api/examples/.builder-api.toml .
vim .builder-api.toml                              # edit command, logs, port
export BUILDER_API_PASSWORD=$(openssl rand -hex 16) # or put it in shell rc
python3 /path/to/llm-docker/src/builder-api/server.py
```

Then from inside the container:

```python
import client
client.build(["--fast"])
qid = client.build(["--clean"])["queue_id"]
res = client.wait_build(qid)        # blocks until done
print(res["log_tail"])              # last 40 lines of build.log
```

## What the API exposes

| Method | Path                            | Purpose |
|--------|---------------------------------|---------|
| GET    | `/`                             | Health + name + bind + port |
| GET    | `/status`                       | Runtime PID, uptime, current build |
| GET    | `/jobs`                         | Job catalog for MCP / client introspection |
| POST   | `/build[?dryrun=1]`             | Enqueue a legacy `[build]` run, returns `queue_id` |
| POST   | `/job/<name>[?dryrun=1]`        | Enqueue a `[jobs.<name>]` template invocation |
| GET    | `/build_status?id=&wait=N`      | Long-poll status (up to 60s), `log_tail` on finish |
| GET    | `/queue`                        | `{current, pending[], history[]}` |
| DELETE | `/queue/<id>`                   | Cancel a pending build |
| GET    | `/logs?file=<alias>&n=<lines>`  | Tail N lines of a declared alias |
| GET    | `/events?type=&since=&n=&pid=`  | Filter the JSONL event feed |
| POST   | `/log`                          | Ingest an external / browser log line (forwarded live to `/ws`) |
| POST   | `/run`                          | Start or restart the runtime process |
| POST   | `/stop`                         | Stop the runtime process |
| GET    | `/ws`                           | WebSocket — live logs, events, heartbeats |

Plus any paths the optional plugin registers.

### Live event stream (on `/ws`)

Every successful `POST /log`, `POST /build`, `/run` / `/stop`, and every
build/runtime lifecycle transition produces a JSONL event and is
**pushed live** to every connected WebSocket as:

```json
{"type": "event", "record": {"ts": 1.7e9, "type": "browser_log", "level": "error", "message": "...", "source": "browser", "url": "https://..."}}
```

Filter-on-subscribe isn't built in (yet) — clients receive all events and
filter by `record.type` / `record.source` locally.

### Browser console tunnel

[`browser.js`](browser.js) is a self-contained snippet that overrides
`console.log` / `warn` / `error` / `info` / `debug` and forwards each call
to `POST /log`. Drop it into your dev web page:

```html
<script src="/path/to/llm-docker/src/builder-api/browser.js"></script>
<script>
  BuilderAPILog.init({
    url: 'http://localhost:6666',
    password: 'your-builder-api-password',
    source: 'my-web-app',   // becomes /events?type=my-web-app_log
  });
</script>
```

After init, every console log from the page shows up live on any open
`/ws` connection as a `record.type = "<source>_log"` event. It also
captures `window.onerror` and `unhandledrejection`, including stacks.

**Security note**: the password ends up in the page's JavaScript, so this
is only safe in local-dev / trusted-LAN setups. Don't paste this into a
site that strangers can load.

## Configuration

Every per-project setting lives in `.builder-api.toml` (or `.yml` if
`pyyaml` is installed, or `.json`). See `examples/.builder-api.toml` for a
heavily-commented reference.

Core keys:

| Key                 | Meaning |
|---------------------|---------|
| `name`              | Label shown in `/` and `/status` |
| `bind`              | Interface (`127.0.0.1` default, `0.0.0.0` to expose to LAN) |
| `port`              | TCP port (default 6666) |
| `password`          | API password. **Required** when `bind != 127.0.0.1`. Use `${BUILDER_API_PASSWORD}` to pull from env. |
| `auth_reads`        | Require auth on GETs too. Defaults `true` when bound non-loopback, else `false` |
| `[build].command`   | The one command the API is allowed to run for builds (legacy single-command shape) |
| `[build].allowed_args` | Closed whitelist of flag strings `[build].command` may receive from the API |
| `[build].timeout_s` | Hard kill after this many seconds (default 900) |
| `[build].dedupe_window_s` | Same fingerprint within this window collapses onto the existing `queue_id` (default 5; 0 disables) |
| `[jobs.<name>]`     | Recommended shape for multi-operation projects — see [Job templates](#job-templates) below |
| `[logs].<alias>`    | Maps an alias name to a file path under the project root |
| `[runtime].enabled` | Turn `/run` and `/stop` on |
| `[runtime].start_command` | The runtime process to launch (e.g. `"./my-app --server"`) |
| `[runtime].stop_signal` / `stop_timeout_s` | Graceful shutdown signal + grace window before SIGKILL |
| `[events].path`     | Append-only JSONL file; API reads and rotates it |
| `[events].max_bytes` / `drop_bytes` | Cap + drop-oldest rotation (default 200 MB / 10 MB) |
| `[security]...`     | Rate limit knobs: `auth_failures_per_min`, `lockout_s`, body/URL size caps |
| `plugin`            | Path to an optional Python plugin file (see below) |

Every path in the config is resolved against the project root at boot and
the server refuses to start if any of them escape the project tree.

### Hot-reload

The daemon polls `.builder-api.toml`'s mtime every ~1.5s. When it changes,
the file is re-parsed and (on success) atomically swapped into place. The
following take effect for **new** enqueues:

- `[jobs.*]` — new templates available immediately via `POST /job/<name>`
- `[build].command`, `[build].allowed_args`, `[build].timeout_s`,
  `[build].max_pending`, `[build].dedupe_window_s`
- `[logs].*` — new aliases reachable, removed aliases start returning 404

Already-running builds keep their snapshotted command + timeout — a hot
reload won't yank a build mid-flight. If the new file fails to parse,
the daemon logs the error and keeps the previous config in place.

The following **require a daemon restart** (won't hot-reload):

- `[runtime]`  — already-running processes can't be retroactively rebound
- `[security]` — auth lockout state and rate limiters are in-memory
- `[events].path` — opening a different jsonl midway corrupts ordering
- `plugin = "..."` — plugin imports register state at load time

`config_mtime` is exposed via `GET /jobs` so MCP clients can cheaply
detect when their cached schema is stale.

## Job templates

`[jobs.<name>]` is the recommended shape for projects with more than one
operation. Each block declares one named job with its own command, argv
template, placeholder regex/length caps, optional sha256 pin, and per-job
timeout. Same closed-whitelist security model as `[build]` — argv form
only, no shell, placeholders fully validated before execvp.

### Schema

```toml
[jobs.<name>]
command     = "vendor/bin/phpunit"   # executable, resolved at request time
args        = ["--filter", "{test}"] # argv tail; "{name}" must be a STANDALONE element
timeout_s   = 60                     # default 60 (lower than build's 900 because most jobs are short)
description = "..."                  # optional; surfaces in /jobs and MCP tool docs
sha256      = "<64-char hex>"        # optional; integrity check on the resolved command file

[jobs.<name>.placeholders.<key>]
regex       = "^[A-Za-z0-9_]+$"      # required; Python regex, must fullmatch the value
max_len     = 200                    # default 200
required    = true                   # default true; false → omitting drops the corresponding argv slot
description = "..."                  # optional; flows into MCP per-param docs
```

### Constraints enforced at config load

The daemon refuses to start if any of these are violated:

- placeholder names match `^[A-Za-z_][A-Za-z0-9_]*$`
- every `{name}` reference in `args` resolves to a declared placeholder
- placeholders are **standalone array elements** — `args = ["--filter={test}"]`
  or `args = ["pre-{test}-suf"]` are rejected. This forces the argv-form
  pattern that prevents accidental shell-style interpolation
- every declared placeholder is referenced (no dead schema entries)
- every placeholder regex compiles
- if `sha256` is set, it's exactly 64 chars of lowercase hex
- `timeout_s >= 1`

### Calling a job

```bash
curl -X POST http://127.0.0.1:6666/job/phpunit \
  -H "X-Builder-API-Password: $BUILDER_API_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"params": {"test": "PinCreateTest"}, "agent_id": "my-mcp"}'
```

Response: `202 Accepted` with the queue entry, including `queue_id`,
`job_name`, the validated `params`, the resolved `command`, and the
snapshotted `timeout_s`. Poll `GET /build_status?id=<queue_id>&wait=30`
to long-poll for completion.

Add `?dryrun=1` to validate + return what would run, without enqueueing:

```bash
curl -X POST 'http://127.0.0.1:6666/job/phpunit?dryrun=1' \
  -H "X-Builder-API-Password: $BUILDER_API_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"params":{"test":"PinCreateTest"}}'
# {"dryrun": true, "job": "phpunit", "would_run": ["vendor/bin/phpunit", "--filter", "PinCreateTest"], ...}
```

### Validation error shapes (locked)

The `POST /job/<name>` endpoint returns one of these structured errors.
MCP clients should pin against these shapes — they're stable.

**HTTP 400 — placeholder validation failed:**
```json
{
  "error":         "validation_failed",
  "endpoint":      "/job/phpunit",
  "field":         "test",
  "reason":        "regex_mismatch",
  "expected":      "^[A-Za-z][A-Za-z0-9_]*$",
  "value_preview": "'Pin Create...'"
}
```
`reason` is one of `regex_mismatch | max_len_exceeded | missing_required
| wrong_type | unknown_param`. `expected` is the regex string, the
integer cap, the type name, or the list of valid param names depending
on `reason`. `value_preview` is omitted for `missing_required`; otherwise
a 64-char repr-truncation of the offending value.

**HTTP 404 — unknown job name:**
```json
{"error": "unknown_job", "name": "phpnit", "available": ["build", "compose-ps", "phpunit"]}
```

**HTTP 412 — sha256 hash mismatch:**
```json
{
  "error":           "command_hash_mismatch",
  "job":             "phpunit",
  "command":         "/abs/path/vendor/bin/phpunit",
  "expected_sha256": "abc123...",
  "actual_sha256":   "def456..."
}
```

**HTTP 412 — command not found:**
```json
{"error": "command_not_found", "job": "phpunit", "command": "vendor/bin/phpunit"}
```

**HTTP 429 — pending queue at capacity** (existing shape):
```json
{"error": "pending queue at capacity (32)"}
```

### Introspection: `GET /jobs`

```json
{
  "jobs": {
    "phpunit": {
      "command":       "vendor/bin/phpunit",
      "args_template": ["--filter", "{test}"],
      "timeout_s":     60,
      "description":   "Run a PHPUnit class by name",
      "sha256_pinned": true,
      "placeholders": {
        "test": {
          "regex":       "^[A-Za-z][A-Za-z0-9_]*$",
          "max_len":     200,
          "required":    true,
          "description": "PHPUnit test class name"
        }
      }
    }
  },
  "build": { "command": "...", "allowed_args": [...], "timeout_s": 900, "dedupe_window_s": 5 },
  "config_version": "0.2",
  "config_mtime":   1715000000.0
}
```

`sha256_pinned` is a bool — the actual hash is never returned. `config_mtime`
is exposed so consumers can cheaply detect hot-reloads (compare on each tool
call; refresh schema only when mtime changes).

### Per-stack examples

Bundled under `examples/`:

- [`.builder-api.toml`](examples/.builder-api.toml) — the annotated reference
- [`quake/.builder-api.toml`](examples/quake/.builder-api.toml) — Quake make/test/rcon
- [`node/.builder-api.toml`](examples/node/.builder-api.toml) — npm test/build/lint with jest pattern + path placeholders
- [`php-docker-compose/.builder-api.toml`](examples/php-docker-compose/.builder-api.toml) — full docker-compose verb set with whitelisted artisan/composer subcommands

## Security model — read this

This API is a **privileged surface**: it can launch processes on your host.
Anything less than careful thinking here turns it into an escape vector.

**What the API cannot do via HTTP:**

- Modify `.builder-api.toml`, your plugin file, or any file it hasn't
  declared. Config is read once at startup; there is no `/reload`.
- Run arbitrary shell commands. The only commands ever executed are
  `[build].command` (with whitelisted args) and `[runtime].start_command`.
- Read files outside the project root. Log aliases are resolved at
  startup; any that escape the root abort the server before it binds.
- Receive free-form arguments. Every request body is validated against
  a fixed schema; args must be in the build whitelist.

**What it does to protect itself:**

- `execvp` throughout — no `sh -c`, so shell metacharacters in a
  whitelisted arg are inert.
- Rate limit on failed-auth attempts per IP (default 10/min → 5 min
  lockout). Warnings print to stderr and append to the events feed.
- Non-loopback binds force `password` to be set; server won't start
  otherwise.
- `auth_reads = true` by default on non-loopback binds, so `/logs` and
  `/events` aren't passive data leaks on your LAN.
- `/ws` always requires auth, even when `auth_reads = false`.
- Bounded body (1 MB) and URL (8 KB) sizes per request.

**What's your responsibility:**

- Keep the password out of git. Use
  `password = "${BUILDER_API_PASSWORD}"` and export it in your shell.
- If your build needs shell features (`cd foo && make`), wrap them in
  a script (`./build.sh`) that the API invokes. `execvp` is not a shell.
- Only set `plugin = "builder_plugin.py"` when you wrote the plugin
  yourself or fully trust whoever did. **A plugin runs unrestricted in
  the server process.** Copying a project directory from the internet
  with an unfamiliar `builder_plugin.py` is the same as running
  unknown Python with write access to your home directory.

## Plugin API (optional)

Drop a `builder_plugin.py` in the project root and set `plugin =
"builder_plugin.py"` in the config. Every symbol below is optional.

```python
def on_build_start(entry):       ...   # entry has id, args, agent_id, started_at
def on_build_finish(entry):      ...   # entry adds returncode, status, log_tail
def on_run_start(pid):           ...
def on_run_exit(pid, cause):     ...   # cause: 'api_stop'|'restart'|'self_exit'|'daemon_shutdown'

def handlers():
    # Custom HTTP endpoints. Returns {path: {METHOD: fn}}.
    # Each fn takes (body_dict, handler, query=dict) and returns a JSON-serialisable dict.
    return {
        '/hello': {'GET': _hello},
    }

def _hello(body, handler, query=None):
    return {'msg': 'hi from plugin'}
```

Lifecycle hooks are fire-and-forget — exceptions are logged, never
propagated. Handler exceptions return HTTP 500 with the error text.

## Env vars the Docker client reads

The shipped `client.py` honours these so the same code works across
projects that use different ports/passwords:

| Env var                | Default                | Used for |
|------------------------|------------------------|----------|
| `BUILDER_API_HOST`     | `host.docker.internal` | Daemon hostname from container's view |
| `BUILDER_API_PORT`     | `6666`                 | Daemon port |
| `BUILDER_API_PASSWORD` | *(none)*               | Sent as `X-Builder-API-Password` header |
| `BUILDER_AGENT_ID`     | *(none)*               | Optional `X-Agent-ID` label for queue history |

The llm-docker `cld`/`ocd` wrappers forward these into the container
already; you just set them in `.env`.

## Running it

There's no daemoniser — you start it in a terminal:

```sh
python3 server.py                           # reads .builder-api.toml from cwd
BUILDER_API_PASSWORD=secret python3 server.py
```

To keep it alive across reboots, wrap in launchd / systemd / tmux / whatever
you already use. `SIGINT`/`SIGTERM` shut down cleanly — the build queue is
drained in-flight (or cancelled), the runtime process group is killed, and
no orphans are left behind.

## Requirements

- **Python 3.11+** for native `tomllib`. JSON configs work on older
  Pythons. YAML needs `pip install pyyaml`.
- No other runtime dependencies.

## Files

```
server.py         Entry point, HTTP routing
config.py         Config loader + schema validation + path scoping
security.py       Auth gate + per-IP rate limiter + body/URL size caps
build_queue.py    Build FIFO, worker thread, long-poll wait, log_tail
runtime.py        /run /stop /status + process group cleanup
logs.py           Alias-scoped log tail + live watcher
events.py         Read-filter + rotating append for the JSONL feed
ws.py             WebSocket handshake + per-session streaming loop
plugin.py         Optional plugin loader (dynamic import, validated)
client.py         Docker-side HTTP helper (import from your code)
examples/         Starter configs + minimal Makefile project
```
