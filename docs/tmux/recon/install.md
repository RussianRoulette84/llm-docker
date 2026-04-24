# Recon — install

## Via `cld` (normal path)

Recon is **opt-in** and baked into the image only when `INSTALL_TMUX_RECON=true` in [src/llm-docker.conf:86](../../../src/llm-docker.conf#L86).

Two ways to flip it on:

1. **Via installer** — re-run the installer's tmux step and check the `recon` box.
2. **Auto-flip** — the first time you launch `cld -tr`, the launcher detects that recon isn't baked in, sets `INSTALL_TMUX_RECON=true` in `llm-docker.conf`, and triggers a rebuild. Subsequent `cld -tr` launches are fast.

Either way the image includes `cargo install --path .` of the upstream repo, so the final binary lives at `/usr/local/bin/recon` (or `$HOME/.cargo/bin/recon`) inside the container.

## Manual / host install
If you want recon on the host (outside the container):

```bash
git clone https://github.com/gavraz/recon.git
cd recon
cargo install --path .
```

Requires Rust, tmux, and Claude Code on the host.

## What gets added to tmux.conf
The image bakes in these tmux bindings (from the upstream project):

```tmux
bind-key g run-shell "tmux display-popup -E -w 80% -h 80% recon"
bind-key n run-shell "tmux display-popup -E -w 60% -h 40% recon new"
bind-key r run-shell "tmux display-popup -E -w 60% -h 40% recon resume"
bind-key i run-shell "recon next"
bind-key X run-shell "tmux display-popup -E -w 50% -h 30% recon kill"
```

## Verifying
Inside the container:
```bash
which recon         # /usr/local/bin/recon or ~/.cargo/bin/recon
recon --version
```
