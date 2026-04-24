# Claude Code Desktop + llm-docker over SSH

Anthropic ships a native **Claude Code Desktop** app for macOS that supports three session backends out of the box: `Local`, `Remote` (Anthropic cloud), and **`SSH` — including dev containers**. Your llm-docker container with sshd enabled is a valid SSH backend.

This is the app you were remembering — **not Conductor**. Conductor is Mac-only-local. Claude Code Desktop has native SSH + orchestrates parallel sessions.

Source: https://code.claude.com/docs/en/desktop-quickstart

## What you get

- Native Mac GUI: sidebar with parallel sessions, diff viewer, integrated terminal, file editor, live app preview.
- Every SSH session runs `claude` **inside** your llm-docker container — fully sandboxed (dropped caps, narrow mounts, per-slot SSH port).
- Multiple parallel agents, each its own session, each in its own container if you slot them correctly.
- Shared `~/.claude/*` config between desktop and container via the bind mounts llm-docker already sets up.

## Prerequisites

- llm-docker installed, SSH enabled (`LLM_DOCKER_SSH_ENABLED=true` in `llm-docker.conf`), auth keys set.
- `ssh -p 8884 root@127.0.0.1` works from the Mac (verify with `./src/smoke_test.sh` or manually).
- Claude Code is in the image (baked in by `Dockerfile` line `RUN npm install -g @anthropic-ai/claude-code`).
- Anthropic Pro/Max/Team/Enterprise subscription (required by the desktop app).

## Setup

### 1. Install Claude Code Desktop

Download from Anthropic:
- **Mac (universal)**: https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect

Run the installer, launch from Applications, sign in with your Anthropic account.

### 2. Bring up your llm-docker container

One terminal, once per Conductor-style "workspace":

```bash
cd ~/Projects/my-project
cld --slot 1         # or just `cld` — slot 1 = port 8884
```

Leave it running. `cld` keeps the container alive; the desktop app will ssh into it.

### 3. Add an SSH entry on your Mac

Edit `~/.ssh/config` and add:

```
Host llm-docker-1
    HostName 127.0.0.1
    Port 8884
    User root
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts_llm-docker
```

For more slots, add more host blocks (`llm-docker-2` on 8885, `llm-docker-3` on 8886, etc.).

Test from a terminal: `ssh llm-docker-1 whoami` → should print `root`.

### 4. Connect Claude Code Desktop

1. Open Claude Code Desktop → click the **Code** tab.
2. At the environment selector, choose **SSH**.
3. Enter the host: `llm-docker-1` (the alias you configured) or `root@127.0.0.1:8884`.
4. Pick the project folder: `/root/Projects/my-project` (or wherever your CWD mapped inside the container — `DOCKER_DIR` default is `/root/Projects`).
5. Pick a model (Opus / Sonnet / Haiku).
6. Start prompting.

Claude now runs inside your sandboxed llm-docker container. All file operations happen on the container's filesystem (which is bind-mounted from your Mac's `~/Projects/my-project`), so edits land on your Mac disk but execution is caged.

## Parallel agents (the real killer feature)

Each parallel session can target a different slot:

| Session | SSH host in desktop | Slot | What runs |
|---|---|---|---|
| 1 | `llm-docker-1` | 1 | `cld --slot 1` on 8884 |
| 2 | `llm-docker-2` | 2 | `cld --slot 2` on 8885 |
| 3 | `llm-docker-3` | 3 | `cld --slot 3` on 8886 |

You spin them up once:
```bash
cld --slot 1 &
cld --slot 2 &
cld --slot 3 &
```

…then open three sessions in Claude Code Desktop, one per slot. Each is a separate sandboxed container. They can't see each other's processes.

## How this compares

| | Conductor | Claude Code Desktop (SSH) | VSCode Remote-SSH |
|---|---|---|---|
| Native Mac app | ✅ | ✅ | ❌ (Electron) |
| Built-in diff viewer | ✅ | ✅ | partial (git pane) |
| Parallel agents UI | ✅ | ✅ | via multiple windows |
| **SSH to container** | ❌ | ✅ | ✅ |
| Uses llm-docker's sandbox | ❌ | ✅ | ✅ |
| Runs Claude Code | ✅ local only | ✅ anywhere | manual in terminal |

Your pick: **Claude Code Desktop** is the closest thing to "Conductor but with SSH." It's Anthropic's first-party answer to the sandboxed agent problem.

## Gotchas

1. **Host keys**: the container's sshd uses persistent host keys from `~/.llm-docker/ssh/`, so once you accept the fingerprint you won't get re-prompted across rebuilds. If you ever wipe `~/.llm-docker/ssh/`, clear the corresponding entry in `~/.ssh/known_hosts_llm-docker`.
2. **Slot collisions**: if you open session 2 in the desktop app pointing at `llm-docker-2` but never ran `cld --slot 2`, nothing's listening on 8885 and the connection fails. Bring the container up first, then connect the desktop session.
3. **Auto-bump without `--slot`**: if you run plain `cld` (no slot) and 8884's taken, cld auto-bumps to 8885/8886/... — but your SSH config entry points at a fixed port. Use explicit `--slot N` when you care about matching desktop entries to ports.
4. **Container restarts**: if you `cld --clean` and then relaunch, Claude Code Desktop's SSH session needs to reconnect. The app should retry automatically; if not, close and reopen the session.
5. **Performance**: file I/O through the bind mount is native-speed on Docker Desktop for Mac (virtiofs backend). TUI responsiveness over local SSH is indistinguishable from running Claude on your Mac directly.

## Why this is better than Conductor for your use case

- **Same UI pattern** (parallel sessions sidebar, diff viewer, integrated terminal).
- **Actual sandbox** — your caps-dropped llm-docker container, not bare macOS.
- **First-party**: Anthropic ships it, it's kept up to date with Claude Code CLI features.
- **Your llm-docker setup requires zero changes** — you already have sshd + keys + bind mounts + slot-based ports. The desktop app just consumes them.

## Next

Set it up (takes 5 min). Smoke-test by:
1. `cld --slot 1` in a terminal
2. Claude Code Desktop → Code → SSH → `llm-docker-1` → pick project
3. Ask it `whoami` — should reply `root` (i.e., it's executing inside the container).
4. Ask it to create a file — verify the file shows up in `~/Projects/my-project/` on your Mac (bind mount proves it).
