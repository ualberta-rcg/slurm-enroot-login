# =============================================================================
# slurm-login-pods: portable Alliance HPC login userland for Pyxis + Enroot
# =============================================================================
# Build from the repository root (Slurm client DEBs staged at ./debs):
#   docker build -f images/user/Dockerfile -t slurm-login-pods:latest .
#
# Public image — NO SECRETS, no site config (see SECRETS.md). Everything
# site-specific is injected at runtime via bind mounts / configless Slurm.
# =============================================================================

# --- Pyxis plugin builder: tools live and die here, never in the final image
FROM ubuntu:24.04 AS pyxis-builder
ENV DEBIAN_FRONTEND=noninteractive
COPY debs/ /tmp/debs/
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make libc6-dev git ca-certificates && \
    dpkg -i /tmp/debs/slurm-smd_*_u2404.deb /tmp/debs/slurm-smd-dev_*_u2404.deb 2>/dev/null || \
        apt-get install -f -y && \
    PYXIS_TAG=$(git ls-remote --tags https://github.com/NVIDIA/pyxis 'v*' \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1) && \
    git clone --depth 1 --branch "$PYXIS_TAG" https://github.com/NVIDIA/pyxis /tmp/pyxis && \
    make -C /tmp/pyxis && cp /tmp/pyxis/spank_pyxis.so /spank_pyxis.so

FROM ubuntu:24.04

ARG IMAGE_VERSION=dev
ENV DEBIAN_FRONTEND=noninteractive

# --- Containment sentinel (checked by container-sshd-entrypoint & login-shell
# so a failed Pyxis container start refuses to execute uncontained on a host) ---
RUN printf 'slurm-login-pods %s\n' "${IMAGE_VERSION}" > /etc/slurm-login-pods-release && \
    chmod 644 /etc/slurm-login-pods-release

# --- Fixed service UIDs (SlurmUser must resolve inside the container) ---
RUN groupadd -g 999 slurm && useradd -u 999 -g 999 -M -s /usr/sbin/nologin slurm && \
    groupadd -g 972 munge && useradd -u 972 -g 972 -M -s /usr/sbin/nologin munge

# --- Base interactive tooling + non-root container sshd support ---
RUN echo "deb [trusted=yes] http://cvmrepo.s3.cern.ch/cvmrepo/apt noble-prod main" \
        > /etc/apt/sources.list.d/cernvm.list
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash-completion \
    ca-certificates \
    curl \
    wget \
    git \
    less \
    vim \
    nano \
    tmux \
    screen \
    openssh-client \
    openssh-server \
    xauth \
    rsync \
    tar \
    gzip \
    bzip2 \
    xz-utils \
    zip \
    unzip \
    file \
    strace \
    lsof \
    htop \
    procps \
    bc \
    jq \
    man-db \
    environment-modules \
    openmpi-bin \
    libopenmpi-dev \
    python3 \
    python3-pip \
    make \
    golang \
    libnccl2 \
    libnccl-dev \
    numactl \
    hwloc-nox \
    libmunge2 \
    libnss-sss \
    locales \
    tzdata \
    tree \
    sysstat \
    iotop \
    iftop \
    net-tools \
    gnupg \
    lsb-release \
    zsh \
    fish \
    gdb \
    valgrind \
    parallel \
    ripgrep \
    fd-find \
    fzf \
    bat \
    ncdu \
    pv \
    zstd \
    p7zip-full \
    lz4 \
    dos2unix \
    colordiff \
    pciutils \
    cvmfs \
    neovim \
    emacs-nox \
    byobu \
    btop \
    git-delta \
    tealdeer \
    yq \
    xmlstarlet \
    miller \
    pigz \
    lzop \
    ltrace \
    binutils \
    cmake \
    gfortran \
    build-essential \
    python3-dev \
    pipx \
    lftp \
    aria2 \
    rclone \
    mtr-tiny \
    socat \
    netcat-openbsd \
    git-lfs \
    time \
    sqlite3 \
    hdf5-tools \
    netcdf-bin \
    x11-apps \
    direnv \
    shellcheck \
    tig \
    mc \
    inotify-tools \
    hyperfine \
    entr \
    manpages-dev \
    cowsay \
    fortune-mod \
    lolcat \
    neofetch \
    cvmfs-fuse3 \
    msmtp \
    msmtp-mta \
    openssl \
    gettext \
    pkg-config \
    libdbus-1-dev \
    dnsutils \
    traceroute \
    iputils-ping \
    pdsh \
    python3-venv \
    python3-psutil \
    rdma-core \
    ibverbs-utils \
    rrdtool \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /usr/libexec/openssh \
    && ln -sf /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu names these binaries batcat/fdfind; users expect bat/fd
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null; true

# --- Slurm client DEBs (staged by CI from warewulf-slurmd) ---
COPY debs/ /tmp/debs/
RUN cd /tmp/debs && \
    KEEP=""; \
    for deb in slurm-smd_*_u2404.deb slurm-smd-client_*_u2404.deb slurm-smd-sackd_*_u2404.deb; do \
        case "$deb" in \
            *dbgsym*|*dev*|*slurmd*|*slurmctld*|*slurmdbd*|*slurmrestd*|*sview*|*torque*|*openlava*|*doc*) continue;; \
        esac; \
        KEEP="$KEEP $deb"; \
    done; \
    if [ -z "$KEEP" ]; then echo "ERROR: no client DEBs matched in /tmp/debs"; ls -la /tmp/debs; exit 1; fi; \
    { dpkg -i $KEEP || { apt-get update && apt-get install -f -y; }; } && \
    command -v srun >/dev/null || { echo "ERROR: srun missing after DEB install"; exit 1; }; \
    mkdir -p /etc/bash_completion.d && \
    if [ -f /usr/share/bash-completion/completions/slurm_completion.sh ]; then \
        ln -sf /usr/share/bash-completion/completions/slurm_completion.sh /etc/bash_completion.d/slurm; \
    fi && \
    rm -rf /tmp/debs /var/lib/apt/lists/*

# --- Developer & data-transfer CLIs (uv, gh, globus-cli) + AI coding agent CLIs ---
# Public binaries only — NO API keys, NO site endpoints; self-updaters disabled for RO SquashFS.
ARG UV_VERSION=0.13.10
ARG UV_SHA256=bf65ac1a0af10f92c522d91ac096c7c0a39657647b155577e7836c2cbbb4526c
ARG CODEX_VERSION=0.172.0
ARG CODEX_SHA256=a2342a8f7f68f088be30620ccfe9cb84162c93a6b56177855961cda3ed6be392
ARG OPENCODE_VERSION=2.4.1
ARG OPENCODE_SHA256=9ddd18e3faf64eaeccf6a0fcbc96a5c7a14520ae5fd5b61e5be51d894f478b47
ARG GEMINI_CLI_VERSION=0.71.1
ARG PI_CODING_AGENT_VERSION=0.73.1

ENV DISABLE_AUTOUPDATER=1 \
    AGY_CLI_DISABLE_AUTO_UPDATE=true

RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends nodejs claude-code gh && \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
        -o /tmp/uv.tar.gz && \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/uv.tar.gz -C /tmp && \
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv && \
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx && \
    rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install globus-cli && \
    chmod -R a+rX /opt/pipx && \
    npm install -g --no-audit --no-fund \
        "@google/gemini-cli@${GEMINI_CLI_VERSION}" \
        "@mariozechner/pi-coding-agent@${PI_CODING_AGENT_VERSION}" && \
    npm cache clean --force && \
    curl -fsSL "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-x86_64-unknown-linux-musl.tar.gz" \
        -o /tmp/codex.tar.gz && \
    echo "${CODEX_SHA256}  /tmp/codex.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/codex.tar.gz -C /usr/local/bin && \
    chmod 0755 /usr/local/bin/codex-x86_64-unknown-linux-musl && \
    ln -sf /usr/local/bin/codex-x86_64-unknown-linux-musl /usr/local/bin/codex && \
    curl -fsSL "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" \
        -o /tmp/opencode.tar.gz && \
    echo "${OPENCODE_SHA256}  /tmp/opencode.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/opencode.tar.gz -C /usr/local/bin opencode && \
    chmod 0755 /usr/local/bin/opencode && \
    mkdir -p /opt/antigravity/bin && \
    curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/agy-install.sh && \
    HOME=/opt/antigravity /bin/bash /tmp/agy-install.sh -d /opt/antigravity/bin && \
    chmod -R a+rX /opt/antigravity && \
    ln -sf /opt/antigravity/bin/agy /usr/local/bin/agy && \
    mkdir -p /opt/cursor-agent && \
    curl -fsSL https://cursor.com/install -o /tmp/cursor-install.sh && \
    HOME=/opt/cursor-agent NO_COLOR=1 /bin/bash /tmp/cursor-install.sh && \
    chmod -R a+rX /opt/cursor-agent && \
    ln -sf /opt/cursor-agent/.local/bin/cursor-agent /usr/local/bin/cursor-agent && \
    rm -rf /tmp/codex.tar.gz /tmp/opencode.tar.gz /tmp/agy-install.sh /tmp/cursor-install.sh \
        /root/.npm /var/lib/apt/lists/*

# --- Pyxis SPANK plugin: lets the container's own srun launch container jobs ---
COPY --from=pyxis-builder /spank_pyxis.so /usr/lib/x86_64-linux-gnu/slurm/spank_pyxis.so
RUN mkdir -p /etc/slurm/plugstack.d && \
    echo "optional /usr/lib/x86_64-linux-gnu/slurm/spank_pyxis.so" \
        > /etc/slurm/plugstack.d/pyxis.conf && \
    echo "include /etc/slurm/plugstack.d/*" > /etc/slurm/plugstack.conf

# --- Login pod entrypoints & Alliance user utilities ---
COPY images/user/login-shell /usr/local/bin/login-shell
COPY images/user/slurm-login-shell /usr/local/bin/slurm-login-shell
COPY images/user/container-sshd-entrypoint /usr/local/bin/container-sshd-entrypoint
COPY images/user/bin/ /usr/local/bin/
COPY images/user/profile.d/50-alliance-env.sh /etc/profile.d/50-alliance-env.sh
COPY images/user/profile.d/zz-cvmfs.sh /etc/profile.d/zz-cvmfs.sh
RUN chmod 755 /usr/local/bin/login-shell /usr/local/bin/slurm-login-shell \
        /usr/local/bin/container-sshd-entrypoint \
        /usr/local/bin/login-pod /usr/local/bin/sq \
        /usr/local/bin/seff /usr/local/bin/diskusage_report && \
    chmod 644 /etc/profile.d/50-alliance-env.sh /etc/profile.d/zz-cvmfs.sh

# --- Generic pod-aware cluster-status banner ---
COPY status/bin/cluster-status /usr/local/bin/cluster-status
COPY status/sbin/cluster-status-bake /usr/local/sbin/cluster-status-bake
COPY status/sbin/cluster-status-announce /usr/local/sbin/cluster-status-announce
COPY status/etc/cluster-status/motd.conf.example /etc/cluster-status/motd.conf
COPY status/etc/cluster-status/announce.txt /etc/cluster-status/announce.txt
COPY status/etc/profile.d/zz-cluster-status.sh /etc/profile.d/zz-cluster-status.sh
RUN mkdir -p /etc/cluster-status/bin /etc/cluster-status/announce.d && \
    chmod 755 /usr/local/bin/cluster-status /usr/local/sbin/cluster-status-bake \
        /usr/local/sbin/cluster-status-announce && \
    chmod 644 /etc/cluster-status/motd.conf /etc/cluster-status/announce.txt \
        /etc/profile.d/zz-cluster-status.sh

# --- AI agent guardrails & Alliance skills (disabled automatically in robot pods) ---
COPY agent-guardrails/bin/agent-guardrails /usr/local/bin/agent-guardrails
COPY agent-guardrails/etc/ /tmp/agent-guardrails-etc/
COPY agent-guardrails/skills/ /usr/share/agent-guardrails/skills/
COPY agent-guardrails/community-skills/ /usr/share/agent-guardrails/community-skills/
RUN rm -rf /tmp/agent-guardrails-etc/claude-code/.claude/skills \
        /tmp/agent-guardrails-etc/agents/skills \
        /tmp/agent-guardrails-etc/codex/skills && \
    cp -a /tmp/agent-guardrails-etc/. /etc/ && \
    rm -rf /tmp/agent-guardrails-etc && \
    mkdir -p /etc/claude-code/.claude && \
    cp -a /usr/share/agent-guardrails/skills /etc/claude-code/.claude/skills && \
    ln -sf ../claude-code/.claude/skills /etc/agents/skills && \
    ln -sf ../agents/skills /etc/codex/skills && \
    chmod -R a+rX /etc/claude-code /etc/agents /etc/codex /etc/opencode \
        /etc/gemini-cli /etc/pi /etc/cursor /usr/share/agent-guardrails && \
    chmod 755 /usr/local/bin/agent-guardrails /etc/claude-code/update-motd.sh && \
    chmod 644 /etc/profile.d/ai-agent-skills.sh

# Pin /usr/bin/lesspipe in /etc/skel/.bashrc so CVMFS Gentoo lesspipe never shadows it
RUN sed -i 's|eval "$(SHELL=/bin/sh lesspipe)"|eval "$(SHELL=/bin/sh /usr/bin/lesspipe)"|' /etc/skel/.bashrc

ENTRYPOINT ["/usr/local/bin/login-shell"]
