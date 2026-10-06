# =============================================================================
# slurm-enroot-login: portable HPC login userland for pyxis+enroot clusters
# =============================================================================
# Public image — NO SECRETS, no site config (see SECRETS.md). Everything
# site-specific is injected at runtime via bind mounts / configless Slurm.
#
# Build flow (see .github/workflows/build-push-workflow.yml):
#   1. The workflow stages the Slurm client DEBs from the
#      ualberta-rcg/warewulf-slurmd repo (slurm-debs/, *_u2404) into ./debs/.
#   2. This Dockerfile installs only the client-facing packages
#      (no slurmd/slurmctld/slurmdbd daemons, no dev, no dbgsym).
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

ENV DEBIAN_FRONTEND=noninteractive

# --- Fixed service UIDs (standardized across all Slurm images; SlurmUser
# must resolve inside the container for clients to parse slurm.conf) ---
RUN groupadd -g 999 slurm && useradd -u 999 -g 999 -M -s /usr/sbin/nologin slurm && \
    groupadd -g 972 munge && useradd -u 972 -g 972 -M -s /usr/sbin/nologin munge

# --- Base interactive tooling (no services, no sshd) ---
# CVMFS client from the public CERN repo (24-install-cvmfs parity); the
# site config (default.local, proxies) is runtime-injected, never baked.
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
    zsh  \
    fish  \
    gdb  \
    valgrind  \
    parallel  \
    ripgrep  \
    fd-find  \
    fzf  \
    bat  \
    ncdu  \
    pv  \
    zstd  \
    p7zip-full  \
    lz4  \
    dos2unix  \
    colordiff  \
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
    && rm -rf /var/lib/apt/lists/*

# Ubuntu names these binaries batcat/fdfind; users expect bat/fd
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null; true

# --- Slurm client DEBs (staged by the workflow from warewulf-slurmd) ---
# Keep only client-facing packages: main libs + client tools.
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

# --- AI agent tooling (93-ai-agents parity; public, no secrets) ---
# claude-code system-wide from Anthropic's signed apt repo (93-ai-agents
# uses the same repo). codex/antigravity/opencode come from site-specific
# installers and stay out of the portable base.
# Official signed apt repo (docs: downloads.claude.ai; key fingerprint
# 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE — .asc used directly as signed-by)
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

# --- Entrypoint: job-environment scrub, then login shell ---
# Called explicitly by the gateway dispatcher:
#   srun --container-image=... /usr/local/bin/login-shell
COPY login-shell /usr/local/bin/login-shell
COPY slurm-login-shell /usr/local/bin/slurm-login-shell
RUN chmod 755 /usr/local/bin/login-shell /usr/local/bin/slurm-login-shell

# Entrypoint: land in the login shell. Used via pyxis --container-entrypoint
# (or docker run with no args). Explicit commands still bypass it, so CI
# and debugging are unaffected.
ENTRYPOINT ["/usr/local/bin/login-shell"]
