# v1.2 (2026-03-03)

- 🐳 **Claude Code support**: New `cld` wrapper for Claude Code CLI in Docker; persistent data in `~/.llm_docker/claude`.
- 📝 **Entrypoint**: `docker-entrypoint.sh` switches between OpenCode and Claude based on `TOOL`.
- ⚙️ **ENV-driven config**: Docker Compose reads `.env` for `WORKSPACE_DIR`, `TOOL`, sandbox settings, etc.
- 📦 **Node 24**: Base image updated from Node 22 to Node 24.
- 📋 **Config**: `opencode.config.jsonc` tweaks; `.env.sample` expanded with Claude Code options.

# v1.1 (2026-02-03)

- 🐳 **Premium Branding**: New badges, logo, and professional README overhaul.
- 🚀 **Better Routing**: Full support for path arguments and flag passthrough.
- 🔓 **Saner Exits**: Immediate container exit on completion or Ctrl+C.
