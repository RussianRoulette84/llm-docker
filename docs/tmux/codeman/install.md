# Codeman — install

## Via `cld` (normal path)

Opt-in, baked into the image only when `INSTALL_TMUX_CODEMAN=true` in [src/llm-docker.conf:87](../../../src/llm-docker.conf#L87).

Two ways to flip it on:
1. **Installer** — re-run the installer's tmux step and check `codeman`.
2. **Auto-flip** — first `cld -tc` (or `ocd -tc`) detects codeman isn't baked in, flips the config, triggers a rebuild.

Under the hood the image runs the upstream installer:

```bash
curl -fsSL https://raw.githubusercontent.com/Ark0N/Codeman/master/install.sh | bash
```

which clones to `~/.codeman/app`, installs Node.js + tmux if missing, and builds.

## Port exposure
Codeman serves on **:3000**. `cld -tc` wires up the port publish so you can hit `http://localhost:3000` from the host browser.

## Manual / host install
```bash
curl -fsSL https://raw.githubusercontent.com/Ark0N/Codeman/master/install.sh | bash
```

Requires Node.js 18+ and at least one AI coding CLI (Claude Code or OpenCode). Windows users need WSL.

## Daemon mode (optional)
Upstream ships templates for running codeman as a background service:
- **Linux:** systemd user service
- **macOS:** launchd LaunchAgent

The container doesn't enable daemon mode by default — `cld -tc` starts codeman in the foreground. If you want persistence across container restarts, mount `~/.codeman/` as a volume.

## Verifying
Inside the container:
```bash
which codeman           # $HOME/.codeman/app/bin or similar
codeman --version
codeman web             # then open http://localhost:3000 on host
```
