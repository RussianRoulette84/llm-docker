# Setting up a project with the Builder API (+ optional s3c-gorilla)

A practical, copy-paste walkthrough for giving one of your projects the
**Builder API** — so Claude/OpenCode inside the container can build, test, run,
and read logs on your Mac — and, optionally, wiring **s3c-gorilla** so its
secrets come from your KeePassXC vault instead of a `.env` file.

> Run every command below on your **Mac** (the host). The container can't see
> `~/.llm-docker`. Replace `myapp` with your project's folder name throughout.

---

## 0. What you get

- `cld -a` (or `ocd -a`) spawns a **builder-api panel** + a **cld-status**
  dashboard next to your session (iTerm split; Terminal.app gets a single
  window).
- The agent can call host jobs (`pytest`, `npm build`, `composer install`, a
  dev server, …) over HTTP — no toolchain baked into the image.
- Every command the API can run is declared by **you** in one host-owned file.
  A prompt-injected agent can't add or change jobs.

**Prereqs:** Docker running, llm-docker installed (`cld` on PATH), and on macOS
**iTerm2** is recommended for the panels (<https://iterm2.com/downloads.html>).

---

## 1. One-time host setup (once per Mac)

The daemon reads everything from `~/.llm-docker/api_config/`:

- `builder-api.toml` — **base**: defaults, global jobs, language packs.
- `<project>.toml` — **one shard per project**: its `[project.<name>]` block.

Seed the base file from the template (skip if it already exists):

```
mkdir -p ~/.llm-docker/api_config
cp ~/Projects/llm-docker/src/builder-api/api_config/builder-api.toml \
   ~/.llm-docker/api_config/builder-api.toml
```

Set the shared password once, in llm-docker's **own** `.env` (the container can
read this; if you don't trust that, use s3c-gorilla — see §5). Note: env vars
are leet-renamed to defeat malware that greps for `KEY / TOKEN / PASSWORD`.
Full rename map at the top of `src/.env.example`:

```
echo "BUILDER_API_P4SS=$(openssl rand -hex 16)" >> ~/Projects/llm-docker/src/.env
```

> ⚠️ Treat `~/.llm-docker/api_config/builder-api.toml` like `sudoers`. Every job
> is "Claude may run this on my Mac." No `bash -c` jobs, no `regex = ".*"`.

---

## 2. Add your project (a shard file)

Create `~/.llm-docker/api_config/myapp.toml`. Pick a **unique port** per project
(6666 is llm-docker's; use 6701, 6702, … for yours). Opt into the language packs
you want — that's how the project inherits `pytest`, `npm-build`, etc.

```toml
[project.myapp]
root      = "~/Projects/myapp"
port      = 6701
languages = ["python"]            # any of: python, php, node, compose

# Optional: a long-lived dev server the agent can start/stop/restart via /run /stop.
[project.myapp.runtime]
enabled       = true
start_command = "python -m uvicorn app:app --reload --port 8000"

# Optional: a project-specific job (beyond the language packs).
[project.myapp.jobs.deploy]
command     = "scripts/deploy.sh"
args        = []
timeout_s   = 120
description = "Deploy myapp"
```

**Job rules** (enforced at config load):
- Placeholders must be standalone argv elements: `args = ["--filter", "{x}"]` ✅,
  `args = ["--filter={x}"]` ❌. Each `{x}` needs an anchored `regex`.
- Commands run via `execvp` (no shell) — shell metacharacters are literal.
- For a binary inside the repo (`vendor/bin/...`), pin it with `command_hash`
  or point at a host path; a hostile agent could otherwise swap the file.

**Recommended shard layout** (once you have more than ~10 jobs — keeps the file
scannable when Claude/OpenCode has to reason about it):

```
1.  header comment           project purpose + which services are launchd/brew/docker
2.  [project.<name>]         header block (root, port, languages, description)
3.  GENERIC VERBS section    up / down / restart / build / lint / test / logs /
                             status / deploy — all platform-based
4.  NAMED JOBS section       grouped by domain, in this order:
    - services               env-seed, launchd wrappers
    - apps                   per-app groups (each: install → up → down → restart →
                             status → tail → build → test → variants)
    - dev tools              smoke, lint variants, format, preview, e2e, mypy
    - package management     npm, pip, other package managers
    - escape hatch           the regulated `sa`-style passthrough (if any)
    - data                   postgres, db utilities, migrations
    - extras                 xcode schemes, one-offs
```

Reference examples in the repo:
- `src/builder-api/api_config/project_python.toml` — Python-heavy (FastAPI + Django + Vite + Swift), launchd services, brew redis, pytest / e2e / mypy dev tools
- `src/builder-api/api_config/project_php.toml` — PHP-heavy (Lumen + Slim in docker-compose), Angular workspace, iOS + Objective-C library, Envoy-based deploys, allowlist compose-exec pattern
- `src/builder-api/api_config/project_rust.toml` — Rust binary crate (cargo build / clippy / nextest / audit), a long-lived `cargo run` runtime, and the smallest useful shard: self-contained, almost no placeholders

All three follow the layout above and are safe to copy-and-rename as your starting point.

Save it — the daemon **hot-reloads** within ~2s; new jobs apply on next enqueue.

---

## 3. Launch & verify

```
cd ~/Projects/myapp
cld -a            # or: ocd -a
```

You should see the builder-api panel come up on `myapp`'s port and the
cld-status dashboard. Quick check that jobs resolved:

```
curl -s -H "X-Builder-API-Password: $BUILDER_API_P4SS" \
  http://127.0.0.1:6701/jobs | python3 -m json.tool | head
```

From inside the container the agent calls jobs via the bundled client
(`client.run_job("pytest", params={})`) or the `*-ops` MCP tools.

When you quit `cld`/`ocd` (Ctrl+C twice), the daemon is stopped and both panes
close automatically — scoped to this project's port, so other sessions' panels
are left alone.

---

## 4. Keep the repo mirror in sync (optional)

llm-docker tracks a copy of these configs under `src/builder-api/api_config/` for versioning.
After editing the live host config, back it up (or deploy a tracked one):

```
cp -f ~/.llm-docker/api_config/*.toml ~/Projects/llm-docker/src/builder-api/api_config/   # host → repo
cp -f ~/Projects/llm-docker/src/builder-api/api_config/*.toml ~/.llm-docker/api_config/   # repo → host
```

Or use the bundled helper: `src/builder-api/tomlify.sh all` (repo → host).

---

## 5. Optional: secrets from the vault (s3c-gorilla)

Instead of keeping `BUILDER_API_PASSWORD` / API keys in `.env`, pull them from an
encrypted KeePassXC database at launch (Touch ID, or password-only on a
Hackintosh). See [s3c-gorilla](https://github.com/RussianRoulette84/s3c-gorilla).

1. **Enable it** — the installer asks at step 3 (default on), or set it by hand
   in `~/Projects/llm-docker/src/llm-docker.conf` (underscores only):
   ```
   IS_S3C_GORILLA_ENABLED=true
   ```
   When on, `cld`/`ocd` re-exec through `env-gorilla llm-docker -- …` and `.env`
   becomes an optional fallback.

2. **Install gorilla** (the installer offers this at the end too):
   ```
   bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/s3c-gorilla/master/src/install.sh)
   ```

3. **Populate the vault** — in KeePassXC, create an entry titled **`llm-docker`**,
   then Advanced → Attachments → add a file named **`.env`** containing your
   secrets. Use the leet-renamed names (see `src/.env.example` for the full
   rename map):
   ```
   _4NTHR0P1C_H4NDLE=...          # was ANTHROPIC_API_KEY
   BUILDER_API_P4SS=...           # was BUILDER_API_PASSWORD
   G1TL4B_LLMD0CKER_TEKKEN=...    # was GITLAB_LLMDOCKER_TOKEN
   ```
   Per-project secrets go in a second entry titled like the **project folder**
   (`myapp`). env-gorilla merges the `llm-docker` + `<project>` profiles into one
   unlock.

4. **Launch as usual** — `cld -a` unlocks the vault once and injects the secrets;
   nothing is written to disk.

If `IS_S3C_GORILLA_ENABLED=true` but env-gorilla isn't installed, `cld`/`ocd`
fall back to `.env` quietly (one dim warning only on a fresh launch with no
`.env`; continue/resume stays silent).

---

## 5b. Optional: outbound SSH — container reaches your servers

The container ships with an in-container ssh-agent. Keys live in agent memory
only — they're never written to disk. Three ways to set outbound SSH up:

**Path A — vault (recommended if you use s3c-gorilla).**
- Attach the private keys as base64 env vars on `ENV/llm-docker`: `LLMD0CKER_SHH_3D25519_PVYT_B64`, `PS4_SHH_3D25519_PVYT_B64`.
- Attach the ssh config as a real file to `SSH/llm-docker-ssh-config` (a plain text attachment named `config`).
- env-gorilla drops the config file at `$S3C_ATTACHMENT_DIR/config` on unlock; the container copies it into `/root/.ssh/config` at startup.

**Path B — plain .env (no vault).**
- Run `install.sh` step **6b** to generate a fresh `llmdocker_ed25519` outbound key and seed a starter `~/.ssh/config` template into `LLM_D0CKER_SHH_CFG_B64`.
- Edit `.env` afterward to add real host blocks. The container decodes both at startup.

**Remote user provisioning — `src/tools/provision-llmdocker.sh`.**
- Bootstrap the `llmdocker` user on a fresh server with **full `NOPASSWD` sudo** minus a narrow denylist for root deletion / password change / `su` to root / `rm /root`. Idempotent, works on Debian/Ubuntu, RHEL/Rocky/Alma/Fedora/Amazon, Alpine. See `src/tools/README.md` for usage examples.
- Step **6b** of `install.sh` offers to run it against a hostname you provide, or you can run it later against any server via a one-line `ssh admin@host bash -s -- --pubkey '<key>' < provision-llmdocker.sh`.

---

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `CONFIG ERROR: host config not found` | `cp` the template to `~/.llm-docker/api_config/builder-api.toml` (§1). |
| `CONFIG ERROR: no [project.<name>]` | Your shard's block name must match the **folder** basename. Add `[project.myapp]`. |
| `GET /jobs` empty / 401 | Wrong/missing `BUILDER_API_P4SS`, or the port doesn't match the shard. |
| Panel opens in a separate window | iTerm not installed/denied AppleScript — install iTerm2 or grant Automation. |
| Edited config, nothing changed | Job/alias edits hot-reload (~2s). Bind/port/runtime changes need a daemon restart (quit + `cld -a`). |

**Read more:** full API reference in
[`src/builder-api/README.md`](../src/builder-api/README.md).
