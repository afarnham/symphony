# syntax=docker/dockerfile:1.7

# Dedicated Chromium for Symphony LinkedIn lookups, with the scoped bridge in
# the same container so DevTools never leaves it. The worker reaches only the
# bridge's token-authenticated Unix socket, through a shared volume.
ARG NODE_IMAGE=node:22.22-bookworm-slim@sha256:e21fc383b50d5347dc7a9f1cae45b8f4e2f0d39f7ade28e4eef7d2934522b752
FROM ${NODE_IMAGE}

ARG BROWSER_UID=10001
ARG BROWSER_GID=10001

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium \
        fonts-liberation \
        novnc \
        tini \
        websockify \
        x11vnc \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN if getent passwd "${BROWSER_UID}" >/dev/null; then userdel -r "$(getent passwd "${BROWSER_UID}" | cut -d: -f1)"; fi \
    && if getent group "${BROWSER_GID}" >/dev/null; then groupdel "$(getent group "${BROWSER_GID}" | cut -d: -f1)"; fi \
    && groupadd --gid "${BROWSER_GID}" browser \
    && useradd --uid "${BROWSER_UID}" --gid "${BROWSER_GID}" --home-dir /data --no-create-home --shell /usr/sbin/nologin browser \
    && install -d -o browser -g browser -m 0700 /data \
    && install -d -o browser -g browser -m 0711 /run/symphony-linkedin

WORKDIR /opt/linkedin-bridge
COPY linkedin-bridge/package.json linkedin-bridge/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY linkedin-bridge/src ./src
COPY docker/linkedin-browser/entrypoint.sh /usr/local/bin/symphony-linkedin-browser

USER browser:browser
ENV HOME=/data
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony-linkedin-browser"]
