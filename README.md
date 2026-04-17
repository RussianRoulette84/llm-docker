# 🐳 llm-docker

![Version](https://img.shields.io/badge/Version-v2.0-blue?style=for-the-badge)
![OpenCode](https://img.shields.io/badge/OpenCode-Supported-00A86B?style=for-the-badge&logo=openai&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude_Code-Supported-D1913C?style=for-the-badge&logo=anthropic&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Isolated-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Security](https://img.shields.io/badge/Security-Sandboxed-8A2BE2?style=for-the-badge&logo=lock&logoColor=white)
![Shell](https://img.shields.io/badge/Shell-Automated-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Logo](logo.png)

---

## 📘 About

**llm-docker** provides a secure, sandboxed environment for running **OpenCode** and **Claude Code** with complete data isolation and privacy. Run multiple LLM sessions with automatic session restoration — even if you wipe your Docker.

It bind-mounts your `~/Projects` folder into Docker and stores all tool data (sessions, config, API keys) outside the container at `~/.llm_docker/` for persistence across restarts.

Sleep well knowing your LLM runs in a container you built and control:
1. A prompt injection can only reach files in `~/Projects` — not your system. From there on it's your responsibility to store API keys in a keychain or key manager (example: Infisical), and definaltelly NOT in  `.env` or `.profile` or even worse: a global VAR)
2. A hallucinating LLM can't `rm -rf /` your machine — worst case it nukes the container

![Screenshot](screenshot.png)

---

## ✨ Core Features
* ✅ **One command setup** - `./install.sh` handles everything: Docker image, `.env`, PATH linking
* ✅ **Complete isolation** - Separate from native macOS installations (privacy-focused)
* ✅ **Data persistence** - Sessions, API keys, and config saved to `~/.llm_docker/` — survives container rebuilds
* ✅ **Dual tool support** - Run both OpenCode and Claude Code from the same Docker image
* ✅ **Auto-start Docker** - Automatically starts Docker Desktop on macOS, then launches your tool and restores session
* ✅ **Smart directory detection** - `cld ./my-project` starts a sandboxed session in any directory under `~/Projects`
* ✅ **Slot-based multi-session** - Run 4 Claude instances side by side, each with its own persistent session (`cld --slot N`)

### 🔒 Security Features

* ✅ **Restricted file access** - Only `~/Projects` is accessible inside the container
* ✅ **Dropped capabilities** - Minimal(ish) container privileges
* ✅ **No new privileges** - Security hardening enabled. If you need a new tool installed then edit Dockerfile.
* ✅ **Isolated data** - Tool data completely separate from host
* ✅ **Graceful cleanup** - Background watchdog kills containers on terminal close, CMD+Q, or crash

### ⚙️ Configuration Features

* ✅ **Environment variables** - API keys from `.env` file (OPENAI_API_KEY, ZAI_API_KEY, ANTHROPIC_API_KEY)
* ✅ **Config file support** - JSONC format with comments for OpenCode
* ✅ **Model customization** - Configure agents and models per your needs
* ✅ **Custom hostname** - Easy identification (`llm-docker`)

---

## 🚀 Quick Start

> **One command. That's it.**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RussianRoulette84/llm_docker/master/install.sh)
```

> Installs everything: Docker image, `.env`, PATH — then you're ready to go.

That's it. The installer handles everything:
- Creates data directories
- Sets up `.env` from template (add your API keys)
- Builds the Docker image
- Links `cld` and `ocd` to `/usr/local/bin`

Then just run:

*   **Claude Code**: `cld`
*   **OpenCode**: `ocd`

### Options

```bash
cld                    # New session
cld -c                 # Continue last session
cld -c <session-id>    # Resume specific session
cld ./my-project       # Start in a specific directory
cld 4                  # 4 terminals in grid layout (macOS, new sessions)
cld -c 4               # 4 terminals with session restore
cld 8 -c               # 8 terminals across monitors with restore
ocd 4                  # 4 OpenCode terminals
ocd ./my-project -c    # OpenCode with params
```

### Multi-Window Layout (macOS only)

When launching with a window count (`cld 4`, `cld 8`), terminals are automatically arranged:
- **1 monitor**: all windows in a 2-column grid
- **2 monitors**: windows on the right monitor
- **3+ monitors**: windows on all monitors except the middle one (your coding screen)

## 🏗️ Container Architecture

The llm-docker container includes:

* **Base Image**: `node:24` (with Python 3.11+ support)
* **OpenCode CLI**: Globally installed via `npm install -g opencode-ai`
* **Claude Code CLI**: Globally installed via `npm install -g @anthropic-ai/claude-code`
* **Development Tools**: Python, pip, git, curl, wget, vim
* **Security**: Dropped capabilities, no-new-privileges, restricted file access
* **Network**: Host mode for seamless connectivity
* **Volume Mounts**:
  - `~/Projects` → `/root/Projects` (your projects)
  - `~/.llm_docker/opencode` → `/root` (persistent OpenCode data)
  - `~/.llm_docker/claude` → `/root_claude` (persistent Claude Code data, automatically symlinked to `/root` when using docker-compose)
  - `opencode.config.jsonc` → `/tmp/opencode.config.jsonc` (config file, OpenCode only)


## 🚧 Roadmap

* **Custom API deamon**: LLM calls this API for building & running code locally :) DOCKER => API helper on host server => lint/test/build/debug(websocket)/run[agent.queueID]/interact/read_logs => DOCKER
* **ocd/cld --params**: Allow to pass through params from ocd/cld to docker's opencode/claude
* **Server Mode**: Run OpenCode/Claude Code as a server for IDE integration (port 49455)
* **SSH/GIT**: Securely forward your SSH/Git credentials to the container
