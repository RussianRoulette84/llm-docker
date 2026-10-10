FROM node:24

# Essentials — always installed.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    git \
    curl \
    wget \
    gettext-base \
    ncurses-term \
    trash-cli \
    zip \
    unzip \
    telnet \
    tree \
    mtr \
    imagemagick \
    ffmpeg \
    jq \
    sqlite3 \
    gnupg \
    watchman \
    && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh

RUN npm install -g pnpm

# --- Shell toolchain: zsh + oh-my-zsh + p10k + autosuggest + syntax highlight + fzf.
# Packages: micro (EDITOR), bat (fz preview), ripgrep (fz content mode), ncdu (tt alias), fzf.
# locales package + locale-gen so LANG=en_US.UTF-8 in zprofile doesn't warn.
# Debian ships `bat` as `batcat` — symlink for zprofile compatibility.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        zsh \
        locales \
        micro \
        bat \
        ripgrep \
        ncdu \
        fzf \
    && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Oh-my-zsh + powerlevel10k + common zsh plugins. Baked into the image so
# fresh containers are instantly usable (no first-run install prompt).
ENV ZSH=/root/.oh-my-zsh
RUN RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
        "$ZSH/custom/plugins/zsh-autosuggestions" \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
        "$ZSH/custom/plugins/zsh-syntax-highlighting" \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k \
        "$ZSH/custom/themes/powerlevel10k"

# Baseline .zshrc — loads omz + fzf keybindings. Sources ~/.p10k.zsh (baked
# default below) so p10k never fires its "does this look like a diamond?"
# configuration wizard on fresh containers or SSH logins.
RUN printf '%s\n' \
        'export ZSH="$HOME/.oh-my-zsh"' \
        'ZSH_THEME="powerlevel10k/powerlevel10k"' \
        'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' \
        'source $ZSH/oh-my-zsh.sh' \
        '' \
        '# fzf key-bindings (Ctrl-T file, Ctrl-R history, Alt-C cd) + completion' \
        '[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh' \
        '[ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh' \
        '' \
        '# p10k config (host mount at /root/.p10k.zsh wins; falls back to baked default)' \
        '[[ -f "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"' \
        '' \
        > /root/.zshrc

# Bake p10k's shipped "lean" example as the default ~/.p10k.zsh so SSH logins
# and fresh containers get a working prompt without the setup wizard. Users
# who bind-mount their own ~/.p10k.zsh from the host override this.
RUN cp "$ZSH/custom/themes/powerlevel10k/config/p10k-lean.zsh" /root/.p10k.zsh

# Make zsh the login shell for root (SSH logins + EXIT_TO_DOCKER drop).
RUN chsh -s /usr/bin/zsh root
ENV SHELL=/usr/bin/zsh
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# uv installs to /root/.local/bin.
ENV PATH="/root/.local/bin:$PATH"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Python linter/formatter — used by agents directly and by Builder API
# python-pack jobs (`ruff`, `ruff format`). uv tool → isolated env, binary
# shim lands in /root/.local/bin (already on PATH).
RUN uv tool install ruff

# Rust toolchain paths (INSTALL_RUST group in install_devpack.sh). Set
# unconditionally — harmless when the flag is off, and it keeps cargo/rustc
# on PATH for the build itself, the entrypoint, and every shell the agent
# spawns. rustup's own PATH edit is skipped (--no-modify-path) precisely so
# this one line stays the single source of truth.
ENV RUSTUP_HOME=/root/.rustup
ENV CARGO_HOME=/root/.cargo
ENV PATH="/root/.cargo/bin:$PATH"

WORKDIR /root

# Bake build timestamp into image (used to detect image updates at runtime)
RUN date -u +%Y-%m-%dT%H:%M:%SZ > /IMAGE_BUILD_DATE

# Magic sauce. TOOL build-arg controls which CLI(s) get installed:
#   both     → opencode + claude-code (default; install.sh uses this)
#   claude   → only claude-code (cld's default build)
#   opencode → only opencode (ocd's default build)
# NOTE: this MUST run before install_devpack.sh — Codeman's installer scans
# PATH for claude/opencode and re-installs them from scratch if missing.
ARG TOOL=both
COPY llm-docker.conf /tmp/llm-docker.conf
COPY docker/install_cli.sh /tmp/install_cli.sh
RUN chmod +x /tmp/install_cli.sh \
    && set -a && . /tmp/llm-docker.conf && set +a \
    && /tmp/install_cli.sh "$TOOL" \
    && rm /tmp/install_cli.sh

# Optional software groups — toggled via INSTALL_* in llm-docker.conf.
# Must run AFTER the CLI install so Codeman's installer sees the existing
# claude/opencode binaries and skips its own reinstall.
COPY docker/install_devpack.sh /tmp/install_devpack.sh
RUN chmod +x /tmp/install_devpack.sh \
    && set -a && . /tmp/llm-docker.conf && set +a \
    && /tmp/install_devpack.sh \
    && rm -f /tmp/install_devpack.sh /tmp/llm-docker.conf

# Point HyperFrames at the headless-shell binary installed by INSTALL_BROWSING.
# Harmless when the flag is off — env var just points at a non-existent path
# and HyperFrames isn't installed either.
ENV HYPERFRAMES_BROWSER_PATH=/usr/bin/chromium-headless-shell

# Tell Playwright where to find its browser binaries. The path is populated
# by install_devpack.sh's INSTALL_BROWSING block (`npx playwright install
# chromium`). Setting it unconditionally is harmless — Playwright just
# falls back to its own default lookup if the dir is missing.
ENV PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright

# SSH configuration script
COPY docker/setup-ssh.sh /setup-ssh.sh
RUN chmod +x /setup-ssh.sh
EXPOSE 22

# Entro pointo
COPY docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
COPY docker/entrypoint-lib.sh /usr/local/bin/entrypoint-lib.sh
RUN chmod +x /usr/local/bin/entrypoint-lib.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
