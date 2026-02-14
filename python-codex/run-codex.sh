#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${CODEX_COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.yml}"
IMAGE_NAME="${CODEX_IMAGE_NAME:-codex-ubuntu}"
WORKSPACE="${PWD}"
AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
AUTH_MODE="${CODEX_AUTH_MODE:-rw}"
FORCE_BUILD=0
NO_BUILD=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options] [--] [codex args...]

Builds image on demand, then runs codex via Docker Compose.
Defaults workspace mount to current directory.

Options:
  --build             Force image rebuild before running
  --no-build          Do not build; fail if image is missing
  --workspace PATH    Host directory mounted to /workspace (default: current PWD)
  --auth-file PATH    Path to host auth.json (default: ~/.codex/auth.json)
  --auth-rw           Mount auth.json read-write (default)
  --auth-ro           Mount auth.json read-only
  --image NAME        Override Docker image name (default: codex-ubuntu)
  -h, --help          Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --workspace /path/to/repo
  $(basename "$0") -- --yolo "inspect repository and suggest fixes"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      FORCE_BUILD=1
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --workspace)
      [[ $# -ge 2 ]] || { echo "error: --workspace requires a path" >&2; exit 2; }
      WORKSPACE="$2"
      shift 2
      ;;
    --auth-file)
      [[ $# -ge 2 ]] || { echo "error: --auth-file requires a path" >&2; exit 2; }
      AUTH_FILE="$2"
      shift 2
      ;;
    --auth-rw)
      AUTH_MODE="rw"
      shift
      ;;
    --auth-ro)
      AUTH_MODE="ro"
      shift
      ;;
    --image)
      [[ $# -ge 2 ]] || { echo "error: --image requires a value" >&2; exit 2; }
      IMAGE_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

expand_home() {
  local p="$1"
  if [[ "$p" == ~/* ]]; then
    printf '%s\n' "$HOME/${p#~/}"
  else
    printf '%s\n' "$p"
  fi
}

WORKSPACE="$(expand_home "$WORKSPACE")"
AUTH_FILE="$(expand_home "$AUTH_FILE")"

if [[ ! -d "$WORKSPACE" ]]; then
  echo "error: workspace directory not found at '$WORKSPACE'" >&2
  exit 1
fi
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "error: auth file not found at '$AUTH_FILE'" >&2
  exit 1
fi
AUTH_FILE="$(cd "$(dirname "$AUTH_FILE")" && pwd -P)/$(basename "$AUTH_FILE")"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "error: compose file not found at '$COMPOSE_FILE'" >&2
  exit 1
fi

image_exists() {
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

build_image() {
  echo "Building Docker image '$IMAGE_NAME' via compose..."
  CODEX_IMAGE_NAME="$IMAGE_NAME" \
  CODEX_WORKSPACE="$WORKSPACE" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_AUTH_MODE="$AUTH_MODE" \
  docker compose -f "$COMPOSE_FILE" build codex
}

if (( FORCE_BUILD )); then
  build_image
elif ! image_exists; then
  if (( NO_BUILD )); then
    echo "error: image '$IMAGE_NAME' does not exist and --no-build was provided" >&2
    exit 1
  fi
  build_image
fi

codex_args=("$@")
if [[ ${#codex_args[@]} -eq 0 ]]; then
  codex_args=(--yolo)
fi

echo "Running codex via compose using workspace '$WORKSPACE'..."
CODEX_IMAGE_NAME="$IMAGE_NAME" \
  CODEX_WORKSPACE="$WORKSPACE" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_AUTH_MODE="$AUTH_MODE" \
  exec docker compose -f "$COMPOSE_FILE" run --rm codex "${codex_args[@]}"
