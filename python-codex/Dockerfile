FROM ghcr.io/astral-sh/uv:latest AS uv

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG CODEX_UID=1000
ARG CODEX_GID=1000

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm \
        openssh-client \
        socat \
        tmux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

RUN npm install -g @openai/codex \
    && npm cache clean --force

RUN if ! getent group "${CODEX_GID}" >/dev/null; then groupadd --gid "${CODEX_GID}" codexgrp; fi \
    && useradd -m -s /bin/bash --uid "${CODEX_UID}" --gid "${CODEX_GID}" codex \
    && mkdir -p /workspace /home/codex/.codex /home/codex/.cache/uv \
    && chown -R codex:"${CODEX_GID}" /workspace /home/codex

LABEL org.openai.codex.uid="${CODEX_UID}" \
      org.openai.codex.gid="${CODEX_GID}"

ENV HOME=/home/codex \
    CODEX_HOME=/home/codex/.codex \
    UV_CACHE_DIR=/home/codex/.cache/uv

WORKDIR /workspace
USER codex

ENTRYPOINT ["codex"]
CMD ["--help"]
