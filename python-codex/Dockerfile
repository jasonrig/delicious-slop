FROM ghcr.io/astral-sh/uv:latest AS uv

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

RUN npm install -g @openai/codex \
    && npm cache clean --force

RUN useradd -m -s /bin/bash codex \
    && mkdir -p /workspace /home/codex/.codex /home/codex/.cache/uv \
    && chown -R codex:codex /workspace /home/codex

ENV HOME=/home/codex \
    CODEX_HOME=/home/codex/.codex \
    UV_CACHE_DIR=/home/codex/.cache/uv

WORKDIR /workspace
USER codex

ENTRYPOINT ["codex"]
CMD ["--help"]
