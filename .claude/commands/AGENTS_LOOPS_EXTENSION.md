# Autonomous Feedback Loop — llm-docker

Every non-trivial change must be verified before you call it done. This repo
has no test suite, so verification is mostly static checks + live probes of
running processes.

---

## After ANY change to shell scripts (`cld`, `ocd`, `setup.sh`, `ascii.sh`, `install.sh`, `install_devpack.sh`, `docker-entrypoint.sh`)

1. `bash -n <file>` — parse check (catches syntax, unclosed quotes, etc.).
2. If the file is sourced (e.g. `setup.sh`, `ascii.sh`): also run `shellcheck
   <file>` if installed. Fix warnings that matter (SC2086 word splitting,
   SC2046 command substitution, SC2034 unused vars); ignore style-only noise.
3. Trace the change: does it break any caller? `grep -rn "<function_name>"
   src/` catches renames.

## After ANY change to `src/builder-api/*.py`

1. `python3 -m py_compile src/builder-api/<file>.py` — syntax + import check.
2. If a cross-module contract changed (e.g. function signature in `events.py`
   used by `ws.py`): `python3 -c "import sys; sys.path.insert(0,
   'src/builder-api'); import server"` to catch wiring breakage at import.
3. If tests exist under `src/builder-api/tests/`: run them before declaring
   done.
4. For server behavior: if the builder-api is already running as a daemon, it
   won't pick up the change. Either restart (`POST /stop` then relaunch) or
   note that the change needs a daemon restart to take effect.

## After ANY change to `Dockerfile` / `install_devpack.sh`

- Don't rebuild without explicit user permission (see CLAUDE.md rule:
  "do not manage docker without my permission"). Note the change in the
  response and leave the rebuild to the user.

## When logs are available

- Builder-api backgrounded via `--api` on Linux writes to
  `/tmp/builder-api-<pid>.log` — tail it to catch startup errors.
- Build output: `src/<project>/logs/build.log` if a project uses the default
  `build` alias; otherwise whatever path is in `.builder-api.toml`.
- Don't fabricate "logs look clean" — either read them or say you didn't.

## Failure budget

4 attempts on the same error, then stop and ask the user one specific
question. Do not rewrite unrelated code while blocked.
