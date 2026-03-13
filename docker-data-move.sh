#!/bin/bash
# Docker 数据迁移脚本（通用版，支持 CentOS7/8/9, Debian/Ubuntu, Alpine）
# 用法: sudo ./docker-data-move.sh /data1/docker
#
# 来源 (GitHub): https://github.com/tool-tl/docker-data-move.sh
# 作者: tool-tl
# 用法: sudo ./docker-data-move.sh /data1/docker
set -euo pipefail

NEW_PATH=${1:-}
DOCKER_SERVICE="docker"
DOCKER_DIR="/var/lib/docker"
CONFIG_FILE="/etc/docker/daemon.json"

# 允许迁移到非空目录（默认 0=不允许）。需要时可临时：
#   ALLOW_NONEMPTY=1 sudo ./docker-data-move.sh /path
ALLOW_NONEMPTY="${ALLOW_NONEMPTY:-0}"

# ----------- 输出函数 -----------
die()  { echo -e "\n[ERROR] $*\n" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }

# ----------- 检测函数 -----------
require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行（sudo）。"
}

require_new_path() {
  [[ -n "$NEW_PATH" ]] || die "请输入新的 Docker 数据目录路径。用法: sudo $0 /data1/docker"
  [[ "$NEW_PATH" == /* ]] || die "新目录必须使用绝对路径：$NEW_PATH"
  [[ -d "$DOCKER_DIR" ]] || die "旧目录不存在：$DOCKER_DIR，未检测到常规 Docker 安装。"

  if [[ "$NEW_PATH" == "$DOCKER_DIR" ]]; then
    die "新目录不能与当前目录相同：$NEW_PATH"
  fi
  if [[ "$NEW_PATH" == "$DOCKER_DIR"* ]]; then
    die "新目录不能放在旧目录内部：$NEW_PATH 在 $DOCKER_DIR 内"
  fi
  if [[ "$DOCKER_DIR" == "$NEW_PATH"* ]]; then
    die "旧目录不能位于新目录内部：$DOCKER_DIR 在 $NEW_PATH 内"
  fi

  mkdir -p "$NEW_PATH" || die "无法创建新目录：$NEW_PATH"
  chown root:root "$NEW_PATH" || die "无法设置新目录属主：$NEW_PATH"

  if [[ "$ALLOW_NONEMPTY" != "1" ]]; then
    if [[ -d "$NEW_PATH" ]] && [[ -n "$(ls -A "$NEW_PATH" 2>/dev/null || true)" ]]; then
      die "新目录必须为空（或设置 ALLOW_NONEMPTY=1 跳过）：$NEW_PATH"
    fi
  fi
}

require_cmds() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker 命令，请先安装 Docker。"

  if ! command -v rsync >/dev/null 2>&1; then
    warn "未找到 rsync，尝试安装..."
    if [[ -f /etc/debian_version ]]; then
      apt update && apt install -y rsync || true
    elif [[ -f /etc/redhat-release ]]; then
      yum install -y rsync || dnf install -y rsync || true
    elif [[ -f /etc/alpine-release ]]; then
      apk add --no-cache rsync || true
    fi
  fi
  command -v rsync >/dev/null 2>&1 || die "无法安装 rsync，请手动安装后重试。"
}

check_space() {
  local used avail need parent
  used=$(du -sb "$DOCKER_DIR" 2>/dev/null | awk '{print $1}')
  [[ -n "$used" && "$used" -gt 0 ]] || die "无法获取 $DOCKER_DIR 占用空间。"

  parent="$NEW_PATH"
  [[ -d "$parent" ]] || parent="$(dirname "$NEW_PATH")"

  avail=$(df -P -B1 "$parent" 2>/dev/null | awk 'NR==2{print $4}')
  [[ -n "$avail" && "$avail" -gt 0 ]] || die "无法获取 $parent 所在分区可用空间。"

  local GiB2=$((2*1024*1024*1024))
  local need1=$(( (used * 110 + 99) / 100 ))
  local need2=$(( used + GiB2 ))
  need=$(( need1 > need2 ? need1 : need2 ))

  info "旧目录占用：$used 字节；目标可用：$avail 字节；需要至少：$need 字节"
  [[ "$avail" -ge "$need" ]] || die "目标磁盘空间不足（需要：$need，可用：$avail）。"
}

check_selinux() {
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode=$(getenforce 2>/dev/null || echo "")
    if [[ "$mode" == "Enforcing" ]]; then
      cat >&2 </dev/null 2>&1; then
      if ! jq -e '.' "$CONFIG_FILE" >/dev/null 2>&1; then
        local bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$bak" || true
        die "检测到 $CONFIG_FILE 不是合法 JSON，已备份到：$bak"
      fi
    else
      warn "未安装 jq，无法校验 $CONFIG_FILE 的 JSON 合法性。"
    fi
  fi
}

preflight_checks() {
  info "开始进行安全预检..."
  require_root
  require_cmds
  require_new_path
  check_space
  check_selinux
  check_daemon_json
  info "预检通过 ✅"
}

# ----------- 控制 Docker -----------
stop_docker() {
  if command -v systemctl &>/dev/null; then
    systemctl stop "$DOCKER_SERVICE" || true
    systemctl stop "${DOCKER_SERVICE}.socket" || true
  elif command -v service &>/dev/null; then
    service "$DOCKER_SERVICE" stop || true
  else
    die "未检测到 systemctl 或 service，无法自动停止 Docker。"
  fi
}

start_docker() {
  if command -v systemctl &>/dev/null; then
    systemctl daemon-reexec || true
    systemctl start "$DOCKER_SERVICE"
  elif command -v service &>/dev/null; then
    service "$DOCKER_SERVICE" start
  else
    die "未检测到 systemctl 或 service，无法自动启动 Docker。"
  fi
}

# ----------- 主流程 -----------
echo "开始迁移 Docker 数据目录到: $NEW_PATH"

# 自动安装 jq（CentOS7 修复）
if ! command -v jq &>/dev/null; then
  echo "jq 未安装，正在尝试安装..."
  if [[ -f /etc/debian_version ]]; then
    apt update && apt install -y jq || true
  elif [[ -f /etc/redhat-release ]]; then
    yum install -y epel-release || true
    rpm --import https://archive.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7 || true
    yum install -y jq oniguruma || dnf install -y jq oniguruma || true
  elif [[ -f /etc/alpine-release ]]; then
    apk add --no-cache jq || true
  fi
fi

# 0. 预检
preflight_checks

# 1. 停止 Docker
echo "停止 Docker 服务..."
stop_docker

# 2. 确保新路径存在
echo "检查新目录..."
mkdir -p "$NEW_PATH"
chown root:root "$NEW_PATH"

# 3. 迁移数据
echo "迁移数据..."
rsync -aHAX --numeric-ids --delete --info=progress2 "$DOCKER_DIR/" "$NEW_PATH/"

# 4. 备份旧目录
if [[ -d "$DOCKER_DIR" ]]; then
  echo "备份旧目录..."
  mv "$DOCKER_DIR" "${DOCKER_DIR}.bak.$(date +%Y%m%d%H%M%S)"
fi

# 5. 修改配置文件
echo "修改 Docker 配置..."
mkdir -p "$(dirname "$CONFIG_FILE")"
if [[ -f "$CONFIG_FILE" && command -v jq >/dev/null 2>&1 ]]; then
  tmp="${CONFIG_FILE}.tmp"
  # 用 --arg 确保路径安全传入
  if ! jq --arg path "$NEW_PATH" '.["data-root"]=$path' "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
    bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG_FILE" "$bak" || true
    echo '{"data-root":"'$NEW_PATH'"}' > "$tmp"
    warn "原 $CONFIG_FILE 写入失败，已备份到 $bak，并用最小配置覆盖。"
  fi
  mv "$tmp" "$CONFIG_FILE"
else
  echo '{"data-root":"'$NEW_PATH'"}' > "$CONFIG_FILE"
fi

# 6. 启动 Docker
echo "启动 Docker..."
start_docker

# 7. 验证
echo "验证 Docker 数据目录..."
if docker info >/dev/null 2>&1; then
  docker info | grep -E "Docker Root Dir:\s+$NEW_PATH" >/dev/null 2>&1 \
    && echo "验证通过：Docker Root Dir 已是 $NEW_PATH" \
    || die "验证失败：Docker Root Dir 未切换到 $NEW_PATH，请检查。"
else
  die "docker info 执行失败，请检查 Docker 是否正常运行。"
fi

echo "迁移完成！旧数据已备份（如存在）到: ${DOCKER_DIR}.bak.*"