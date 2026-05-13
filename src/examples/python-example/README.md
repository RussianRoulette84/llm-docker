# python-example

Reference Python project wired up to **llm-docker**: FastAPI dev server +
builder-api jobs (lint/test/install) + 5 MCP servers (playwright, filesystem,
git, llm-docker-logs, llm-docker-ops). Copy this whole directory to start
your own Python project with the autonomous-dev-loop already configured.

```
python-example/
├── .mcp.json              ← MCP servers Claude/OpenCode will use
├── .env.example           ← rename to .env, set BUILDER_API_PASSWORD
├── pyproject.toml         ← FastAPI + dev deps
├── src/python_example/
│   └── main.py            ← FastAPI app — the "/run" runtime target
├── tests/
│   └── test_main.py
└── scripts/mcp/
    ├── logs-server/       ← MCP: tail/grep/list logs in ./logs/
    └── ops-server/        ← MCP: proxy to host builder-api
                            (list_jobs, run_job, queue, run, stop, ...)
```

## Wiring it to llm-docker

1. **Copy this directory** to wherever you keep projects:
   ```sh
   cp -R /path/to/llm-docker/src/examples/python-example ~/Projects/my-app
   cd ~/Projects/my-app
   ```

2. **Add a project block** to `~/.llm-docker/builder-api.toml`:
   ```toml
   [project.my-app]
     root      = "~/Projects/my-app"
     port      = 6701
     languages = ["python"]
     [project.my-app.runtime]
       enabled        = true
       start_command  = ".venv/bin/uvicorn python_example.main:app --host 0.0.0.0 --port 8000 --reload"
       cwd            = "."
       stop_signal    = "SIGTERM"
       stop_timeout_s = 5
   ```
   The `python` language pack already ships `pytest`, `ruff`, `mypy`,
   `pip-install` — they'll show up automatically in `list_jobs`.

3. **Install deps** (one-time):
   ```sh
   python3 -m venv .venv
   .venv/bin/pip install -e ".[dev]"
   cd scripts/mcp/logs-server && npm install
   cd ../ops-server && npm install
   cd ../../..
   ```

4. **Set the password** — same value as `[defaults].password` in your host toml:
   ```sh
   cp .env.example .env
   $EDITOR .env       # set BUILDER_API_PASSWORD
   ```

5. **Launch**:
   ```sh
   cld -a               # spawns the builder-api daemon for this project,
                        # then opens Claude inside the container with all
                        # 5 MCP servers connected
   ```

## What Claude can do once it's running

- **Run** — `run_job` with `name="pytest"` or `name="ruff"`; `run` /
  `stop` for the FastAPI dev server.
- **See** — `playwright` MCP navigates to `http://host.docker.internal:8000`
  and reads the DOM / takes screenshots.
- **Hear** — `recent_errors` and `tail_log` surface uvicorn output;
  `tests/test_main.py` failures land in `logs/test.log` (if you wire your
  test job to write there).
- **Touch** — `playwright` MCP can click, fill forms, drag — the entire
  Puppeteer surface, headless or headful.

## Customise

- **Add a project-specific job** — drop a `[project.my-app.jobs.<name>]`
  block in `~/.llm-docker/builder-api.toml`. Don't add jobs in this
  directory — the daemon won't read them.
- **Change the runtime** — edit `[project.my-app.runtime].start_command`
  in the host toml.
- **Different log dir** — set `MCP_LOG_DIRS=logs:tmp/logs` in `.mcp.json`'s
  llm-docker-logs `env` block.

## NOT in this example (intentional)

- No `.builder-api.toml` in this directory. Per-project tomls are ignored
  by the daemon — everything lives in `~/.llm-docker/builder-api.toml`.
- No plugin loader. The feature was removed (was a host-exec escape path).
- No Docker stack. This is meant to run directly on your Mac; the FastAPI
  process lives on the host, and the container reaches it via
  `host.docker.internal:8000`.
