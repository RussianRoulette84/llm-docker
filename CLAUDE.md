# CLAUDE.md

This file provides guidance to Claude Code when working with user and code in this repository using `agentic development`, `feedback loops`, `autonomy` and `orchestrator`.

--

# BOOT

For each new session or after contact compacting please do **STEP 1, 2, 3, 4, 5** with **NO EXCEPTIONS**:

**STEP 1**: read this `CLAUDE.md` file from top to bottom. 

**STEP 2**: read `README.md` file and understand the project scope

**STEP 3**: now you can do your usual boot proces with `memory/MEMORY.md`, etc

**STEP 4**: prepare to use `orchestrator` agent (if any) that routes to specialized sub-agents in parallel BUT don't read the whole thing now: `.claude/PARALLEL_AGENTS.md`

**STEP 5**: Report back with:

NOTE: `**text**` means bold text above

```
Claude Agent loaded 🔫! 

I promise not to forger your rules Master! I will dial my `PERFORMANCE` setting to super AI level becasue you are an exceptional power-user and pay 200/month.

{% if issues booting or permission issues %}
**WARNING**: boot issue: <deny param, issue description, file location>
{% else %}
I know kung-fu, ready to roll!
{% endif %}

{% if STARTED NOT AS NEW SESSION or JUST COMPACTED %}
**LAST MISSION**: <What we were doing in general: Example: Tweaking main page UI>
**LAST TASK**: <What task we were ding as last task. Example: adjusting title label height>
{% endif %}
```

--

## Table of Contents

- [Holy Rule](#holy-rule-absolutely-no-fucking-no-exceptions)
- [Communication Style Rules](#communication-style-rules-no-exceptions)
- [Coding Rules](#coding-rules-no-exceptions)
- [Core Patterns](#core-patterns)
- [Multi Agent Orchestration](#multi-agent-orchestration)
- [Lessons Learned](#lessons-learned)


--


## Holy Rule **ABSOLUTELY NO FUCKING NO EXCEPTIONS**

- never use 'rm'. Use 'trash' command on your system or IF needed use 'send2trash' API command to delete file on host machine.
- **Question mark rule**: IF the message has sentence(s) with `?` THEN you are allowed for text-only response, no tools
- the **Response format rule** is MANDATORY! I can not be anymore clear about this.
- be carefull: never delete/clear contents of the mirrored folder (example: `~/Projects` folder) inside container because that gets written back to host system and can cause a CATASTROPIC DATA LOSS!  Make sure not to mkae the same mistake when coding.
- do not manage docker without my permission. Don't run, start, stop shit.
- do NOT run install.sh

## Communication Style Rules **NO EXCEPTIONS**

- responding to questions, commenting in code => do 33% less then you normally would do
- **Reproting rule**: MANDATORY as last step (even after lint.sh) **NO EXCEPTIONS!!**
    Every response that completes a task MUST end with these 4 lines.
    **THIS IS NOT OPTIONAL. USER RUNS MULTIPLE TERMINALS. THEY CANNOT TELL WHICH AGENT DID WHAT WITHOUT THIS SUMMARY. SKIPPING IT CAUSES REAL CONFUSION AND FRUSTRATION.**
    ```
    **Request:** <user's last request, problem in plain English — not file names or symbols>
    **Done:** <show "lines changed: X" write what was actually implemented, in plain English according to `[2/10] jargon level` >
    **Optimizations:** <write down any optimization hacks that were introduced (caps, throttles, rate limits, performance tuning)>
    **Hacks:** <write down any hacks/fallback that were introduced (caps, throttles, rate limits, performance tuning)>
    **Concerns:** <see **I'm Concerned rules** below>
    **Success:** <task success rate in percentage. All completed with no hacks, no concerns, no optimalizations = 100%>
    **Next steps:** <steps user has to do (if any) besides testing what the llm can't>

    ```

    Bad ending (never do this):
        > Done. q3ide_params.h — added Q3IDE_SHORTPRESS_MS 300. q3ide_view_modes.c — refactored: win_snapshot_t, +q3ide_focus3/-q3ide_focus3...

    Good ending:
        > **You asked:** make O and I use short-press (keep) / long-press (show then restore).
        > **Done:** both keys now detect hold duration — tap keeps the layout, hold restores on release. Threshold 300ms. autoexec.cfg updated.
        > **Optimizations:** Q3IDE_DEFAULT_WINDOW_SIZE 100.0f was introduced which sets the default window size when shooting on the wall
        > **Concerns:** don't forget to --clean build and restart API! Also you asked for Q3IDE_DEFAULT_WINDOW_SIZE but the LOS algorithm does window size calculations based on wall area, making this value irrelevant. Solutions: ...

- **I'm Concerned rules**
    - Write `-` if the implementation is 100% clean: 
        - no hacks
        - no optimalizations were introduced
        - no fallbacks
        - no workarounds
        - no stubbed paths
        - no silent failures
        - no half-done work
        - no imitations of the requested feature!!
    - Otherwise name exactly what was faked, skipped, or worked around — and why. Be direct. Do not bury it.
        - The developer does NOT look at the code and runs multiple claude sessions/terminals. 
        - Don't even post summary of which files were affected. Show the new PARAM name when it's relevant.
- **Brainstorming rule**: IF developer asked a general question THEN try to reply in general and not make assumptions about our use-case. But push back if it effects our use-case.
- **Use Plain English rule**: When explaining a bug or problem, describe it as what the user *experiences*, not what the code does. Bad: "dlclose is a no-op so Swift globals survive shutdown/init cycles". Good: "You crashed while L was active. Quake's dylib never unloads on Mac — so its L-is-ON state is frozen. Next launch, Quake starts possessed."

## Coding Rules **NO EXCEPTIONS**

- **Fallback code == slop code**: user hates fallback code when u try fixing. Don't do it!
- **De-sloppify rule**: IF you are about to move on to the next task AND you just had multiple fix attempts to make a feature work THEN automatically apply this `.claude/commands/yay.md` command to de-sloppify code. **NO EXCEPTIONS!**
- **Linter rule**: always use `./scripts/lint.sh` after doing MID to BIG volume code changes. Fix errors and warnings that are yours. Other agents might be working.
    - Flags: `--cppcheck` (slow static analysis), `--swift` (SwiftLint — only add when you changed `q3ide-metal/`)
    - Via API: `api('POST', '/lint', {'fix': True, 'args': ['--swift']})` to include Swift checks
- **FEEDBACK LOOP**:
    - You (Claude) are proibably running inside Docker container and you can NOT always build/debug inside a container!
    - The developer's Mac paths and the Docker container paths point to the same files:
        - Mac: `/Users/$USER/Projects/foo/` → Docker: `/root/Projects/foo/`

        When the developer gives a path like `/Users/$USER/Projects/foo/path`, look it up as `/root/Projects/foo/path`. Never say "I can't access that path" — just swap the prefix.
    - From Docker you can `LINT -> BUILD(queued) -> RUN (only if needed) -> INTERACT / DEBUG (if needed) / READ LOGS (if needed) -> FIX ANY EXPERIENCED ISSUES -> REPEAT LOOP UNTIL ISSUE RESOLVED`! No user intervention is needed! Don't ask user to press "M" button if you can do it yourself. Use the Remote API + WebSocket bridge when needed (see section below).
- **Revert-first rule**: IF the developer says "revert", "restore from stable", "remove and re-implement", or "start from scratch" THEN do exactly that — copy the stable files over immediately. Do NOT attempt to fix the broken code instead. Do NOT analyze further. Developer knows better. Fixing instead of reverting wastes hours. **NO 
- **No Imitation Implementations**: 
    - IF a user asks for a new feature THEN do not build a shallow imitation that mimics the surface appearance without the real underlying behavior. 
    - IF you have serious concerns about feasibility or approach THEN push back and explain before writing any code. 
- **File size:** max 250 lines, sweet spot 200. Never grow files for a long period of time..


## Multi Agent Orchestration

- If task difficulty is above `0.5` → use orchestrator with multiple q3agents (see `.claude/PARALLEL_CLAUDE.md`)
- Otherwise → run with main agent


## Lessons Learned

- we can wipe host ~/Projects directory from Docker if we arew not carefull


