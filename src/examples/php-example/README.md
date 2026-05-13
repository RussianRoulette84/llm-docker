# php-example

Reference PHP project wired up to **llm-docker**: built-in PHP dev server +
builder-api jobs (phpunit/pint/composer-install) + 5 MCP servers (playwright,
filesystem, git, llm-docker-logs, llm-docker-ops). Copy this whole directory
to start your own PHP project with the autonomous-dev-loop already configured.

```
php-example/
├── .mcp.json              ← MCP servers Claude/OpenCode will use
├── .env.example           ← rename to .env, set BUILDER_API_PASSWORD
├── composer.json          ← PHPUnit + Pint (dev-only)
├── phpunit.xml            ← PHPUnit config
├── public/
│   └── index.php          ← entry point — the "/run" runtime target
├── src/
│   └── Greeter.php        ← tiny domain class
├── tests/
│   └── GreeterTest.php
└── scripts/mcp/
    ├── logs-server/       ← MCP: tail/grep/list logs in ./logs/
    └── ops-server/        ← MCP: proxy to host builder-api
                            (list_jobs, run_job, queue, run, stop, ...)
```

## Wiring it to llm-docker

1. **Copy this directory** to wherever you keep projects:
   ```sh
   cp -R /path/to/llm-docker/src/examples/php-example ~/Projects/my-app
   cd ~/Projects/my-app
   ```

2. **Add a project block** to `~/.llm-docker/builder-api.toml`:
   ```toml
   [project.my-app]
     root      = "~/Projects/my-app"
     port      = 6801
     languages = ["php"]
     [project.my-app.runtime]
       enabled        = true
       start_command  = "php -S 0.0.0.0:8000 -t public"
       cwd            = "."
       stop_signal    = "SIGTERM"
       stop_timeout_s = 5
   ```
   The `php` language pack already ships `phpunit`, `phpunit-filter`,
   `pint`, `composer-install` — they'll show up automatically in `list_jobs`.

3. **Install deps** (one-time):
   ```sh
   composer install
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

- **Run** — `run_job` with `name="phpunit"` (whole suite) or
  `name="phpunit-filter"` with `{test: "GreeterTest"}` (one class).
  `run` / `stop` for the built-in PHP dev server.
- **See** — `playwright` MCP navigates to `http://host.docker.internal:8000`
  and reads the DOM / takes screenshots.
- **Hear** — `recent_errors` and `tail_log` surface PHP errors;
  `tests/*` failures land in `logs/test.log` (if you redirect phpunit output).
- **Touch** — `playwright` MCP can click, fill forms, drag — the entire
  Puppeteer surface, headless or headful.

## Customise

- **Add a project-specific job** — drop a `[project.my-app.jobs.<name>]`
  block in `~/.llm-docker/builder-api.toml`. Don't add jobs in this
  directory — the daemon won't read them.
- **Change the runtime** — edit `[project.my-app.runtime].start_command`
  in the host toml. Swap the built-in `php -S` for `php artisan serve`,
  `symfony server:start`, or a docker-compose stack.
- **Different log dir** — set `MCP_LOG_DIRS=logs:storage/logs` in
  `.mcp.json`'s llm-docker-logs `env` block.
- **Add docker-compose** — declare `languages = ["php", "compose"]` in
  the host toml and the `compose-ps` / `compose-up` / `compose-down` /
  `compose-logs` jobs become available.

## NOT in this example (intentional)

- No `.builder-api.toml` in this directory. Per-project tomls are ignored
  by the daemon — everything lives in `~/.llm-docker/builder-api.toml`.
- No plugin loader. The feature was removed (was a host-exec escape path).
- No Docker stack. This is meant to run directly on your Mac via the
  built-in PHP server; the PHP process lives on the host, and the
  container reaches it via `host.docker.internal:8000`. If you want a
  Laravel/Lumen + nginx + mysql stack, swap the runtime `start_command`
  for `docker compose up` and opt into the `compose` language pack.
