---
description: Two-part health probe — log files in this project AND MCP servers + LLM-Docker builder-API. Output is two tables.
argument-hint: [optional: "logs" or "mcp" to run only one of the two — default runs both]
allowed-tools: Bash, mcp__llm-docker-logs__list_logs, mcp__llm-docker-ops__list_jobs, mcp__llm-docker-ops__queue, mcp__llm-docker-ops__runtime_status, mcp__llm-docker-ops__builder_api, mcp__filesystem__list_allowed_directories, mcp__git__git_status
---

# CHECK — logs + MCP/builder-API health

Probe what we can see and touch right now. **Output two tables only — no walkthroughs, no per-tool narration.** End with the standard reporting footer.

## Variables

MODE: `$ARGUMENTS` (default: `both`. Accepts: `logs`, `mcp`, `both`)

## Workflow

Run all probes **in parallel** (single tool-call batch). Don't probe sequentially — these are independent reads.

### Part 1 — LOGS (skip if MODE=mcp)

- `mcp__llm-docker-logs__list_logs` — get names, bytes, mtime for every `*.log` in this project's configured log dirs.
- Fallback if the MCP server isn't wired: `Bash` `find ./logs -maxdepth 2 -name "*.log" -printf "%P\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n" 2>/dev/null | head -30`
- Mark "🟢 hot" if mtime is within 60s, blank otherwise.
- Categorise each log heuristically:
  - **runtime** — anything the project's `[runtime].start_command` writes (`*.log` named like the framework/server you're running)
  - **build** — output from build/test/install jobs (`build.log`, `test.log`, `install.log`, `lint.log`)
  - **events** — `events.jsonl` / `events.log` (builder-api's structured feed)
  - **other** — anything that doesn't match
- Do NOT assume specific filenames — read what's actually there.

### Part 2 — MCP + BUILDER-API (skip if MODE=logs)

Probe whatever MCP servers are wired in this session. Each succeeds 🟢 or fails 🔴 with the failure mode noted in `Concerns`.

- `mcp__llm-docker-ops__list_jobs` — confirms the ops MCP is up AND the builder-api is reachable. Count how many jobs resolved for this project.
- `mcp__llm-docker-ops__queue` — current + pending + history + total_history (proves /queue route works).
- `mcp__llm-docker-ops__runtime_status` — runtime PID + uptime (only meaningful if `[runtime].enabled = true`).
- `mcp__llm-docker-ops__builder_api path:"/jobs"` — raw `/jobs` (sanity-checks the daemon response shape).
- `mcp__llm-docker-logs__list_logs` — already covered in Part 1; counts as the logs-MCP probe here too.
- `mcp__filesystem__list_allowed_directories` — confirms filesystem MCP scope.
- `mcp__git__git_status includeUntracked:false` — branch + clean/dirty.
- **Playwright MCP**: don't probe (browser launch is expensive). Just confirm the tool list shows `browser_*` deferred tools. If it doesn't, mark 🔴 in the table.
- **Builder-API direct probe (Bash fallback)**: if the ops MCP isn't wired, hit the daemon directly:
  ```bash
  PORT=$(awk -v p="project.$(basename "$PWD")" '$0~"^\\["p"\\]"{i=1;next} i&&/^\[/{i=0} i&&/^[[:space:]]*port[[:space:]]*=/{gsub(/^[[:space:]]*port[[:space:]]*=[[:space:]]*/,"");gsub(/[^0-9].*$/,"");print;exit}' ~/.llm-docker/builder-api.toml 2>/dev/null)
  PORT=${PORT:-6666}
  curl -sS -m 2 -H "X-Builder-API-Password: ${BUILDER_API_PASSWORD:-}" "http://host.docker.internal:$PORT/jobs" -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n"
  ```

## Output format

### Table 1 — logs (only if MODE != mcp)

| Log | Category | Size | Last write | What it is |
|---|---|---|---|---|
| `<name>` | runtime / build / events / other | `<KB/MB>` | `<Xs/m/h ago>` 🟢 if hot | one-line purpose |

If no logs exist yet, render one row: `(none)`.

### Table 2 — MCP + builder-API (only if MODE != logs)

| Surface | Type | Probe | Result |
|---|---|---|---|
| llm-docker-ops | MCP | `list_jobs` | 🟢 N jobs / 🔴 reason |
| llm-docker-ops | MCP | `queue` | 🟢 d=N pending=M / 🔴 |
| llm-docker-ops | MCP | `runtime_status` | 🟢 pid=X uptime / 🔴 not running |
| llm-docker-logs | MCP | `list_logs` | 🟢 N files / 🔴 |
| playwright | MCP | tool list | 🟢 browser_* deferred / 🔴 missing |
| filesystem | MCP | `list_allowed_directories` | 🟢 scope / 🔴 |
| git | MCP | `git_status` | 🟢 `<branch>` clean/dirty / 🔴 |
| Builder API | LLM-Docker | `GET /jobs` (direct curl) | 🟢 HTTP 200 + ms / 🔴 connection refused / 401 / etc. |

Omit a row if the corresponding MCP server isn't wired in this session — don't fake-fail it.

## Tone reminders

- **Two tables. No prose between probes.** Concerns/gaps go in the reporting footer, not inline.
- If something fails, mark it 🔴 in the table and explain the failure mode in `Concerns` (one line each — no novel).
- Don't run linters / smoke / e2e — this is a passive health probe, not a build.
- Don't hit the browser or take screenshots.
- Don't try to "fix" anything — this is read-only diagnostics.

After the tables, follow up with the standard reporting footer per `CLAUDE.md` (Request / Done / Success / Concerns / Optimizations / Hacks / Next steps).
