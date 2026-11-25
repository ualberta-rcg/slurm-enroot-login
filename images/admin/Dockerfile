# =============================================================================
# slurm-login-pods admin root pod: privileged fork of the login userland
# =============================================================================
# Build from the repository root (Slurm client DEBs staged at ./debs):
#   docker build -f images/admin/Dockerfile -t slurm-login-pods:admin .
#
# Same Ubuntu 24.04 userland as images/user/Dockerfile, plus sudo and
# libpam-sss, so an opted-in gateway admin can `sudo -i` inside an isolated
# admin-<user> pod without landing on the gateway host.
#
# Public image — NO SECRETS, no site config (see SECRETS.md).
# =============================================================================

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

# --- Containment sentinel (checked by admin-container-sshd-entrypoint) ---
RUN printf 'slurm-login-pods %s (admin)\n' "${IMAGE_VERSION}" > /etc/slurm-login-pods-release && \
    chmod 644 /etc/slurm-login-pods-release

# --- Fixed service UIDs ---
RUN groupadd -g 999 slurm && useradd -u 999 -g 999 -M -s /usr/sbin/nologin slurm && \
    groupadd -g 972 munge && useradd -u 972 -g 972 -M -s /usr/sbin/nologin munge

# --- Base interactive tooling + sudo/SSSD PAM + sshd ---
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
    sudo \
    util-linux \
    libpam-sss \
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
    clustershell \
    ipmitool \
    freeipmi-tools \
    dmidecode \
    lshw \
    smartmontools \
    nvme-cli \
    ethtool \
    lldpd \
    ldap-utils \
    sssd-tools \
    krb5-user \
    munge \
    tcpdump \
    iperf3 \
    ipcalc \
    whois \
    httpie \
    ngrep \
    conntrack \
    nftables \
    iproute2 \
    nfs-common \
    cifs-utils \
    restic \
    mariadb-client \
    postgresql-client \
    redis-tools \
    glab \
    bpftrace \
    linux-tools-generic \
    atop \
    iotop-c \
    sosreport \
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

RUN ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null; true

# --- Slurm client DEBs ---
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
    PERF_BIN="$(ls /usr/lib/linux-tools-*/perf 2>/dev/null | head -n 1 || true)" && \
    if [ -n "$PERF_BIN" ]; then ln -sf "$PERF_BIN" /usr/local/bin/perf; fi && \
    rm -rf /tmp/debs /var/lib/apt/lists/*

# --- Sysadmin / K8s / Cloud / IaC CLIs + AI coding agent CLIs ---
ARG UV_VERSION=0.13.10
ARG UV_SHA256=bf65ac1a0af10f92c522d91ac096c7c0a39657647b155577e7836c2cbbb4526c
ARG KUBECTL_VERSION=v1.37.2
ARG KUBECTL_SHA256=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
ARG HELM_VERSION=v4.3.2
ARG HELM_SHA256=d1c0278d46beab79582d7e50f5b3dc206944ba8e577cde618513fd07daa53983
ARG K9S_VERSION=v0.51.0
ARG K9S_SHA256=c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7
ARG STERN_VERSION=1.35.0
ARG STERN_SHA256=03729b01a8fcfab25f6ea53389bd38bc37400ff86d90cd2dcda541f248cf843e
ARG S5CMD_VERSION=2.3.0
ARG S5CMD_SHA256=de0fdbfa3aceae55e069ba81a0fc17b2026567637603734a387b2fca06c299b4
ARG OPENTOFU_VERSION=1.13.10
ARG OPENTOFU_SHA256=f606b6117ee03177374806d56d580bde7b512aff69f86d2b9f3148dced4ca375
ARG AWSCLI_VERSION=2.42.3
ARG AWSCLI_SHA256=09a4a71458061ce4e6e8c1ddbeb5d128c219ef7c9906b7b92c3b542944c025c8
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
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl && \
    echo "${KUBECTL_SHA256}  /tmp/kubectl" | sha256sum -c - && \
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm -f /tmp/kubectl && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz && \
    echo "${HELM_SHA256}  /tmp/helm.tgz" | sha256sum -c - && \
    tar -xzf /tmp/helm.tgz -C /tmp && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm && \
    rm -rf /tmp/helm.tgz /tmp/linux-amd64 && \
    curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" -o /tmp/k9s.tgz && \
    echo "${K9S_SHA256}  /tmp/k9s.tgz" | sha256sum -c - && \
    tar -xzf /tmp/k9s.tgz -C /tmp k9s && install -m 0755 /tmp/k9s /usr/local/bin/k9s && rm -f /tmp/k9s.tgz /tmp/k9s && \
    curl -fsSL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_amd64.tar.gz" -o /tmp/stern.tgz && \
    echo "${STERN_SHA256}  /tmp/stern.tgz" | sha256sum -c - && \
    tar -xzf /tmp/stern.tgz -C /tmp stern && install -m 0755 /tmp/stern /usr/local/bin/stern && rm -f /tmp/stern.tgz /tmp/stern && \
    curl -fsSL "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-64bit.tar.gz" -o /tmp/s5cmd.tgz && \
    echo "${S5CMD_SHA256}  /tmp/s5cmd.tgz" | sha256sum -c - && \
    tar -xzf /tmp/s5cmd.tgz -C /tmp s5cmd && install -m 0755 /tmp/s5cmd /usr/local/bin/s5cmd && rm -f /tmp/s5cmd.tgz /tmp/s5cmd && \
    curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_amd64.tar.gz" -o /tmp/tofu.tgz && \
    echo "${OPENTOFU_SHA256}  /tmp/tofu.tgz" | sha256sum -c - && \
    tar -xzf /tmp/tofu.tgz -C /tmp tofu && install -m 0755 /tmp/tofu /usr/local/bin/tofu && rm -f /tmp/tofu.tgz /tmp/tofu && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" -o /tmp/awscliv2.zip && \
    echo "${AWSCLI_SHA256}  /tmp/awscliv2.zip" | sha256sum -c - && \
    unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install -i /opt/aws-cli -b /usr/local/bin && \
    chmod -R a+rX /opt/aws-cli && rm -rf /tmp/awscliv2.zip /tmp/aws && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install globus-cli && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --include-deps ansible-core && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install ansible-lint && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install python-openstackclient && \
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

# --- Pyxis SPANK plugin ---
COPY --from=pyxis-builder /spank_pyxis.so /usr/lib/x86_64-linux-gnu/slurm/spank_pyxis.so
RUN mkdir -p /etc/slurm/plugstack.d && \
    echo "optional /usr/lib/x86_64-linux-gnu/slurm/spank_pyxis.so" \
        > /etc/slurm/plugstack.d/pyxis.conf && \
    echo "include /etc/slurm/plugstack.d/*" > /etc/slurm/plugstack.conf

# --- Entrypoints, sudoers, and Alliance user utilities ---
COPY images/user/login-shell /usr/local/bin/login-shell
COPY images/user/slurm-login-shell /usr/local/bin/slurm-login-shell
COPY images/user/container-sshd-entrypoint /usr/local/bin/container-sshd-entrypoint
COPY images/user/bin/ /usr/local/bin/
COPY images/admin/admin-login-shell /usr/local/bin/admin-login-shell
COPY images/admin/admin-container-sshd-entrypoint /usr/local/bin/admin-container-sshd-entrypoint
COPY images/admin/sudoers.gateway-admins /etc/sudoers.d/gateway-admins
COPY images/user/profile.d/50-alliance-env.sh /etc/profile.d/50-alliance-env.sh
COPY images/user/profile.d/zz-cvmfs.sh /etc/profile.d/zz-cvmfs.sh
RUN chmod 755 /usr/local/bin/login-shell /usr/local/bin/slurm-login-shell \
        /usr/local/bin/container-sshd-entrypoint \
        /usr/local/bin/login-pod /usr/local/bin/sq \
        /usr/local/bin/seff /usr/local/bin/diskusage_report \
        /usr/local/bin/admin-login-shell \
        /usr/local/bin/admin-container-sshd-entrypoint && \
    chmod 644 /etc/profile.d/50-alliance-env.sh /etc/profile.d/zz-cvmfs.sh && \
    chmod 440 /etc/sudoers.d/gateway-admins && \
    visudo -cf /etc/sudoers.d/gateway-admins

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

# --- AI agent skills & informational admin notes (NO deny/ask policy restrictions) ---
COPY agent-guardrails/bin/agent-guardrails /usr/local/bin/agent-guardrails
COPY agent-guardrails/skills/ /usr/share/agent-guardrails/skills/
COPY agent-guardrails/community-skills/ /usr/share/agent-guardrails/community-skills/
COPY agent-guardrails/admin/CLAUDE.md /etc/claude-code/CLAUDE.md
COPY agent-guardrails/admin/CLAUDE.md /etc/agents/AGENTS.md
COPY agent-guardrails/etc/agents/site.md.example /etc/agents/site.md.example
COPY agent-guardrails/admin/codex-config.toml /etc/codex/config.toml
COPY agent-guardrails/admin/opencode.json /etc/opencode/opencode.json
COPY agent-guardrails/admin/gemini-settings.json /etc/gemini-cli/settings.json
COPY agent-guardrails/etc/profile.d/ai-agent-skills.sh /etc/profile.d/ai-agent-skills.sh
RUN mkdir -p /etc/claude-code/.claude && \
    cp -a /usr/share/agent-guardrails/skills /etc/claude-code/.claude/skills && \
    ln -sf ../claude-code/.claude/skills /etc/agents/skills && \
    ln -sf ../agents/skills /etc/codex/skills && \
    rm -rf /etc/claude-code/managed-settings.json /etc/claude-code/update-motd.sh \
        /etc/codex/requirements.toml /etc/gemini-cli/policies \
        /etc/pi/extensions/hpc-guardrails.ts /etc/cursor/cli-config.json && \
    chmod -R a+rX /etc/claude-code /etc/agents /etc/codex /etc/opencode \
        /etc/gemini-cli /usr/share/agent-guardrails && \
    chmod 755 /usr/local/bin/agent-guardrails && \
    chmod 644 /etc/profile.d/ai-agent-skills.sh

RUN sed -i 's|eval "$(SHELL=/bin/sh lesspipe)"|eval "$(SHELL=/bin/sh /usr/bin/lesspipe)"|' /etc/skel/.bashrc

ENTRYPOINT ["/usr/local/bin/admin-login-shell"]
