# syntax=docker/dockerfile:1.7

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.3.3-debian-bookworm-20260803-slim@sha256:7d3e4edfd47da0a4b8e36e1245ee2d1ff11aa0d7be4fb38e66caaf5334ca3176
ARG DEBIAN_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

FROM ${ELIXIR_IMAGE} AS build

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    SYMPHONY_RELEASE_FORMAT=container

WORKDIR /build/elixir

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY elixir/config ./config
COPY elixir/lib ./lib
COPY elixir/priv ./priv

RUN mix release symphony --overwrite

FROM ${DEBIAN_IMAGE} AS runtime

ARG SYMPHONY_UID=10001
ARG SYMPHONY_GID=10001

ENV HOME=/home/symphony \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SYMPHONY_LOGS_ROOT=/var/log/symphony \
    SYMPHONY_PORT=4000 \
    SYMPHONY_SSH_CONFIG=/tmp/symphony-ssh/config \
    SYMPHONY_WORKFLOW_PATH=/etc/symphony/WORKFLOW.md

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libncurses6 \
        libssl3 \
        libstdc++6 \
        openssh-client \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${SYMPHONY_GID}" symphony \
    && useradd --uid "${SYMPHONY_UID}" --gid symphony --create-home --shell /usr/sbin/nologin symphony \
    && install -d -o symphony -g symphony -m 0750 /app /etc/symphony /var/log/symphony

COPY --from=build --chown=symphony:symphony /build/elixir/_build/prod/rel/symphony /app
COPY --chown=root:root docker/orchestrator/entrypoint.sh /usr/local/bin/symphony-entrypoint
COPY --chown=root:root docker/orchestrator/healthcheck.sh /usr/local/bin/symphony-healthcheck
COPY --chown=root:root docker/orchestrator/volume-init.sh /usr/local/bin/symphony-volume-init

RUN chmod 0755 \
      /usr/local/bin/symphony-entrypoint \
      /usr/local/bin/symphony-healthcheck \
      /usr/local/bin/symphony-volume-init

USER symphony:symphony
WORKDIR /app

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony-entrypoint"]
