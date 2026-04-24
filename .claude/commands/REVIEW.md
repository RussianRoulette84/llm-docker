---
description: Review recent changes for shell + Python + Docker issues
---

# Code Review (llm-docker)

Review the set of changed files for the class of issues that actually occur
in this project: shell-isms, Python wiring, Dockerfile correctness,
secret/privilege scopes.

## Scope

- **Shell**: `src/cld`, `src/ocd`, `src/install.sh`, `src/setup.sh`, `src/ascii.sh`,
  `src/docker/install_devpack.sh`, `src/docker/docker-entrypoint.sh`, `src/builder-api/run-local.sh`.
- **Python**: `src/builder-api/*.py`.
- **Docker**: `src/Dockerfile`.
- **Config**: `src/.env.example`, `src/llm-docker.conf`, `src/llm-container-opencode-config.jsonc`,
  `src/llm-container-claude-settings.json`, `src/builder-api/examples/*`.
- **AppleScript**: `src/*.applescript` (minor — mostly light validation).

## Checks

Run these against the changed files. Use each tool if it's on PATH; otherwise
note the gap and check by eye.

| Concern | Tool / pattern | What to look for |
|---|---|---|
| Shell parse | `bash -n <file>` | Syntax errors |
| Shell quality | `shellcheck <file>` | SC2086 word splitting, SC2046, SC2155, SC2206 |
| Shell safety | grep | `$VAR` unquoted where path could contain spaces; `eval`; `rm -rf $VAR` without `-- ` and guard |
| Python parse | `python3 -m py_compile <file>` | Import-time errors |
| Python quality | `ruff check <file>` (if available), else flake8 | Unused imports, complexity |
| Python security | `bandit -q <file>` (if available), else grep | `shell=True`, `eval`, `pickle.load(untrusted)`, `os.system`, `subprocess.Popen(...shell=True)` |
| Dockerfile | `hadolint <file>` (if available), else eye | Unpinned base tags, `apt-get` without cleanup, `COPY . .` bleeding secrets |
| Secrets | `grep -E "(API_KEY|TOKEN|SECRET|PASSWORD|sk-)" <files>` | Hardcoded values; everything must come from `.env` |
| Path safety | grep | `$SCRIPT_DIR` used without quotes inside `docker run`; unsanitized `rm -rf $path` |
| Permission creep | grep | New `--cap-add`, `--privileged`, `-v /:/`, `no-new-privileges:false` |

## Builder-api specific

- Any new endpoint in `server.py`: confirm it's wired into the route table,
  goes through `_maybe_auth`, and either emits CORS (only for `/log`) or
  doesn't.
- Any new `subprocess.Popen(...)`: **must** have `shell=False` and
  `start_new_session=True`. Fail review otherwise.
- Any new config field in `config.py`: check `_build_config` enforces type +
  fail-closed on invalid.

## Workflow

1. List changed files. If user handed you a range, use it; otherwise ask.
2. Run the checks above per category. For each finding, cite
   `file:line` and the fix.
3. Group by severity: Blocker (security/correctness) → Warning (style /
   maintainability) → Nit (optional).

## Report

```
### Review of <file list>

Blockers:  N
Warnings:  M
Nits:      K

[ ] file.py:42 — <description> → <fix>
[ ] ...
```

Don't emit a ✅ summary unless you actually ran the checks — CLAUDE.md
rule: no fake "tests pass" confirmations.
