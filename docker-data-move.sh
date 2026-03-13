#!/usr/bin/env bash
#
# Docker data-root migration helper
# Source: https://github.com/tool-tl/docker-data-move.sh
#
# Features:
# - Detect the current Docker data-root automatically
# - Estimate required free space with safety buffer
# - Scan local disks and recommend the best migration target
# - Let the user pick a suggested path, enter a custom path, or auto-choose
# - Migrate data-root and update /etc/docker/daemon.json safely
#
set -Eeuo pipefail

DOCKER_SERVICE="${DOCKER_SERVICE:-docker}"
CONFIG_FILE="${CONFIG_FILE:-/etc/docker/daemon.json}"
ALLOW_NONEMPTY="${ALLOW_NONEMPTY:-0}"
AUTO_MODE=0
ASSUME_YES=0
NEW_PATH=""

DEFAULT_DOCKER_DIR="/var/lib/docker"
DOCKER_DIR=""
DOCKER_FS_DEVICE=""
DOCKER_FS_MOUNT=""
REQUIRED_BYTES=0
BACKUP_DOCKER_DIR=""
BACKUP_CONFIG_FILE=""

declare -a CANDIDATE_LABELS=()
declare -a CANDIDATE_PATHS=()
declare -a CANDIDATE_AVAILS=()
declare -a CANDIDATE_MOUNTS=()
declare -a CANDIDATE_FS_TYPES=()

die()  { echo -e "\n[ERROR] $*\n" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }

is_interactive_stdin() {
  [[ -t 0 ]]
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./docker-data-move.sh [--auto] [--yes] [--path /new/docker-data-root]

Options:
  --auto           Auto-pick the best detected target path.
  --yes            Skip confirmation prompts.
  --path PATH      Use a specific target path directly.
  -h, --help       Show this help message.

Environment variables:
  ALLOW_NONEMPTY=1 Allow migration into a non-empty target directory.
  DOCKER_SERVICE   Override the Docker service name (default: docker).
  CONFIG_FILE      Override Docker daemon config path.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)
        AUTO_MODE=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --path)
        [[ $# -ge 2 ]] || die "--path requires a value"
        NEW_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$NEW_PATH" ]]; then
          NEW_PATH="$1"
          shift
        else
          die "Unknown argument: $1"
        fi
        ;;
    esac
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Please run this script as root."
}

require_cmds() {
  command -v docker >/dev/null 2>&1 || die "docker command not found."
  command -v df >/dev/null 2>&1 || die "df command not found."
  command -v du >/dev/null 2>&1 || die "du command not found."
  command -v rsync >/dev/null 2>&1 || die "rsync command not found. Please install rsync first."
}

human_bytes() {
  local value="${1:-0}"
  awk -v n="$value" '
    function human(x) {
      split("B KiB MiB GiB TiB PiB", u, " ")
      i=1
      while (x >= 1024 && i < 6) { x /= 1024; i++ }
      return sprintf(i == 1 ? "%.0f %s" : "%.2f %s", x, u[i])
    }
    BEGIN { print human(n) }
  '
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

detect_docker_dir() {
  local detected
  detected="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [[ -n "$detected" && "$detected" != "<no value>" ]]; then
    DOCKER_DIR="$detected"
  else
    DOCKER_DIR="$DEFAULT_DOCKER_DIR"
  fi

  [[ -d "$DOCKER_DIR" ]] || die "Docker data directory does not exist: $DOCKER_DIR"

  DOCKER_FS_DEVICE="$(df -P "$DOCKER_DIR" | awk 'NR==2 {print $1}')"
  DOCKER_FS_MOUNT="$(df -P "$DOCKER_DIR" | awk 'NR==2 {print $6}')"
}

calculate_required_space() {
  local used avail need_by_ratio need_by_buffer buffer

  used="$(du -sb "$DOCKER_DIR" 2>/dev/null | awk '{print $1}')"
  [[ -n "$used" && "$used" -gt 0 ]] || die "Unable to calculate used space for $DOCKER_DIR"

  buffer=$((2 * 1024 * 1024 * 1024))
  need_by_ratio=$(( (used * 115 + 99) / 100 ))
  need_by_buffer=$(( used + buffer ))
  REQUIRED_BYTES=$(( need_by_ratio > need_by_buffer ? need_by_ratio : need_by_buffer ))

  avail="$(df -P -B1 "$DOCKER_DIR" | awk 'NR==2 {print $4}')"

  info "Current Docker data-root: $DOCKER_DIR"
  info "Current Docker filesystem: $DOCKER_FS_DEVICE mounted on $DOCKER_FS_MOUNT"
  info "Current Docker data usage: $(human_bytes "$used")"
  info "Current filesystem free space: $(human_bytes "$avail")"
  info "Recommended minimum free space for migration target: $(human_bytes "$REQUIRED_BYTES")"
}

is_excluded_fs_type() {
  case "$1" in
    tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup|cgroup2|autofs|nsfs|debugfs|tracefs|securityfs|configfs|selinuxfs|ramfs|fusectl|pstore|mqueue|hugetlbfs)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

suggest_target_path() {
  local mount="$1"
  case "$mount" in
    /)
      printf '/data/docker-data'
      ;;
    *)
      printf '%s/docker-data' "$mount"
      ;;
  esac
}

collect_candidates() {
  local line fs_device fs_type avail mount target label
  while read -r line; do
    [[ -n "$line" ]] || continue
    fs_device="$(awk '{print $1}' <<<"$line")"
    fs_type="$(awk '{print $2}' <<<"$line")"
    avail="$(awk '{print $5}' <<<"$line")"
    mount="$(awk '{print $7}' <<<"$line")"

    is_excluded_fs_type "$fs_type" && continue
    [[ "$fs_device" == "$DOCKER_FS_DEVICE" ]] && continue
    [[ "$avail" =~ ^[0-9]+$ ]] || continue
    (( avail >= REQUIRED_BYTES )) || continue
    [[ -d "$mount" ]] || continue

    target="$(suggest_target_path "$mount")"
    label="$(printf '%s  |  %s free  |  fs=%s  |  target=%s' \
      "$mount" "$(human_bytes "$avail")" "$fs_type" "$target")"

    CANDIDATE_LABELS+=("$label")
    CANDIDATE_PATHS+=("$target")
    CANDIDATE_AVAILS+=("$avail")
    CANDIDATE_MOUNTS+=("$mount")
    CANDIDATE_FS_TYPES+=("$fs_type")
  done < <(df -PT -B1 | awk 'NR>1 {print}')
}

sort_candidates() {
  local count="${#CANDIDATE_PATHS[@]}"
  local i j
  for ((i = 0; i < count; i++)); do
    for ((j = i + 1; j < count; j++)); do
      if (( CANDIDATE_AVAILS[j] > CANDIDATE_AVAILS[i] )); then
        local tmp
        tmp="${CANDIDATE_LABELS[i]}"; CANDIDATE_LABELS[i]="${CANDIDATE_LABELS[j]}"; CANDIDATE_LABELS[j]="$tmp"
        tmp="${CANDIDATE_PATHS[i]}";  CANDIDATE_PATHS[i]="${CANDIDATE_PATHS[j]}";  CANDIDATE_PATHS[j]="$tmp"
        tmp="${CANDIDATE_AVAILS[i]}"; CANDIDATE_AVAILS[i]="${CANDIDATE_AVAILS[j]}"; CANDIDATE_AVAILS[j]="$tmp"
        tmp="${CANDIDATE_MOUNTS[i]}"; CANDIDATE_MOUNTS[i]="${CANDIDATE_MOUNTS[j]}"; CANDIDATE_MOUNTS[j]="$tmp"
        tmp="${CANDIDATE_FS_TYPES[i]}"; CANDIDATE_FS_TYPES[i]="${CANDIDATE_FS_TYPES[j]}"; CANDIDATE_FS_TYPES[j]="$tmp"
      fi
    done
  done
}

validate_path_rules() {
  local path="$1"
  [[ -n "$path" ]] || die "Target path is empty."
  [[ "$path" == /* ]] || die "Target path must be an absolute path: $path"
  [[ "$path" != "$DOCKER_DIR" ]] || die "Target path must differ from current Docker dir."
  [[ "$path" != "$DOCKER_DIR"* ]] || die "Target path cannot live inside the current Docker dir."
  [[ "$DOCKER_DIR" != "$path"* ]] || die "Current Docker dir cannot live inside the target path."
}

validate_target_space() {
  local path="$1"
  local parent avail
  parent="$path"
  [[ -d "$parent" ]] || parent="$(dirname "$path")"
  mkdir -p "$path"
  chown root:root "$path"

  if [[ "$ALLOW_NONEMPTY" != "1" ]] && [[ -n "$(ls -A "$path" 2>/dev/null || true)" ]]; then
    die "Target directory must be empty, or use ALLOW_NONEMPTY=1: $path"
  fi

  avail="$(df -P -B1 "$parent" | awk 'NR==2 {print $4}')"
  [[ -n "$avail" && "$avail" -ge "$REQUIRED_BYTES" ]] || die \
    "Not enough space at $parent. Need $(human_bytes "$REQUIRED_BYTES"), available $(human_bytes "${avail:-0}")"
}

pick_target_path() {
  if [[ -n "$NEW_PATH" ]]; then
    validate_path_rules "$NEW_PATH"
    validate_target_space "$NEW_PATH"
    return
  fi

  collect_candidates
  sort_candidates

  if (( ${#CANDIDATE_PATHS[@]} == 0 )); then
    warn "No recommended target path was detected automatically."
    if (( AUTO_MODE == 1 )); then
      die "Auto mode could not find a suitable target path. Re-run with --path /new/docker-data-root"
    fi
    is_interactive_stdin || die \
      "No recommended target path was detected and no interactive terminal is available. Re-run with --path /new/docker-data-root"
    read -r -p "Enter a custom Docker data-root path: " NEW_PATH
    validate_path_rules "$NEW_PATH"
    validate_target_space "$NEW_PATH"
    return
  fi

  info "Recommended migration targets:"
  local i
  for ((i = 0; i < ${#CANDIDATE_PATHS[@]}; i++)); do
    printf '  %d) %s\n' "$((i + 1))" "${CANDIDATE_LABELS[i]}"
  done
  printf '  c) Enter a custom path\n'

  if (( AUTO_MODE == 1 )); then
    NEW_PATH="${CANDIDATE_PATHS[0]}"
    info "Auto-selected target path: $NEW_PATH"
    validate_target_space "$NEW_PATH"
    return
  fi

  local choice
  is_interactive_stdin || die \
    "Interactive target selection requires a terminal. Re-run with --auto or --path /new/docker-data-root"
  while true; do
    read -r -p "Choose a target [1-${#CANDIDATE_PATHS[@]} or c]: " choice
    case "$choice" in
      [1-9]*)
        if (( choice >= 1 && choice <= ${#CANDIDATE_PATHS[@]} )); then
          NEW_PATH="${CANDIDATE_PATHS[choice-1]}"
          break
        fi
        ;;
      c|C)
        read -r -p "Enter a custom Docker data-root path: " NEW_PATH
        break
        ;;
    esac
    warn "Invalid selection. Please try again."
  done

  validate_path_rules "$NEW_PATH"
  validate_target_space "$NEW_PATH"
}

check_daemon_json() {
  [[ ! -f "$CONFIG_FILE" ]] && return 0

  if command -v jq >/dev/null 2>&1; then
    jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "Invalid JSON in $CONFIG_FILE"
  else
    warn "jq not installed. daemon.json will still be updated, but JSON validation is skipped."
  fi
}

confirm_plan() {
  info "Migration plan:"
  info "  From: $DOCKER_DIR"
  info "  To:   $NEW_PATH"
  info "  Need: $(human_bytes "$REQUIRED_BYTES") free space"

  if (( ASSUME_YES == 1 )); then
    return
  fi

  local answer
  read -r -p "Proceed with Docker data migration? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || die "Operation cancelled."
}

stop_service_if_exists() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q "^${service}\.service"; then
      systemctl stop "$service" || true
    fi
    if systemctl list-unit-files | grep -q "^${service}\.socket"; then
      systemctl stop "${service}.socket" || true
    fi
  elif command -v service >/dev/null 2>&1; then
    service "$service" stop || true
  fi
}

start_service_if_exists() {
  local service="$1"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q "^${service}\.service"; then
      systemctl start "$service"
    fi
  elif command -v service >/dev/null 2>&1; then
    service "$service" start
  fi
}

stop_docker_stack() {
  info "Stopping Docker services..."
  stop_service_if_exists "$DOCKER_SERVICE"
  stop_service_if_exists containerd
}

start_docker_stack() {
  info "Starting Docker services..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi
  start_service_if_exists containerd
  start_service_if_exists "$DOCKER_SERVICE"
}

migrate_data() {
  info "Syncing Docker data to $NEW_PATH ..."
  rsync -aHAX --numeric-ids --info=progress2 "$DOCKER_DIR/" "$NEW_PATH/"

  BACKUP_DOCKER_DIR="${DOCKER_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  info "Backing up current Docker data dir to $BACKUP_DOCKER_DIR"
  mv "$DOCKER_DIR" "$BACKUP_DOCKER_DIR"
}

update_daemon_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"

  if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP_CONFIG_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_FILE" "$BACKUP_CONFIG_FILE"
  fi

  if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
    local tmp_file
    tmp_file="$(mktemp)"
    jq --arg path "$NEW_PATH" '.["data-root"]=$path' "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
  else
    cat >"$CONFIG_FILE" <<EOF
{"data-root":"$(json_escape "$NEW_PATH")"}
EOF
  fi
}

verify_result() {
  local actual_root
  actual_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ "$actual_root" == "$NEW_PATH" ]] || die \
    "Verification failed. Docker Root Dir is '$actual_root', expected '$NEW_PATH'."

  info "Verification passed. Docker Root Dir is now $NEW_PATH"
  info "Old data backup: $BACKUP_DOCKER_DIR"
  [[ -n "$BACKUP_CONFIG_FILE" ]] && info "daemon.json backup: $BACKUP_CONFIG_FILE"
}

main() {
  parse_args "$@"
  require_root
  require_cmds
  detect_docker_dir
  calculate_required_space
  check_daemon_json
  pick_target_path
  confirm_plan
  stop_docker_stack
  migrate_data
  update_daemon_config
  start_docker_stack
  verify_result
}

main "$@"
