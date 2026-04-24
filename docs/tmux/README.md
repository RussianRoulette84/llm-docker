# docs/tmux

Index of the four tmux modes the `cld` launcher ships with.

| Flag | Mode | Third-party tool | Folder |
|------|------|------------------|--------|
| `-tt`  | Team (multi-pane claude, one container) | — (built into cld)       | [team/](./team/) |
| `-tr`  | Recon dashboard                         | [gavraz/recon]           | [recon/](./recon/) |
| `-tc`  | Codeman web UI on :3000                 | [Ark0N/Codeman]          | [codeman/](./codeman/) |
| `-tcl` | Claude-tmux popup                       | [nielsgroen/claude-tmux] | [claude-tmux/](./claude-tmux/) |

All four are mutually exclusive — pick one per `cld` invocation. Plain `cld -t` gives you a bare tmux session without any of the add-ons.

Each subfolder has five files:
- `overview.md` — what it is, why it exists
- `install.md` (or `layouts.md` for team) — how it gets baked into the image
- `usage.md` — running it via `cld` and manually
- `keybindings.md` — shortcuts
- `troubleshooting.md` — known gotchas

[gavraz/recon]: https://github.com/gavraz/recon
[Ark0N/Codeman]: https://github.com/Ark0N/Codeman
[nielsgroen/claude-tmux]: https://github.com/nielsgroen/claude-tmux
