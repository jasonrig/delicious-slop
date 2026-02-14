# Codex in Docker (Ubuntu + uv)

Run OpenAI Codex inside an isolated Ubuntu container with `uv` installed, while mounting only what you need from the host.

## What This Includes

- `Dockerfile`
  - Base image: `ubuntu:24.04`
  - Installs `@openai/codex` globally via `npm`
  - Copies `uv` and `uvx` from `ghcr.io/astral-sh/uv`
  - Uses non-root user `codex`
- `docker-compose.yml`
  - Service: `codex`
  - Mounts host workspace to `/workspace`
  - Mounts auth file to `/home/codex/.codex/auth.json`
- `run-codex.sh`
  - Wrapper script for build-on-demand + run
  - Defaults workspace mount to current shell `PWD`
  - Supports overriding workspace/auth/image via flags

## Prerequisites

- Docker with Compose v2 (`docker compose`)
- Host auth file at `~/.codex/auth.json`

## Quick Start

Run from any directory (that directory will be mounted as workspace):

```bash
/path/to/run-codex.sh
```

Override the mounted workspace:

```bash
/path/to/run-codex.sh --workspace /absolute/path/to/project
```

Pass explicit Codex arguments:

```bash
/path/to/run-codex.sh -- --yolo "analyze repo and propose fixes"
```

## Script Options (`run-codex.sh`)

- `--build`: Force rebuild image before running.
- `--no-build`: Do not build; fail if image is missing.
- `--workspace PATH`: Host directory to mount at `/workspace` (default: current `PWD`).
- `--auth-file PATH`: Host auth file path (default: `~/.codex/auth.json`).
- `--auth-rw`: Mount auth file read-write (default).
- `--auth-ro`: Mount auth file read-only.
- `--image NAME`: Override image name (default: `codex-ubuntu`).

## Running with Docker Compose Directly

You can run without the wrapper by setting env vars:

```bash
CODEX_WORKSPACE="$PWD" \
CODEX_AUTH_FILE="$HOME/.codex/auth.json" \
CODEX_AUTH_MODE=rw \
docker compose -f /path/to/docker-compose.yml run --rm --build codex --yolo
```

## Notes

- Auth mount is `rw` by default so token refresh can be persisted.
- Container `working_dir` is `/workspace`.
- The wrapper script uses Compose file path relative to itself, so it can be called from any directory.

## Troubleshooting

- `auth file not found`: verify `~/.codex/auth.json` exists or pass `--auth-file`.
- Docker permission errors: ensure Docker daemon is running and your user can access it.
