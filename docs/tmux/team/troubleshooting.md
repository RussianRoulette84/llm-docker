# Team mode — troubleshooting

## "cld: -t / -tt / -tr / -tc / -tcl are mutually exclusive"
You passed two of the mutually-exclusive tmux flags. Drop all but one. See [src/cld:307](../../../src/cld#L307).

## "cld: -tt supports sizes 2, 3, or 4"
You passed a number other than 2/3/4 to `-tt`. Use one of the documented sizes or omit the number for the default 1+3 layout. See [src/cld:143](../../../src/cld#L143).

## Last pane isn't running Haiku
- Check the pane is actually pane N-1 (bottom-right in grid, bottom of stack in 1+3 / 1+2). The "last" designation is positional.
- Verify your Claude account has Haiku access. If Haiku isn't authorized the pane will fail to start claude.
- Inspect `TMUX_TEAM_SIZE` inside the container: `echo $TMUX_TEAM_SIZE` — must be `0`, `2`, `3`, or `4`.

## Orange border missing
Cosmetic only — tmux theme didn't load. Re-source `~/.tmux.conf` inside the container or detach and re-attach.

## All panes show the same chat
They shouldn't — each pane has its own claude process. If they literally share state, you probably attached multiple terminals to the same pane (e.g., two `cld` attach commands hit the same session). Detach one.

## Container runs out of RAM
Each pane = one claude process = real memory. 4 concurrent agents on a 4GB container will thrash. Raise the Docker memory limit or drop to `-tt 2`.

## `/compact` freed nothing
`/compact` is per-pane. Run it in the pane that's heavy, not the lead.
