# Claude Code Hacks (2026)

Undocumented + power-user features relevant to this repo. Sources are linked
inline — many of these come from leaked-binary analysis or blog writeups, so
**treat them as mortal**: Anthropic can rename/remove without warning.
Refresh this page periodically.

Organized by "what would you actually want to do in an llm-docker container".

---

## 1. Skip permission prompts (the original hack)

Claude Code ships **two** escape hatches for sitting-in-front-of-the-terminal
friction.

### `--dangerously-skip-permissions`

```sh
claude --dangerously-skip-permissions
```

Turns off **every** permission confirmation. No `allow`/`deny` evaluation, no
"Do you want to run this command?" prompts. Dangerous anywhere a runaway
`rm -rf` can reach real data. Known blow-up: `rm -rf tests/ ~/` expanded
`~/` to the user's home and wiped the Keychain ([TrueFoundry writeup][df1]).

**Safe in this repo** because the container is the blast radius — not your
Mac. Use this inside `cld` when you want maximum autonomy on a throw-away
container:

```sh
# inside the container (cld) or via an env forwarded from the host:
claude --dangerously-skip-permissions "fix all the failing tests"
```

Because `WORKSPACE_DIR` defaults to off (per-invocation mount of CWD only),
the only host files in scope are the one folder you `cd` into. Still scary
if that folder is important — combine with `git status` sanity checks.

### `auto-mode` — the safer alternative

Anthropic's recommended middle ground. Uses a prompt-injection probe +
transcript classifier to decide whether a call is safe, avoiding manual
approvals *and* avoiding YOLO-mode blindness ([Anthropic engineering][auto]).

```sh
claude auto-mode defaults     # see the classifier config
```

See [permission-modes.md](permission-modes.md#eliminate-prompts-with-auto-mode)
for the full opt-in.

---

## 2. Ultraplan — offload planning to the cloud

Officially launched in 2026 ([Anthropic Q1 roundup][q1], [AI Productivity
guide][aip]). Behavior:

- Invoke by either `/ultraplan` as a slash command, or by including the word
  `ultraplan` anywhere in a normal prompt.
- Claude offloads the planning phase to a cloud Opus 4.6 session running
  plan-mode for up to 30 minutes.
- You get the approved plan back in your browser, then execute either in the
  cloud or in your local `cld` session.

Requires a Claude Code Web account (Pro / Max / Team / Enterprise) and a
connected GitHub repo. See [ultraplan.md](ultraplan.md).

**Why it's a hack for this repo**: instead of using up your local turn budget
on exploration, let the cloud plan, then `cld -c` locally and execute. Pairs
well with the `plan` slash command in `.claude/commands/plan.md`.

---

## 3. Agent Teams (a.k.a. "swarms")

The multi-agent feature, officially released as "Agent Teams" in 2026
([techsy.io leaked-features writeup][tc]).

**Enable:**

```sh
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
cld
```

Each agent gets its own **Git Worktree**, so N agents can hack on the same
repo concurrently without stepping on each other. The pre-release opt-OUT
var was `CLAUDE_CODE_AGENT_SWARMS=0` — now superseded.

Relevant reading: [agent-teams.md](agent-teams.md).

**Caution:** pairs badly with `cld 4` (4 slot containers) unless you want to
multiply agent count × slot count. Pick one.

---

## 4. Coordinator mode (undocumented, partial)

Spawns isolated worker agents that communicate through an XML protocol
across `research → spec → implement → verify` phases
([techsy.io leaked-features][tc]).

```sh
export CLAUDE_CODE_COORDINATOR_MODE=1
```

Still "partially built" — use at your own risk. Not the same as Agent Teams.

---

## 5. Headless / remote-control

Run Claude Code like a batch job instead of an interactive REPL
([headless docs][hd], [MindStudio guide][ms]).

```sh
# one-shot, non-interactive:
claude -p "summarize git log" --output-format json

# with tool allowlist (scope to minimum):
claude -p "run the tests" --allowedTools "Bash(pytest*)" --output-format json
```

The `--output-format json` emits a structured stream — pipe it to `jq`,
store it, whatever. This is how you'd script `cld` from CI or from a
builder-api plugin.

**Related flag**: `claude --bg <prompt>` keeps the session alive in a tmux
background (a.k.a. the `DAEMON` feature flag — shipping but hidden per
leaked source).

**Remote Control** (2026): `claude remote-control` starts a server you can
drive from the browser or phone via WebSocket ([Q1 roundup][q1]). Overlaps
with this repo's `builder-api/ws.py` stream — not a replacement, but worth
knowing exists.

---

## 6. Permission lifting inside a live session

Without restarting the CLI you can widen permissions for the rest of the
session using slash commands:

- `/permissions` — opens the editor for `.claude/settings.local.json`
- `/mode plan` / `/mode edit` / `/mode auto` — switch between plan, edit
  (prompt for dangerous), auto (classifier-gated)
- `/bypass on` — temporary per-session bypass (survives only the current
  session; equivalent to launching with `--dangerously-skip-permissions`)

See [permission-modes.md](permission-modes.md).

---

## 7. Hidden env vars worth knowing

Pulled from the leaked-binary analysis of Claude Code 2.1.19
([turboai.dev][tb]). **Not officially documented** — could vanish in any
release.

### Speed / noise controls
| Var | Effect |
|---|---|
| `CLAUDE_CODE_SIMPLE=1` | Disables `CLAUDE.md` loading + attachments. Fastest boot. |
| `CLAUDE_CODE_DISABLE_THINKING=1` | Turns off extended thinking entirely. |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` | Keeps thinking but stops auto-scaling depth. |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` | Disables automatic `MEMORY.md` updates. |
| `CLAUDE_CODE_EFFORT_LEVEL=low` | `low` / `medium` / `high`; default `high`. |
| `MAX_THINKING_TOKENS=N` | Hard cap on thinking tokens. |

### Safety / debugging
| Var | Effect |
|---|---|
| `CLAUDE_CODE_DISABLE_COMMAND_INJECTION_CHECK=1` | **Disables** the command-injection guard. Inverse of safety; useful only when you know what you're doing. |
| `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` | Ignore every `CLAUDE.md` in the tree. |
| `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING=1` | Disables git-based auto-checkpoints. |
| `CLAUDE_CODE_PROFILE_STARTUP=1` / `CLAUDE_CODE_PROFILE_QUERY=1` | Dumps profiling data — useful when the CLI feels slow. |
| `CLAUDE_DEBUG=1` | Verbose debug logs. |

### Agents / planning
| Var | Effect |
|---|---|
| `CLAUDE_CODE_PLAN_MODE_REQUIRED=1` | Force all agents into plan mode first. |
| `CLAUDE_CODE_PLAN_V2_AGENT_COUNT=N` | Parallel agents for plan v2 (1–10). |
| `CLAUDE_CODE_PLAN_V2_EXPLORE_AGENT_COUNT=N` | Parallel explore agents (1–10). |
| `CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-4-5` | Force a cheap/fast model for sub-agents (we already set this in `.env.example`). |
| `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=N` | Parallelism cap for tool calls (default 10). |

### Infra / proxy
| Var | Effect |
|---|---|
| `CLAUDE_CODE_API_BASE_URL` | Route API calls through a proxy. |
| `CLAUDE_CODE_DONT_INHERIT_ENV=1` | Start each shell with empty env — tight leak control. |
| `CLAUDE_CODE_GLOB_HIDDEN=1` | Include dotfiles in glob results. |
| `CLAUDE_CODE_GLOB_NO_IGNORE=1` | Ignore `.gitignore` rules in globs. |
| `CLAUDE_CODE_EXTRA_BODY='{"json":"merged"}'` | Extra JSON merged into every API request. |

Full list (~90 vars) in the [turboai.dev writeup][tb] and the [jedisct1
gist][gist].

---

## 8. Other leaked-but-unshipped flags

From [techsy.io's source-leak analysis][tc] — don't count on these working
today, but they'll probably show up:

- **KAIROS** — `feature('KAIROS')`. Cross-session memory with nightly markdown
  logs + auto-consolidation ("dream"). Internal, May 2026 ETA.
- **BUDDY** — `BUDDY` env. Tamagotchi-style companion, 18 species. Experimental.
- **UDS_INBOX** — Unix-domain-socket IPC between Claude instances on the
  same machine. Would be interesting combined with this repo's multi-slot
  model (each `cld 4` container could chat).
- **BRIDGE_MODE** — `claude remote-control`. Phone / browser UI. Partially
  shipping.
- Utility slash commands: `/ctx-viz` (context-window visualization), `/btw`
  (side questions), `/dream` (manual KAIROS trigger), `/env` (show active
  flags).

---

## 9. Applying these to `llm-docker`

Concrete recipes for this specific repo:

- **Max-autonomy build loop inside the container** — in `cld`, run
  `claude --dangerously-skip-permissions` (safe because the workspace is
  either a single scoped dir or a pre-validated `WORKSPACE_DIR`).
- **Parallel work across 4 Claude slots on the same repo** — export
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `src/.env`, then `cld 4 -c`.
  Each agent gets its own Git Worktree — no conflicts.
- **Cheap agents for scout/review** — set
  `CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-4-5` (already in `.env.example`)
  so sub-agents don't burn Opus tokens.
- **Quiet, fast boot** for repetitive headless runs —
  `CLAUDE_CODE_SIMPLE=1 claude -p "prompt" --output-format json`.
- **Ultraplan a big refactor from the browser**, then `cld -c` locally and
  hand the plan to the `build` slash command in `.claude/commands/build.md`.

---

## Sources

- [turboai.dev — 83 Undocumented Claude Code Environment Variables (v2.1.19)][tb]
- [techsy.io — Everything in Claude Code's Leaked Source][tc]
- [Anthropic — Claude Code auto mode][auto]
- [Claude Code headless docs][hd]
- [MindStudio — Headless Mode guide][ms]
- [MindStudio — Q1 2026 Update Roundup][q1]
- [DevOps.com — Ultraplan bridges planning and execution][devops]
- [AI Productivity — Ultraplan & Plan Mode guide][aip]
- [TrueFoundry — `--dangerously-skip-permissions`: what it does and when not to][df1]
- [Anthropic Claude Code docs][docs]
- [jedisct1 env-var gist][gist]

[tb]: https://www.turboai.dev/blog/undocumented-claude-code-env-vars-2-1-19
[tc]: https://techsy.io/en/blog/claude-code-leaked-features-2026
[auto]: https://www.anthropic.com/engineering/claude-code-auto-mode
[hd]: https://code.claude.com/docs/en/headless
[ms]: https://www.mindstudio.ai/blog/claude-code-headless-mode-autonomous-agents-2
[q1]: https://www.mindstudio.ai/blog/claude-code-q1-2026-update-roundup-2
[devops]: https://devops.com/claude-codes-ultraplan-bridges-the-gap-between-planning-and-execution/
[aip]: https://aiproductivity.ai/guides/claude-code-ultraplan-planning-mode/
[df1]: https://www.truefoundry.com/blog/claude-code-dangerously-skip-permissions
[docs]: https://code.claude.com/docs/en/
[gist]: https://gist.github.com/jedisct1/9627644cda1c3929affe9b1ce8eaf714
