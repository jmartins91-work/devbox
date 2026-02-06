#!/usr/bin/env bash
set -Eeuo pipefail

log()  { echo "[devbox] $*"; }
warn() { echo "[devbox] WARNING: $*" >&2; }
die()  { echo "[devbox] ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE=""
TMP_ENV=""

cleanup() {
  [[ -n "${TMP_ENV:-}" && -f "$TMP_ENV" ]] && rm -f "$TMP_ENV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

detect_compose_file() {
  if [[ -f "${SCRIPT_DIR}/compose.yaml" ]]; then
    echo "${SCRIPT_DIR}/compose.yaml"
  elif [[ -f "${SCRIPT_DIR}/compose.yml" ]]; then
    echo "${SCRIPT_DIR}/compose.yml"
  else
    return 1
  fi
}

detect_tz() {
  if [[ -f /etc/timezone ]]; then
    local tz
    tz="$(tr -d " \t\r\n" < /etc/timezone || true)"
    [[ -n "$tz" ]] && { echo "$tz"; return; }
  fi
  echo "Etc/UTC"
}

resolve_workdir() {
  local maybe="${1:-}"
  if [[ -z "$maybe" ]]; then
    echo "$(pwd)"
    return
  fi
  if [[ "$maybe" = /* ]]; then
    echo "$maybe"
  else
    echo "$(cd "$maybe" && pwd)"
  fi
}

preflight() {
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "'docker compose' not available. Install Docker Compose v2."
  COMPOSE_FILE="$(detect_compose_file)" || die "No compose.yaml/compose.yml found next to: ${SCRIPT_DIR}"
}

make_tmp_env() {
  local workdir="$1"
  local uid gid tz
  uid="$(id -u)"
  gid="$(id -g)"
  tz="$(detect_tz)"

  TMP_ENV="$(mktemp /tmp/devbox.env.XXXXXX)"
  cat > "$TMP_ENV" <<EOF
UID=${uid}
GID=${gid}
TZ=${tz}
DEVBOX_WORKDIR=${workdir}
EOF

  log "Env: UID=$uid GID=$gid TZ=$tz WORKDIR=$workdir (envfile=$TMP_ENV)"
}

dc() {
  docker compose \
    --env-file "$TMP_ENV" \
    -f "$COMPOSE_FILE" \
    --project-directory "$SCRIPT_DIR" \
    "$@"
}

image_exists() {
  docker image inspect dev_container:latest >/dev/null 2>&1
}

exec_shell_as_dev() {
  exec docker exec -it \
    -u dev \
    -e HOME=/home/dev \
    -e USER=dev \
    -e SHELL=/bin/zsh \
    devbox zsh -l
}

container_exists() { docker container inspect devbox >/dev/null 2>&1; }
container_state()  { docker container inspect -f '{{.State.Status}}' devbox 2>/dev/null || true; }
container_health() { docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' devbox 2>/dev/null || true; }

status_check() {
  if ! container_exists; then
    warn "Container 'devbox' does not exist yet."
    return 0
  fi
  local st health img started
  st="$(container_state)"
  health="$(container_health)"
  img="$(docker container inspect -f '{{.Image}}' devbox 2>/dev/null || true)"
  started="$(docker container inspect -f '{{.State.StartedAt}}' devbox 2>/dev/null || true)"
  log "Status: state=${st:-unknown} health=${health:-none} image=${img:-unknown} started=${started:-unknown}"
}

usage() {
  cat <<'EOF'
Usage:
  ./start_devbox.sh <command> [workdir]

Commands:
  up                Build + start devbox (always does --build)
  work              Start devbox for workdir and enter shell (build only if image missing)
  shell             Enter devbox shell as dev user
  status            Print container state + health
  validate          Run validate-dev inside the container
  down              Stop devbox (keeps named volume)
  rebuild           Build --pull + recreate
  rebuild-nocache   Build --no-cache --pull + recreate

Examples:
  ./start_devbox.sh work /tmp/unici
  ./start_devbox.sh up ~/repo/project
  ./start_devbox.sh shell
EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  [[ -n "$cmd" ]] || { usage; exit 1; }

  preflight

  local workdir
  workdir="$(resolve_workdir "${1:-}")"
  mkdir -p "$workdir"

  make_tmp_env "$workdir"

  case "$cmd" in
    up)
      log "Starting devbox (build+up); mounting: $workdir -> /work"
      dc up -d --build
      ;;
    work)
      log "Starting devbox + entering shell; mounting: $workdir -> /work"
      if image_exists; then
        dc up -d
      else
        warn "Image dev_container:latest missing; building..."
        dc up -d --build
      fi
      exec_shell_as_dev
      ;;
    shell)
      exec_shell_as_dev
      ;;
    status)
      status_check
      ;;
    validate)
      exec docker exec -it devbox validate-dev
      ;;
    down)
      dc down
      ;;
    rebuild)
      status_check
      dc build --pull
      dc up -d --force-recreate
      ;;
    rebuild-nocache)
      status_check
      dc build --no-cache --pull
      dc up -d --force-recreate
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "Unknown command: $cmd (try --help)"
      ;;
  esac
}

main "$@"
``