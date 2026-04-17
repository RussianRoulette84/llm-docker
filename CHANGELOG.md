# v2.0 (2026-03-15)

### Setup & Install
- 📦 **One-command installer** (`install.sh`): creates dirs, `.env`, SSH key, builds image, links `cld`/`ocd` to PATH. Works via `curl` pipe.
- 🔌 **SSH**: port 666 with clean `sshd_config` -> for you, API, ClaudeApp, Conductor, etc

### Session Management
- 🔄 **Session restore**: `cld -c 4` opens 4 terminals and restores previous sessions. `cld 4` starts fresh but still saves on exit. Live tracking detects `/new` session changes via `/proc` fd detection.
- 🎰 **Session slot system** (`cld --slot N`): each terminal gets a numbered slot that auto-saves and restores its Claude session ID. Graceful cleanup via background watchdog — kills containers on terminal close, CMD+Q, or crash.

# Extra: Multi-Window layout on macOS
- 🪟 **Pro multi-window layout (macOS)** (`pro_llm.applescript`): `cld 4`, `cld 8 -c` — auto-detects monitors and arranges terminals in 2-column grids. Skips middle monitor on 3+ screen setups.


# v1.2 (2026-03-03)

- 🐳 **Claude Code support**: New `cld` wrapper for Claude Code CLI in Docker; persistent data in `~/.llm_docker/claude`.
- 📝 **Entrypoint**: `docker-entrypoint.sh` switches between OpenCode and Claude based on `TOOL`.
- ⚙️ **ENV-driven config**: Docker Compose reads `.env` for `WORKSPACE_DIR`, `TOOL`, sandbox settings, etc.
- 📦 **Node 24**: Base image updated from Node 22 to Node 24.
- 📋 **Config**: `opencode.config.jsonc` tweaks; `.env.example` expanded with Claude Code options.

# v1.1 (2026-02-03)

- 🐳 **Premium Branding**: New badges, logo, and professional README overhaul.
- 🚀 **Better Routing**: Full support for path arguments and flag passthrough.
- 🔓 **Saner Exits**: Immediate container exit on completion or Ctrl+C.
