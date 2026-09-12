# CLAUDE.md

This project (primary) `CLAUDE.md` / `AGENTS.md` (symlink) file is used in pair with global `~/.claude/CLAUDE.md` file for ClaudeCode OR `~/.config/opencode/AGENTS.md` for OpenCode.

This file provides guidance to Claude Code / OpenCode when working with user & code in this repository using `agentic development`, `feedback loops`, `autonomy (YALO skill)`, `orchestrator agents`, `MCP Tools`, `LLM-Docker Builder API`.

---

## BOOT

For each new session or after context compaction please do **STEP 1, 2, 3, 4, 5** with **NO EXCEPTIONS**:

**STEP 1**: read this file from top to bottom

**STEP 2**: read `README.md` file and understand the project scope

**STEP 3**: now you can do "your" usual boot process

**STEP 4**: read `docs/LLM-DOCKER.md`

**STEP 5**: Report back with:

NOTE: `**text**` means bold text above

```
Agento loaded 🔫! 

I promise not to forget your rules Master! I will dial my `PERFORMANCE` setting to super AI level because you are an exceptional power-user and pay 200/month.

{% if issues booting or permission issues %}
**WARNING**: boot issue: <deny param, issue description, file location>
{% else %}
I know kung-fu, ready to roll!
{% endif %}

{% if STARTED NOT AS NEW SESSION or JUST COMPACTED %}
**LAST MISSION**: <What we were doing in general: Example: Tweaking main page UI>
**LAST TASK**: <What task we were doing as last task. Example: adjusting title label height>
{% endif %}
```

---

## Table of Contents

- [Project Holy Rules](#project-holy-rules)
- [Coding Rules](#coding-rules)
- [Coding Conventions](#coding-conventions)
- [Styling Rules](#styling-rules)
- [GIT Rules](#git-rules)
- [Secrets](#secrets)
- [Lessons Learned](#lessons-learned)
- [Debugging rules](#debugging-rules)
- [Key Scripts & Files](#key-scripts--files)
- [References](#references)

---

## Project Holy Rules

HOLY RULE = **ABSOLUTELY NO EXCEPTIONS BREAKING THE RULE** 

- The llm-docker repo (`/root/Projects/llm-docker/**`) is denied via `.claude/settings.local.json`. Do not read or modify it.
- `.builder-api.toml` and any `builder_plugin.py` MUST NOT be edited without explicit user approval — both are host-execution attack surface.
- The Builder API job whitelist + placeholder regexes are the boundary between this container and the host Mac. Never broaden silently.
- `scripts/mcp/logs-server/index.js` and `scripts/mcp/ops-server/index.js` must not gain new write/shell-exec/path capability without user approval.

---

## Coding Rules

- **No auto daemon restart in examples**: NEVER chain `&& cld -c -a` / `&& cld -a` / `&& ocd -a` / any other daemon-spawn or kill onto an install or edit command. The clip-wrapped batch ends after the install step. If the change needs a restart to take effect, mention it in prose BEFORE or AFTER the code block, never inside it. Yaro restarts on his own timing across multiple terminals — silently restarting at the end of a `cp` clobbers state he chose to keep. Applies to every entry point: cld, ocd, run-local.sh, builder-api panel spawn, anything that kicks a long-running process.

- **Security-onion rule**: keep imperfect safety layers if they cost nothing — don't nag about theoretical bypasses. See `feedback_security_onion_layers` memory for the full rule.

---

## Coding Conventions

---

## Styling Rules

Use the `ywizz` style pls with my usual purple colors, wizard style tree on left side, nice multi-select option menus, textfields, etc. 

---

## GIT Rules

Read global GIT rules. Stop fucking around with my GIT repo. You are READ only with GIT unless told otherwise.

---

## Secrets

🔐 Follow the global secrets rule (env-gorilla → vault + Infisical, one ready-to-run command, never hand-edit `.env`). Project = `llm-docker`: vault `ENV/llm-docker`. So `env-gorilla set llm-docker KEY=VALUE --push`, run the app via `env-gorilla llm-docker -- <cmd>`.

---

## Lessons Learned

- **LESSON 1:** we can wipe the host ~/Projects directory from Docker if we are not careful. Like mirroring the whole Projects folder then calling 'rm' inside Docker whiich wipes if from MacOS host system too.

- **LESSON 2:** NEVER launch the opencode TUI with `&` + `wait` in the entrypoint (the claude `& + wait` signal shape does NOT translate). A backgrounded opencode loses raw-mode TTY ownership → arrow keys / mouse events leak as literal escape garbage in iTerm2 (junk while scrolling, `%%` at the prompt). opencode runs FOREGROUND; single Ctrl+C still exits fine because SIGINT hits the TUI directly and the deferred bash trap runs cleanup after it quits. Corollary: exit-path worker stops need short grace + `disown` (litestream ignores SIGTERM — 5s grace = 5s exit hang + `Killed` job spam).

---

## Debugging rules


---

## Key Scripts & Files

---

## References

Full documentation: `docs/LLM-DOCKER.md`
