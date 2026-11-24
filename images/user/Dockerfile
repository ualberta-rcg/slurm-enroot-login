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
    nmap \
    git-lfs \
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
    rm -rf /tmp/debs /var/lib/apt/lists/*

# --- AI agent CLI (Anthropic signed apt repo; public, no API keys) ---
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list && \
    apt-get update && apt-get install -y --no-install-recommends claude-code && \
    rm -rf /var/lib/apt/lists/*

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
COPY status/etc/cluster-status/motd.conf.example /etc/cluster-status/motd.conf
COPY status/etc/cluster-status/announce.txt /etc/cluster-status/announce.txt
COPY status/etc/profile.d/zz-cluster-status.sh /etc/profile.d/zz-cluster-status.sh
RUN chmod 755 /usr/local/bin/cluster-status /usr/local/sbin/cluster-status-bake && \
    chmod 644 /etc/cluster-status/motd.conf /etc/cluster-status/announce.txt \
        /etc/profile.d/zz-cluster-status.sh

# --- AI agent guardrails & Alliance skills (disabled automatically in robot pods) ---
COPY agent-guardrails/etc/ /tmp/agent-guardrails-etc/
COPY agent-guardrails/skills/ /usr/share/agent-guardrails/skills/
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
    chmod 755 /etc/claude-code/update-motd.sh && \
    chmod 644 /etc/profile.d/ai-agent-skills.sh

# Pin /usr/bin/lesspipe in /etc/skel/.bashrc so CVMFS Gentoo lesspipe never shadows it
RUN sed -i 's|eval "$(SHELL=/bin/sh lesspipe)"|eval "$(SHELL=/bin/sh /usr/bin/lesspipe)"|' /etc/skel/.bashrc

ENTRYPOINT ["/usr/local/bin/login-shell"]
