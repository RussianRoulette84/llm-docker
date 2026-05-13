---
description: Wire (or refresh) a Python / PHP / Node project for llm-docker's Builder API. Drops MCP servers + .mcp.json + .env.example + .gitignore entries, then prints the [project.<name>] block to paste into ~/.llm-docker/builder-api.toml.
argument-hint: [optional: "python" | "php" | "node" | "auto" — default: auto-detect]
allowed-tools: Bash, Read, Edit, Write
---

# LLM-DOCKER-BUILDER-API-BOOTSTRAP

Wizard-style setup for integrating ANY project with the host-side
Builder API. Safe to re-run after upgrading llm-docker — overwrites
the MCP servers (always shipped fresh), merges into `.mcp.json`,
appends to `.gitignore`, never blows away user-authored files.

**Does NOT touch `~/.llm-docker/builder-api.toml`.** Prints the
`[project.<name>]` block at the end; the user pastes it. The host
toml is a trust boundary — every job that runs on the Mac must be
added consciously.

## Variables

PROJECT_DIR: `$(pwd)` (always run from the project root).
PROJECT_NAME: `$(basename "$PROJECT_DIR")` — must match a future
`[project.<PROJECT_NAME>]` block in the host toml.
LANG: `$ARGUMENTS` (one of `python`, `php`, `node`, `auto`; default `auto`).
LLM_DOCKER_REPO: `${LLM_DOCKER_REPO:-$HOME/Projects/llm-docker}`.

## Wizard phases — confirm before each mutation

### Phase 0 — Sanity checks

1. We're in a project root (look for `.git/`, or any of `pyproject.toml`,
   `composer.json`, `package.json`). If none, ABORT — "run this from your
   project's root, not from `/` or a random subdir".
2. Confirm `LLM_DOCKER_REPO` exists and contains
   `src/examples/python-example/scripts/mcp/` (canonical source of the
   shipped MCP servers). If not, ABORT with the path it tried.
3. If `PROJECT_NAME == "llm-docker"` (running inside the cage source
   itself): proceed normally. The starter template already ships a
   `[project.llm-docker]` block with custom dev jobs (`smoke`,
   `lint-shell`, `syntax-py`), so Phase 6 may print "existing block
   found" rather than "new block to append".

### Phase 1 — Detect language

If `LANG=auto`: detect via file presence. Each detection is additive
(a docker-compose stack with PHP backend = `["php", "compose"]`).

| Marker file | Language tag |
|---|---|
| `pyproject.toml` / `setup.py` / `requirements.txt` | `python` |
| `composer.json` | `php` |
| `package.json` (and not just an MCP server's package.json) | `node` |
| `docker-compose.yml` / `docker-compose.yaml` / `compose.yml` | `compose` |

Print: "Detected: `python`, `compose`". Ask user to confirm or override
(`python php node compose` — space-separated; user can drop / add tags).

### Phase 2 — Validate host config exists (read-only)

Check `~/.llm-docker/builder-api.toml` exists. If not, instruct:

```sh
mkdir -p ~/.llm-docker
cp "$LLM_DOCKER_REPO/src/builder-api/builder-api.host.toml.example" \
   ~/.llm-docker/builder-api.toml
chmod 600 ~/.llm-docker/builder-api.toml
$EDITOR ~/.llm-docker/builder-api.toml
```

…and STOP. (Don't proceed without the host file — the daemon won't start.)

Also check the file already has `[project.<PROJECT_NAME>]`. If yes, note
"existing block found — Phase 6 will print an update suggestion". If no,
note "Phase 6 will print a NEW block to append".

### Phase 3 — MCP servers (overwrite-safe)

Drop the generic logs + ops MCP servers into `scripts/mcp/`. These are
shipped with llm-docker and updated on every upgrade — always overwrite.

```sh
mkdir -p scripts/mcp/logs-server scripts/mcp/ops-server
cp "$LLM_DOCKER_REPO/src/examples/python-example/scripts/mcp/logs-server/index.js"      scripts/mcp/logs-server/
cp "$LLM_DOCKER_REPO/src/examples/python-example/scripts/mcp/logs-server/package.json"  scripts/mcp/logs-server/
cp "$LLM_DOCKER_REPO/src/examples/python-example/scripts/mcp/ops-server/index.js"       scripts/mcp/ops-server/
cp "$LLM_DOCKER_REPO/src/examples/python-example/scripts/mcp/ops-server/package.json"   scripts/mcp/ops-server/
```

The Python and PHP examples ship identical MCP server files, so the
python-example/ subtree is the canonical source.

Tell the user: "MCP servers shipped/refreshed. Run `cd scripts/mcp/logs-server && npm install && cd ../ops-server && npm install` to install Node deps."

### Phase 4 — `.mcp.json` (merge-safe)

- **Does NOT exist** → copy
  `$LLM_DOCKER_REPO/src/examples/python-example/.mcp.json` to `.mcp.json`
  and stop.
- **Exists** → read it as JSON, then for each of:
  - `playwright`, `filesystem`, `git`, `llm-docker-logs`, `llm-docker-ops`
  insert into `mcpServers` ONLY IF MISSING. Never replace an existing
  entry — user might have customised it. Show a diff before writing.

### Phase 5 — `.env.example` + `.gitignore` (append-safe)

`.env.example`: ensure the file contains `BUILDER_API_PASSWORD=` (add the
line if missing; do not touch other lines).

`.gitignore`: append any of the following lines that aren't already present:

```
# Builder API integration
.env
scripts/mcp/*/node_modules/
scripts/mcp/*/package-lock.json
logs/
```

If the file doesn't exist, copy
`$LLM_DOCKER_REPO/src/examples/python-example/.gitignore` to start.

### Phase 6 — Print `[project.<name>]` block (do NOT write the host toml)

Generate the block from detected languages + project layout. Print inside
a `toml` code fence so the user can copy-paste.

Template (adjust to detected stack):

```toml
[project.<PROJECT_NAME>]
  root      = "<absolute project path with ~ expanded>"
  port      = <suggest first unused port: 6701, 6702, ... based on existing [project.*] blocks>
  languages = [<detected tags>]

  # OPTIONAL — long-lived dev server. Comment out if not needed.
  [project.<PROJECT_NAME>.runtime]
    enabled        = true
    start_command  = "<derived from language: see below>"
    cwd            = "."
    stop_signal    = "SIGTERM"
    stop_timeout_s = 5
```

Default `start_command` heuristics:
- `python` + FastAPI marker (`from fastapi import FastAPI` anywhere in src/) → `.venv/bin/uvicorn <pkg>.main:app --host 0.0.0.0 --port 8000 --reload`
- `python` + Django marker (`manage.py` exists) → `.venv/bin/python manage.py runserver 0.0.0.0:8000`
- `php` + `public/index.php` → `php -S 0.0.0.0:8000 -t public`
- `php` + `artisan` exists → `php artisan serve --host=0.0.0.0 --port=8000`
- `node` + `package.json` has `scripts.dev` → `npm run dev`
- `node` + `package.json` has `scripts.start` (no dev) → `npm run start`
- `compose` (only language tag, or with others) → `docker compose up`
- Nothing matches → leave `start_command = ""` and `enabled = false`, tell the user to fill it in.

If a `[project.<PROJECT_NAME>]` block already exists in the host toml,
print the new block alongside a one-line "diff hint": "existing block has
port X; suggested update keeps port X but refreshes languages =
[detected tags]".

### Phase 7 — Print next steps

A clean checklist in chat:

```
NEXT STEPS — do these on your Mac, then `cld -a` from <PROJECT_DIR>:

  1. Open ~/.llm-docker/builder-api.toml and paste the block above.
     (Adjust port if 670N is taken by another project.)

  2. Install Node deps for the bundled MCP servers:
        cd <PROJECT_DIR>/scripts/mcp/logs-server && npm install
        cd ../ops-server && npm install
        cd ../../..

  3. Ensure BUILDER_API_PASSWORD is set on your shell — same value as
     [defaults].password in the host toml.

  4. (Optional) For per-project secrets, copy .env.example to .env and
     fill it in. NEVER commit .env (already in .gitignore).

  5. Launch:
        cd <PROJECT_DIR>
        cld -a
```

## Operating principles

- **Never edit `~/.llm-docker/builder-api.toml`.** Print, don't paste-on-behalf.
- **Never edit `llm-docker/` itself.** The cage source is read-only from
  inside any project.
- **Idempotent.** Every phase: detect → diff → confirm → mutate. Re-running
  after a llm-docker upgrade refreshes the MCP servers without touching
  user-authored files.
- **Wizard, not autopilot.** STOP at every phase boundary for user
  confirmation. The user can say `skip` / `next` to advance, `stop` to
  abort, or `apply all` once to skip the rest of the prompts.
- **Voice dictation rule applies** — `bootstrap` may come in as `boot strap`
  or `boots trap`. Translate silently.

## Out of scope

- Editing the host toml. Always a copy-paste step.
- Creating a project from scratch (use `cp -R` from `src/examples/python-example/`
  or `src/examples/php-example/` if you want a starter).
- Installing Node / Python / PHP / Composer themselves.
- Authoring custom jobs. Those go in the host toml under
  `[project.<name>.jobs.<custom>]` — that's user editorial work.

After all phases, follow up with the standard reporting footer per
`CLAUDE.md` (Request / Done / Success / Concerns / Optimizations /
Hacks / Next steps).
