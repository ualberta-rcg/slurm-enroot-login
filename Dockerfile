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

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# --- Base interactive tooling (no services, no sshd) ---
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
    build-essential \
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
    && rm -rf /var/lib/apt/lists/*

# --- Slurm client DEBs (staged by the workflow from warewulf-slurmd) ---
# Keep only client-facing packages: main libs + client tools.
COPY debs/ /tmp/debs/
RUN cd /tmp/debs && \
    KEEP=""; \
    for deb in slurm-smd_*_u2404.deb slurm-smd-client_*_u2404.deb; do \
        case "$deb" in \
            *dbgsym*|*dev*|*slurmd*|*slurmctld*|*slurmdbd*|*slurmrestd*|*sview*|*torque*|*openlava*|*doc*) continue;; \
        esac; \
        KEEP="$KEEP $deb"; \
    done; \
    if [ -z "$KEEP" ]; then echo "ERROR: no client DEBs matched in /tmp/debs"; ls -la /tmp/debs; exit 1; fi; \
    { dpkg -i $KEEP || { apt-get update && apt-get install -f -y; }; } && \
    command -v srun >/dev/null || { echo "ERROR: srun missing after DEB install"; exit 1; }; \
    rm -rf /tmp/debs /var/lib/apt/lists/*

# --- Entrypoint: job-environment scrub, then login shell ---
# Called explicitly by the gateway dispatcher:
#   srun --container-image=... /usr/local/bin/login-shell
COPY login-shell /usr/local/bin/login-shell
RUN chmod 755 /usr/local/bin/login-shell

# No ENTRYPOINT/CMD: pyxis execs commands directly; keeping the image
# ENTRYPOINT-free also keeps `docker run` friendly for CI and debugging.
