# Codex in Docker (Ubuntu + uv)

Run OpenAI Codex inside an isolated Ubuntu container with `uv` installed, while mounting only what you need from the host.

## What This Includes

- `Dockerfile`
  - Base image: `ubuntu:24.04`
  - Installs `@openai/codex` globally via `npm`
  - Installs `openssh-client` for `ssh`, `ssh-agent`, and `ssh-add`
  - Installs `socat` for ssh-agent relay when host socket permissions require root
  - Installs `tmux` for in-container terminal multiplexing
  - Creates `codex` user with host UID/GID passed at build time
  - Copies `uv` and `uvx` from `ghcr.io/astral-sh/uv`
  - Uses non-root user `codex`
- `docker-compose.yml`
  - Service: `codex`
  - Mounts host workspace to `/workspace`
  - Mounts auth file to `/home/codex/.codex/auth.json`
- `run-codex.sh`
  - Wrapper script for build-on-demand + run
  - Launches tmux in the container with a `shell` window and a `codex` window
  - Can forward host `ssh-agent` into the container (recommended)
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

Forward host SSH agent into the container (no private key mount):

```bash
/path/to/run-codex.sh --ssh-agent-forward
```

Override the socket path when auto-detection is wrong (common on non-Docker-Desktop setups):

```bash
/path/to/run-codex.sh --ssh-agent-forward --ssh-agent-sock "$SSH_AUTH_SOCK"
```

## Script Options (`run-codex.sh`)

- `--build`: Force rebuild image before running.
- `--no-build`: Do not build; fail if image is missing.
- `--workspace PATH`: Host directory to mount at `/workspace` (default: current `PWD`).
- `--auth-file PATH`: Host auth file path (default: `~/.codex/auth.json`).
- `--auth-rw`: Mount auth file read-write (default).
- `--auth-ro`: Mount auth file read-only.
- `--ssh-agent-forward`: Forward host SSH agent socket into the container.
- `--ssh-agent-sock PATH`: Host SSH agent socket path override (usually not needed on Docker Desktop).
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
- In tmux, switch between windows with `Ctrl-b n`/`Ctrl-b p` (or `Ctrl-b 0` for shell and `Ctrl-b 1` for codex).
- Prefer `--ssh-agent-forward` when possible so private keys never enter the container filesystem.
- Startup bootstraps `~/.ssh/known_hosts` with `github.com` (best effort) for common git-over-ssh workflows.
- On macOS, auto-detection defaults to `/run/host-services/ssh-auth.sock` and falls back to `$SSH_AUTH_SOCK` for known non-Docker-Desktop contexts (for example `colima`).
- On Docker Desktop’s permission-restricted bridge socket, startup uses a root `socat` relay and then runs tmux/codex as `codex`.
- When `--ssh-agent-forward` is enabled, startup now fails fast if the forwarded socket is invalid or the agent has no identities loaded.
- If you change users or still see agent permission errors, rebuild so UID/GID mapping is refreshed: `./run-codex.sh --build`.

## Troubleshooting

- `auth file not found`: verify `~/.codex/auth.json` exists or pass `--auth-file`.
- Docker permission errors: ensure Docker daemon is running and your user can access it.
- If you run `docker compose ...` directly (without `run-codex.sh`), set `CODEX_AUTH_FILE` explicitly.
