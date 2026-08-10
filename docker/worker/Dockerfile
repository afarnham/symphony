# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22.22-bookworm-slim@sha256:e21fc383b50d5347dc7a9f1cae45b8f4e2f0d39f7ade28e4eef7d2934522b752
FROM ${NODE_IMAGE}

ARG CLAUDE_CODE_VERSION=2.1.226
ARG CODEX_VERSION=0.147.0
ARG PNPM_VERSION=11.21.0
ARG WORKER_UID=10001
ARG WORKER_GID=10001

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        gh \
        git \
        git-lfs \
        jq \
        less \
        openssh-server \
        procps \
        python3 \
        python3-venv \
        ripgrep \
        rsync \
        tini \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "pnpm@${PNPM_VERSION}" \
    && install -d -m 0755 /usr/local/libexec \
    && mv /usr/local/bin/claude /usr/local/libexec/claude-real \
    && mv /usr/local/bin/codex /usr/local/libexec/codex-real \
    && npm cache clean --force \
    && groupadd --gid "${WORKER_GID}" worker \
    && useradd --uid "${WORKER_UID}" --gid worker --create-home --shell /bin/bash worker \
    && install -d -o root -g root -m 0755 /run/sshd \
    && install -d -o worker -g worker -m 0700 \
        /home/worker/.cache \
        /home/worker/.claude \
        /home/worker/.codex \
        /home/worker/.local \
        /home/worker/.ssh \
    && install -d -o worker -g worker -m 0750 /workspaces

ENV GH_CONFIG_DIR=/tmp/symphony-gh \
    HOME=/home/worker \
    NPM_CONFIG_CACHE=/home/worker/.cache/npm \
    PNPM_HOME=/home/worker/.local/share/pnpm \
    XDG_CACHE_HOME=/home/worker/.cache \
    XDG_DATA_HOME=/home/worker/.local/share

COPY --chown=root:root sshd_config /etc/ssh/sshd_config
COPY --chown=root:root gitconfig /etc/gitconfig
COPY --chown=root:root entrypoint.sh /usr/local/bin/symphony-worker-entrypoint
COPY --chown=root:root git-credential.sh /usr/local/bin/symphony-git-credential
COPY --chown=root:root healthcheck.sh /usr/local/bin/symphony-worker-healthcheck
COPY --chown=root:root shell.sh /usr/local/bin/symphony-worker-shell
COPY --chown=root:root claude-launcher.sh /usr/local/bin/claude
COPY --chown=root:root codex-launcher.sh /usr/local/bin/codex

RUN chmod 0755 \
      /usr/local/bin/symphony-worker-entrypoint \
      /usr/local/bin/symphony-git-credential \
      /usr/local/bin/symphony-worker-healthcheck \
      /usr/local/bin/symphony-worker-shell \
      /usr/local/bin/claude \
      /usr/local/bin/codex \
    && usermod --shell /usr/local/bin/symphony-worker-shell worker

USER worker:worker
WORKDIR /workspaces

EXPOSE 2222

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony-worker-entrypoint"]
CMD ["serve"]
