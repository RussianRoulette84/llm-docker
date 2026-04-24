# Team mode — usage

## Launch

```bash
cld -tt          # default 1+3 (4 panes)
cld -tt 2        # 2 panes side-by-side
cld -tt 3        # 1+2 stacked (3 panes)
cld -tt 4        # 2x2 grid (4 panes)
```

## First-run behavior
- Team mode is always baked into the image — no opt-in required (unlike `-tr` / `-tc` / `-tcl` which need a rebuild on first use).
- All panes start in the same working directory as the container entrypoint.

## Session lifecycle
- Detach: `Ctrl+b d` — container keeps running, re-attach with another `cld -tt`.
- Kill layout: close the tmux session (`Ctrl+b &`, confirm) — panes die with it. The container itself is still there until you exit it.

## Inside a pane
Each pane is a normal claude prompt. They share:
- `/root/Projects/**` mounts
- `~/.claude/` (credentials, settings, project history)
- MCP servers registered in the container

They do **not** share:
- Conversation context — each pane has its own chat
- `/compact` / `/clear` state — per-pane

## Mutually exclusive with
`-t`, `-tr`, `-tc`, `-tcl`. `cld` will error out if you pass two of these. See [src/cld:307](../../../src/cld#L307).

## Resuming
`cld -c -tt` resumes the last conversation in the lead pane; the rest start fresh.
