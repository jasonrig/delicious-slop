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
MODE="${CODEX_MODE:-interactive}"
PERSISTENT_INTERACTIVE=0
PERSISTENT_CONTAINER_NAME="${CODEX_CONTAINER_NAME:-}"
SSH_AGENT_FORWARD=0
if [[ "${CODEX_SSH_AGENT_FORWARD:-}" == "1" ]]; then
  SSH_AGENT_FORWARD=1
fi
SSH_AGENT_SOCK="${CODEX_SSH_AGENT_SOCK:-}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
SSH_SIDECAR_ACTIVE=0
KEEP_SSH_SIDECAR=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options] [--] [codex args...]

Builds image on demand, then runs codex via Docker Compose in container tmux.
tmux starts with both a shell window and a codex window.
Defaults workspace mount to current directory.

Options:
  --build             Force image rebuild before running
  --no-build          Do not build; fail if image is missing
  --mode MODE         Launch mode: interactive (default) or unattended
  --interactive       Shortcut for --mode interactive
  --unattended        Shortcut for --mode unattended
  --persistent        Keep interactive container running and reattach tmux on rerun
  --container-name N  Container name for --persistent mode (default: derived from workspace)
  --workspace PATH    Host directory mounted to /workspace (default: current PWD)
  --auth-file PATH    Path to host auth.json (default: ~/.codex/auth.json)
  --auth-rw           Mount auth.json read-write (default)
  --auth-ro           Mount auth.json read-only
  --ssh-agent-forward Forward host ssh-agent into container (no key mount)
  --ssh-agent-sock PATH
                      Host ssh-agent socket path (defaults to SSH_AUTH_SOCK)
  --image NAME        Override Docker image name (default: codex-ubuntu)
  -h, --help          Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --mode unattended -- --yolo "apply security patches"
  $(basename "$0") --persistent
  $(basename "$0") --persistent --container-name codex-my-session
  $(basename "$0") --workspace /path/to/repo
  $(basename "$0") --ssh-agent-forward
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
    --mode)
      [[ $# -ge 2 ]] || { echo "error: --mode requires a value (interactive|unattended)" >&2; exit 2; }
      MODE="$2"
      shift 2
      ;;
    --interactive)
      MODE="interactive"
      shift
      ;;
    --unattended)
      MODE="unattended"
      shift
      ;;
    --persistent)
      PERSISTENT_INTERACTIVE=1
      shift
      ;;
    --container-name)
      [[ $# -ge 2 ]] || { echo "error: --container-name requires a value" >&2; exit 2; }
      PERSISTENT_CONTAINER_NAME="$2"
      shift 2
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
    --ssh-agent-forward)
      SSH_AGENT_FORWARD=1
      shift
      ;;
    --ssh-agent-sock)
      [[ $# -ge 2 ]] || { echo "error: --ssh-agent-sock requires a path" >&2; exit 2; }
      SSH_AGENT_SOCK="$2"
      SSH_AGENT_FORWARD=1
      shift 2
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

shell_join() {
  local out="" arg
  for arg in "$@"; do
    printf -v out '%s%q ' "$out" "$arg"
  done
  printf '%s\n' "${out% }"
}

expand_home() {
  local p="$1"
  if [[ "$p" == ~/* ]]; then
    printf '%s\n' "$HOME/${p#~/}"
  else
    printf '%s\n' "$p"
  fi
}

default_persistent_container_name() {
  local workspace_path="$1"
  local base hash
  base="$(basename "$workspace_path")"
  base="${base//[^[:alnum:]_.-]/-}"
  [[ -n "$base" ]] || base="workspace"
  hash="$(printf '%s' "$workspace_path" | cksum | awk '{print $1}')"
  printf 'codex-%s-%s\n' "$base" "$hash"
}

default_ssh_agent_sock() {
  local docker_context=""
  local docker_host="${DOCKER_HOST:-}"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v docker >/dev/null 2>&1; then
      docker_context="$(docker context show 2>/dev/null || true)"
    fi
    if [[ "$docker_context" == colima* || "$docker_context" == rancher-desktop* || "$docker_context" == orbstack* || "$docker_host" == *colima* || "$docker_host" == *orbstack* ]]; then
      if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        printf '%s\n' "$SSH_AUTH_SOCK"
        return 0
      fi
    fi
    printf '%s\n' "/run/host-services/ssh-auth.sock"
    return 0
  fi
  if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    printf '%s\n' "$SSH_AUTH_SOCK"
    return 0
  fi
  return 1
}

is_special_docker_desktop_sock() {
  [[ "$(uname -s)" == "Darwin" && "$1" == "/run/host-services/ssh-auth.sock" ]]
}

WORKSPACE="$(expand_home "$WORKSPACE")"
AUTH_FILE="$(expand_home "$AUTH_FILE")"
if [[ -n "$SSH_AGENT_SOCK" ]]; then
  SSH_AGENT_SOCK="$(expand_home "$SSH_AGENT_SOCK")"
fi

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

case "$MODE" in
  interactive|unattended)
    ;;
  *)
    echo "error: unsupported mode '$MODE' (expected: interactive or unattended)" >&2
    exit 1
    ;;
esac

if (( PERSISTENT_INTERACTIVE )) && [[ "$MODE" != "interactive" ]]; then
  echo "error: --persistent is only supported in interactive mode" >&2
  exit 1
fi

if (( PERSISTENT_INTERACTIVE )) && [[ -z "$PERSISTENT_CONTAINER_NAME" ]]; then
  PERSISTENT_CONTAINER_NAME="$(default_persistent_container_name "$WORKSPACE")"
fi

if [[ -n "$SSH_AGENT_SOCK" ]]; then
  SSH_AGENT_FORWARD=1
fi

if (( SSH_AGENT_FORWARD )) && [[ -z "$SSH_AGENT_SOCK" ]]; then
  if ! SSH_AGENT_SOCK="$(default_ssh_agent_sock)"; then
    echo "error: could not determine SSH agent socket; set SSH_AUTH_SOCK or use --ssh-agent-sock" >&2
    exit 1
  fi
fi

if (( SSH_AGENT_FORWARD )); then
  if ! is_special_docker_desktop_sock "$SSH_AGENT_SOCK"; then
    if [[ ! -S "$SSH_AGENT_SOCK" ]]; then
      echo "error: ssh agent socket not found at '$SSH_AGENT_SOCK'" >&2
      exit 1
    fi
    SSH_AGENT_SOCK="$(cd "$(dirname "$SSH_AGENT_SOCK")" && pwd -P)/$(basename "$SSH_AGENT_SOCK")"
  fi
fi

image_exists() {
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

build_image() {
  echo "Building Docker image '$IMAGE_NAME' via compose (uid:gid ${HOST_UID}:${HOST_GID})..."
  CODEX_IMAGE_NAME="$IMAGE_NAME" \
  CODEX_UID="$HOST_UID" \
  CODEX_GID="$HOST_GID" \
  CODEX_WORKSPACE="$WORKSPACE" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_AUTH_MODE="$AUTH_MODE" \
  docker compose -f "$COMPOSE_FILE" build codex
}

cleanup() {
  if (( SSH_SIDECAR_ACTIVE )) && (( ! KEEP_SSH_SIDECAR )); then
    CODEX_IMAGE_NAME="$IMAGE_NAME" \
    CODEX_UID="$HOST_UID" \
    CODEX_GID="$HOST_GID" \
    HOST_SSH_AUTH_SOCK="$SSH_AGENT_SOCK" \
    CODEX_WORKSPACE="$WORKSPACE" \
    CODEX_AUTH_FILE="$AUTH_FILE" \
    CODEX_AUTH_MODE="$AUTH_MODE" \
      docker compose -f "$COMPOSE_FILE" --profile ssh-agent rm -sf ssh-agent-relay >/dev/null 2>&1 || true
  fi
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
  if [[ "$MODE" == "interactive" ]]; then
    codex_args=(--yolo)
  else
    echo "error: unattended mode requires explicit codex arguments after --" >&2
    exit 1
  fi
fi

tmux_codex_cmd="$(shell_join codex "${codex_args[@]}")"
codex_exec_cmd="$tmux_codex_cmd"
tmux_user_bootstrap="$(cat <<'TMUX_USER_BOOTSTRAP'
set -euo pipefail
session_name="${CODEX_TMUX_SESSION:-codex}"

# Ensure GitHub is a known SSH host before running git-over-ssh workflows.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
known_hosts="$HOME/.ssh/known_hosts"
touch "$known_hosts"
chmod 600 "$known_hosts"
if ! ssh-keygen -F github.com -f "$known_hosts" >/dev/null 2>&1; then
  if ! ssh-keyscan -H github.com >> "$known_hosts" 2>/dev/null; then
    echo "warning: failed to add github.com to known_hosts during bootstrap." >&2
  fi
fi

if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  for _ in $(seq 1 40); do
    [[ -S "$SSH_AUTH_SOCK" ]] && break
    sleep 0.05
  done

  if [[ ! -S "$SSH_AUTH_SOCK" ]]; then
    echo "error: forwarded SSH_AUTH_SOCK is not a socket in container: '$SSH_AUTH_SOCK'" >&2
    exit 1
  fi

  if ssh_add_output="$(ssh-add -l 2>&1)"; then
    :
  else
    ssh_add_status=$?
    if [[ "$ssh_add_output" == *"The agent has no identities."* || "$ssh_add_status" -eq 1 ]]; then
      echo "error: ssh-agent is reachable but has no identities; run 'ssh-add' on host first." >&2
    else
      echo "error: failed to communicate with forwarded ssh-agent (ssh-add exit $ssh_add_status)." >&2
      echo "ssh-add output: $ssh_add_output" >&2
      echo "socket stat: $(ls -ln "$SSH_AUTH_SOCK" 2>/dev/null || echo unavailable)" >&2
      echo "process uid:gid: $(id -u):$(id -g)" >&2
    fi
    echo "hint: if auto-detection picked the wrong socket, pass --ssh-agent-sock PATH." >&2
    exit 1
  fi
fi

if tmux has-session -t "$session_name" 2>/dev/null; then
  exec tmux attach -t "$session_name"
fi

tmux new-session -d -s "$session_name" -n shell
tmux new-window -t "$session_name:" -n codex "$CODEX_TMUX_CMD"
tmux select-window -t "$session_name:1"
exec tmux attach -t "$session_name"
TMUX_USER_BOOTSTRAP
)"
unattended_user_bootstrap="$(cat <<'UNATTENDED_USER_BOOTSTRAP'
set -euo pipefail

# Ensure GitHub is a known SSH host before running git-over-ssh workflows.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
known_hosts="$HOME/.ssh/known_hosts"
touch "$known_hosts"
chmod 600 "$known_hosts"
if ! ssh-keygen -F github.com -f "$known_hosts" >/dev/null 2>&1; then
  if ! ssh-keyscan -H github.com >> "$known_hosts" 2>/dev/null; then
    echo "warning: failed to add github.com to known_hosts during bootstrap." >&2
  fi
fi

if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  for _ in $(seq 1 40); do
    [[ -S "$SSH_AUTH_SOCK" ]] && break
    sleep 0.05
  done

  if [[ ! -S "$SSH_AUTH_SOCK" ]]; then
    echo "error: forwarded SSH_AUTH_SOCK is not a socket in container: '$SSH_AUTH_SOCK'" >&2
    exit 1
  fi

  if ssh_add_output="$(ssh-add -l 2>&1)"; then
    :
  else
    ssh_add_status=$?
    if [[ "$ssh_add_output" == *"The agent has no identities."* || "$ssh_add_status" -eq 1 ]]; then
      echo "error: ssh-agent is reachable but has no identities; run 'ssh-add' on host first." >&2
    else
      echo "error: failed to communicate with forwarded ssh-agent (ssh-add exit $ssh_add_status)." >&2
      echo "ssh-add output: $ssh_add_output" >&2
      echo "socket stat: $(ls -ln "$SSH_AUTH_SOCK" 2>/dev/null || echo unavailable)" >&2
      echo "process uid:gid: $(id -u):$(id -g)" >&2
    fi
    echo "hint: if auto-detection picked the wrong socket, pass --ssh-agent-sock PATH." >&2
    exit 1
  fi
fi

exec bash -lc "$CODEX_EXEC_CMD"
UNATTENDED_USER_BOOTSTRAP
)"
compose_run_args=(run --rm --entrypoint bash)

if (( SSH_AGENT_FORWARD )); then
  echo "Forwarding ssh-agent socket '$SSH_AGENT_SOCK' into container via sidecar..."
  CODEX_IMAGE_NAME="$IMAGE_NAME" \
  CODEX_UID="$HOST_UID" \
  CODEX_GID="$HOST_GID" \
  HOST_SSH_AUTH_SOCK="$SSH_AGENT_SOCK" \
  CODEX_WORKSPACE="$WORKSPACE" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_AUTH_MODE="$AUTH_MODE" \
    docker compose -f "$COMPOSE_FILE" --profile ssh-agent up -d ssh-agent-relay
  SSH_SIDECAR_ACTIVE=1
  if (( PERSISTENT_INTERACTIVE )); then
    KEEP_SSH_SIDECAR=1
  fi
  trap cleanup EXIT
  compose_run_args+=(-e "SSH_AUTH_SOCK=/run/codex-ssh-agent/agent.sock")
fi

if [[ "$MODE" == "interactive" ]]; then
  if (( PERSISTENT_INTERACTIVE )); then
    persistent_exists=0
    if docker container inspect "$PERSISTENT_CONTAINER_NAME" >/dev/null 2>&1; then
      persistent_exists=1
    fi

    if (( ! persistent_exists )); then
      echo "Starting persistent interactive container '$PERSISTENT_CONTAINER_NAME'..."
      persistent_run_args=(run -d --name "$PERSISTENT_CONTAINER_NAME" --entrypoint bash)
      if (( SSH_AGENT_FORWARD )); then
        persistent_run_args+=(-e "SSH_AUTH_SOCK=/run/codex-ssh-agent/agent.sock")
      fi
      persistent_run_args+=(codex -lc "trap : TERM INT; while :; do sleep 3600; done")
      CODEX_IMAGE_NAME="$IMAGE_NAME" \
      CODEX_UID="$HOST_UID" \
      CODEX_GID="$HOST_GID" \
      HOST_SSH_AUTH_SOCK="$SSH_AGENT_SOCK" \
      CODEX_WORKSPACE="$WORKSPACE" \
      CODEX_AUTH_FILE="$AUTH_FILE" \
      CODEX_AUTH_MODE="$AUTH_MODE" \
        docker compose -f "$COMPOSE_FILE" "${persistent_run_args[@]}" >/dev/null
    elif [[ "$(docker container inspect -f '{{.State.Running}}' "$PERSISTENT_CONTAINER_NAME")" != "true" ]]; then
      echo "Starting existing persistent container '$PERSISTENT_CONTAINER_NAME'..."
      docker start "$PERSISTENT_CONTAINER_NAME" >/dev/null
    fi

    echo "Attaching tmux session in persistent container '$PERSISTENT_CONTAINER_NAME'..."
    exec_args=(exec -it)
    if (( SSH_AGENT_FORWARD )); then
      exec_args+=(-e "SSH_AUTH_SOCK=/run/codex-ssh-agent/agent.sock")
    fi
    exec_args+=(-e "CODEX_TMUX_CMD=$tmux_codex_cmd")
    exec_args+=("$PERSISTENT_CONTAINER_NAME" bash -lc "$tmux_user_bootstrap")
    exec docker "${exec_args[@]}"
  fi
  compose_run_args+=(-e "CODEX_TMUX_CMD=$tmux_codex_cmd")
  compose_run_args+=(codex -lc "$tmux_user_bootstrap")
else
  compose_run_args+=(-T)
  compose_run_args+=(-e "CODEX_EXEC_CMD=$codex_exec_cmd")
  compose_run_args+=(codex -lc "$unattended_user_bootstrap")
fi

echo "Running codex via compose using workspace '$WORKSPACE' (mode: $MODE)..."
if (( SSH_SIDECAR_ACTIVE )); then
  CODEX_IMAGE_NAME="$IMAGE_NAME" \
  CODEX_UID="$HOST_UID" \
  CODEX_GID="$HOST_GID" \
  HOST_SSH_AUTH_SOCK="$SSH_AGENT_SOCK" \
  CODEX_WORKSPACE="$WORKSPACE" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_AUTH_MODE="$AUTH_MODE" \
    docker compose -f "$COMPOSE_FILE" --profile ssh-agent "${compose_run_args[@]}"
  exit $?
fi

CODEX_IMAGE_NAME="$IMAGE_NAME" \
  CODEX_UID="$HOST_UID" \
  CODEX_GID="$HOST_GID" \
  CODEX_WORKSPACE="$WORKSPACE" \
  CODEX_AUTH_FILE="$AUTH_FILE" \
  CODEX_AUTH_MODE="$AUTH_MODE" \
  exec docker compose -f "$COMPOSE_FILE" "${compose_run_args[@]}"
