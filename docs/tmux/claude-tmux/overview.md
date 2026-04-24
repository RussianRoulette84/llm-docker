# claude-tmux — overview

**Flag:** `cld -tcl` / `cld --tmux-claude`
**Upstream:** [nielsgroen/claude-tmux](https://github.com/nielsgroen/claude-tmux) — Rust TUI.

A **popup** TUI (ratatui-based) for managing Claude Code sessions across tmux. Triggered with `prefix C-c`, shows every tmux session with a Claude Code status indicator and a live preview of the selected session's output.

## Why use it
- You want a **quick popup** (bring up, act, dismiss) rather than a persistent dashboard
- You want integrated **git worktree** support for parallel branches
- You want **PR creation** hooks via `gh` CLI
- You want filter-as-you-type session switching

## Status indicators
- `●` Working — Claude is actively processing
- `○` Idle — ready for input
- `◐` Waiting — permission prompt or interrupt message
- `?` Unknown — couldn't detect

Detection is pattern-matching on pane content (input prompts, interrupt banners).

## What it is NOT
- Not a fleet dashboard — that's [recon/](../recon/)
- Not a web UI — that's [codeman/](../codeman/)
- Not a multi-pane launcher — that's [team/](../team/)

## Related
- [install.md](./install.md) — baked-in + manual install
- [usage.md](./usage.md) — popup flow, worktrees, PRs
- [keybindings.md](./keybindings.md) — the popup shortcuts
- [troubleshooting.md](./troubleshooting.md) — popup sizing, status mis-detection
