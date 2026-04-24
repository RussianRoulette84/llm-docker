# claude-tmux — install

## Via `cld` (normal path)

Opt-in, baked into the image only when `INSTALL_TMUX_CLAUDE=true` in [src/llm-docker.conf:88](../../../src/llm-docker.conf#L88).

Two ways to enable:
1. **Installer** — re-run the installer's tmux step and check `claude-tmux`.
2. **Auto-flip** — first `cld -tcl` detects claude-tmux isn't baked in, flips `INSTALL_TMUX_CLAUDE=true`, triggers a rebuild.

Under the hood: `cargo install claude-tmux`.

## tmux.conf binding
The image adds this line to `~/.tmux.conf`:

```tmux
bind-key C-c display-popup -E -w 80 -h 30 "~/.cargo/bin/claude-tmux"
```

Trigger: `prefix C-c` (i.e. `Ctrl+b` then `Ctrl+c`). Width 80, height 30 characters.

## Manual / host install

**Via Cargo:**
```bash
cargo install claude-tmux
```

**From source:**
```bash
git clone https://github.com/nielsgroen/claude-tmux.git
cd claude-tmux
cargo build --release
```

Then add the bind-key line above to your `~/.tmux.conf` and reload (`prefix :` → `source-file ~/.tmux.conf`).

## PR support dependency
The **Pull Request** flow needs `gh` (GitHub CLI). Install separately:
```bash
# macOS
brew install gh
gh auth login

# inside the container — usually preinstalled; if not:
apt-get install -y gh
```

## Verifying
Inside the container:
```bash
which claude-tmux        # ~/.cargo/bin/claude-tmux
claude-tmux --version
```
Then in tmux press `prefix C-c` — the popup should appear.
