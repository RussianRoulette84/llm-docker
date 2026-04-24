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
| POST   | `/build`                        | Enqueue a build, returns `queue_id` |
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
| `[build].command`   | The one command the API is allowed to run for builds |
| `[build].allowed_args` | Closed whitelist of flag strings `[build].command` may receive from the API |
| `[build].timeout_s` | Hard kill after this many seconds (default 900) |
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
