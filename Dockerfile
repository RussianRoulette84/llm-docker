FROM node:24

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    git \
    curl \
    wget \
    vim \
    gettext-base \
    ncurses-term \
    trash-cli \
    zip \
    unzip

# Quake3IDE development tools
RUN apt-get update && apt-get install -y \
    clang \
    clang-format \
    clang-tools \
    make \
    cmake \
    gcc \
    g++ \
    libc6-dev \
    libsdl2-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root/Projects

RUN npm install -g opencode-ai
RUN npm install -g @anthropic-ai/claude-code

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]