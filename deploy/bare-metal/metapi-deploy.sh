#!/usr/bin/env bash
#
# ╔════════════════════════════════════════════════════════════╗
# ║  Metapi 部署管理脚本 v3 (Ubuntu 22.04)                    ║
# ║  适用于 2核1G 及以下低配置服务器                            ║
# ║  支持: 预编译下载 / 源码编译 / 冲突自动解决 / 智能诊断      ║
# ╚════════════════════════════════════════════════════════════╝
#
# 用法: sudo bash metapi-deploy.sh

set -uo pipefail

# ═══════════════════════════════════════════════════════════
# 常量定义
# ═══════════════════════════════════════════════════════════
readonly APP_NAME="metapi"
readonly APP_DIR="/opt/metapi"
readonly APP_USER="metapi"
readonly APP_GROUP="metapi"
readonly SERVICE_NAME="metapi"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly DATA_DIR="${APP_DIR}/data"
readonly ENV_FILE="${APP_DIR}/.env"
readonly LOG_DIR="/var/log/${APP_NAME}"
readonly LOG_FILE="${LOG_DIR}/deploy.log"
readonly BUILD_LOG="${LOG_DIR}/build.log"
readonly NODE_MAJOR=22
readonly REPO_URL="https://github.com/zczy-k/metapi.git"
readonly RELEASE_API="https://api.github.com/repos/zczy-k/metapi/releases/latest"
readonly DEFAULT_PORT=4000
readonly MARKER_FILE="${APP_DIR}/.metapi_installed"
readonly MARKER_VERSION="3"
readonly SWAP_FILE="/swapfile_metapi"
readonly SYSCTL_CONF="/etc/sysctl.d/99-metapi.conf"

# 运行时变量（可被冲突解决逻辑修改）
ACTUAL_PORT="${DEFAULT_PORT}"
INSTALL_MODE=""  # prebuilt | source

# 安装步骤追踪
declare -a COMPLETED_STEPS=()
declare -a FAILED_STEPS=()

# ═══════════════════════════════════════════════════════════
# 颜色
# ═══════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; log "INFO" "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN" "$*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; log "ERROR" "$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; log "OK" "$*"; }
debug()   { [[ "${VERBOSE:-0}" -eq 1 ]] && echo -e "${DIM}[DEBUG]${NC} $*"; log "DEBUG" "$*"; }
log()     { local lvl="$1"; shift; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$lvl] $*" >> "${LOG_FILE}" 2>/dev/null || true; }

separator() { echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"; }
bold_separator() { echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"; }

press_any_key() {
  echo ""
  read -n 1 -s -r -p "按任意键继续..."
  echo ""
}

confirm() {
  local prompt="$1"
  local default="${2:-N}"
  local yn
  if [ "$default" = "Y" ]; then
    read -rp "${prompt} [Y/n] " yn
    yn="${yn:-Y}"
  else
    read -rp "${prompt} [y/N] " yn
    yn="${yn:-N}"
  fi
  [ "$yn" = "Y" ] || [ "$yn" = "y" ]
}

# ═══════════════════════════════════════════════════════════
# 步骤包装器：统一错误捕获和报告
# ═══════════════════════════════════════════════════════════
step_wrapper() {
  local step_name="$1"
  shift
  local step_fn="$1"
  shift

  info ">>> 步骤: ${step_name}"
  log "STEP" "开始: ${step_name}"

  local start_time
  start_time=$(date +%s)

  if "$step_fn" "$@"; then
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    success "<<< 完成: ${step_name} (${duration}s)"
    COMPLETED_STEPS+=("${step_name}")
    log "STEP" "完成: ${step_name} (${duration}s)"
    return 0
  else
    local exit_code=$?
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    FAILED_STEPS+=("${step_name}")
    log "STEP" "失败: ${step_name} (exit=${exit_code}, ${duration}s)"
    return $exit_code
  fi
}

# ═══════════════════════════════════════════════════════════
# 智能诊断：安装失败时输出详细报告
# ═══════════════════════════════════════════════════════════
show_failure_report() {
  echo ""
  bold_separator
  echo -e "${BOLD}${RED}  安装失败报告${NC}"
  bold_separator

  echo ""
  echo -e "${BOLD}  失败的步骤:${NC}"
  for step in "${FAILED_STEPS[@]}"; do
    echo -e "    ${RED}✗${NC} ${step}"
  done

  if [ ${#COMPLETED_STEPS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BOLD}  已完成的步骤:${NC}"
    for step in "${COMPLETED_STEPS[@]}"; do
      echo -e "    ${GREEN}✓${NC} ${step}"
    done
  fi

  echo ""
  echo -e "${BOLD}  系统状态:${NC}"
  echo -e "    内存:        $(free -h 2>/dev/null | awk '/Mem:/{print $3 " 已用 / " $2 " 总计"}' || echo '未知')"
  echo -e "    磁盘:        $(df -h "${APP_DIR:-/opt}" 2>/dev/null | awk 'NR==2{print $3 " 已用 / " $2 " 总计 (" $5 " 使用率)"}' || echo '未知')"
  echo -e "    CPU 负载:    $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo '未知')"

  echo ""
  echo -e "${BOLD}  日志文件:${NC}"
  echo -e "    部署日志:    ${CYAN}${LOG_FILE}${NC}"
  [ -f "${BUILD_LOG}" ] && echo -e "    构建日志:    ${CYAN}${BUILD_LOG}${NC}"
  echo -e "    服务日志:    ${CYAN}journalctl -u ${SERVICE_NAME} -n 100 --no-pager${NC}"

  echo ""
  echo -e "${BOLD}  常见失败原因及解决方案:${NC}"
  echo ""

  local mem_available
  mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
  if [ "$mem_available" -lt 200 ]; then
    echo -e "    ${YELLOW}▸ 内存不足${NC}  可用内存仅 ${mem_available}MB"
    echo -e "      解决: 配置 swap 后重试，或使用「预编译下载」模式"
  fi

  local disk_use_pct
  disk_use_pct=$(df "${APP_DIR:-/opt}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
  if [ -n "$disk_use_pct" ] && [ "$disk_use_pct" -gt 90 ]; then
    echo -e "    ${YELLOW}▸ 磁盘空间不足${NC}  使用率 ${disk_use_pct}%"
    echo -e "      解决: 清理磁盘空间，预编译模式需要约 300MB"
  fi

  if ! curl -sf --connect-timeout 5 https://github.com >/dev/null 2>&1; then
    echo -e "    ${YELLOW}▸ 网络连接异常${NC}  无法访问 github.com"
    echo -e "      解决: 检查网络和 DNS，或设置代理: export https_proxy=http://proxy:port"
  fi

  echo ""
  echo -e "  ${CYAN}建议: 修复上述问题后，选择「2) 依赖修复」继续，无需从头开始${NC}"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# 前置检查
# ═══════════════════════════════════════════════════════════
preflight_check() {
  if [ "$(id -u)" -ne 0 ]; then
    error "此脚本需要 root 权限运行，请使用: sudo bash $0"
    exit 1
  fi

  if [ ! -f /etc/os-release ]; then
    error "无法检测操作系统版本"
    exit 1
  fi

  source /etc/os-release
  if [ "$ID" != "ubuntu" ]; then
    warn "此脚本针对 Ubuntu 22.04 优化，当前系统: ${PRETTY_NAME}"
    if ! confirm "是否继续？"; then exit 0; fi
  fi

  if [ -n "${VERSION_ID:-}" ] && [ "$VERSION_ID" != "22.04" ]; then
    warn "此脚本针对 Ubuntu 22.04 优化，当前版本: ${VERSION_ID}"
    if ! confirm "是否继续？"; then exit 0; fi
  fi

  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  log "INFO" "===== 脚本启动 ====="
}

# ═══════════════════════════════════════════════════════════
# 系统资源检查
# ═══════════════════════════════════════════════════════════
get_memory_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
get_available_memory_mb() { awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo; }

get_memory_limit() {
  local mem; mem=$(get_memory_mb)
  if [ "$mem" -lt 1024 ]; then echo "192"
  elif [ "$mem" -lt 2048 ]; then echo "256"
  else echo "384"
  fi
}

check_disk_space() {
  local path="${1:-/opt}" needed_mb="${2:-500}"
  local available_kb; available_kb=$(df -P "${path}" 2>/dev/null | awk 'NR==2{print $4}')
  echo $(( available_kb / 1024 ))
}

# ═══════════════════════════════════════════════════════════
# 架构检测
# ═══════════════════════════════════════════════════════════
detect_arch() {
  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "armv7l" ;;
    *) echo "unknown" ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# 网络连通性检测
# ═══════════════════════════════════════════════════════════
check_network() {
  local target="${1:-https://github.com}" timeout="${2:-10}"
  if curl -sf --connect-timeout "$timeout" --max-time "$timeout" "$target" >/dev/null 2>&1; then
    return 0
  else
    if ! host github.com >/dev/null 2>&1 && ! nslookup github.com >/dev/null 2>&1; then
      error "DNS 解析失败，无法解析 github.com"
      return 2
    fi
    error "无法连接到 ${target}，请检查网络或设置代理"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════
# GitHub Release API 查询
# ═══════════════════════════════════════════════════════════
get_latest_release() {
  local api_url="${1:-${RELEASE_API}}"
  local timeout="${2:-15}"

  # 尝试用 curl 获取
  local release_info
  release_info=$(curl -sf --connect-timeout "$timeout" --max-time "$timeout" \
    -H "Accept: application/vnd.github+json" \
    "$api_url" 2>/dev/null)

  if [ -z "$release_info" ]; then
    error "无法获取 GitHub Release 信息"
    return 1
  fi

  echo "$release_info"
}

get_release_version() {
  local release_info="$1"
  echo "$release_info" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1
}

get_release_assets() {
  local release_info="$1"
  local target_arch="$2"
  echo "$release_info" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' | grep "linux-${target_arch}"
}

# ═══════════════════════════════════════════════════════════
# 端口冲突检测与自动解决
# ═══════════════════════════════════════════════════════════
check_port_conflict() { ss -tlnp 2>/dev/null | grep -q ":${1} "; }
get_port_user() { ss -tlnp 2>/dev/null | grep ":${1} " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "未知"; }

find_available_port() {
  local port="$1" max_tries=100
  while [ $max_tries -gt 0 ]; do
    if ! check_port_conflict "$port"; then echo "$port"; return 0; fi
    port=$((port + 1)); max_tries=$((max_tries - 1))
  done
  echo "0"; return 1
}

resolve_port_conflict() {
  local port="${ACTUAL_PORT}"
  if ! check_port_conflict "$port"; then ACTUAL_PORT="$port"; return 0; fi

  local conflict_proc; conflict_proc=$(get_port_user "$port")
  echo ""
  warn "端口 ${port} 已被进程 '${conflict_proc}' 占用"
  echo ""
  echo -e "  ${BOLD}冲突解决选项:${NC}"
  echo -e "    ${GREEN}1${NC}) 自动寻找可用端口（推荐，不影响其他服务）"
  echo -e "    ${YELLOW}2${NC}) 尝试停止占用端口的进程（可能影响其他服务）"
  echo -e "    ${BLUE}3${NC}) 手动指定端口"
  echo -e "    ${RED}0${NC}) 取消安装"
  echo ""

  while true; do
    read -rp "请选择 [0-3]: " port_choice
    case "$port_choice" in
      1)
        local new_port; new_port=$(find_available_port $((port + 1)))
        if [ "$new_port" = "0" ]; then error "未找到可用端口"; return 1; fi
        info "自动选择端口: ${new_port}"; ACTUAL_PORT="$new_port"; return 0 ;;
      2)
        warn "即将停止进程: ${conflict_proc}"
        if confirm "确认停止？"; then
          local pid; pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
          if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null && sleep 2
            if check_port_conflict "$port"; then kill -9 "$pid" 2>/dev/null && sleep 1; fi
            if ! check_port_conflict "$port"; then success "端口已释放"; ACTUAL_PORT="$port"; return 0; fi
          fi
          error "无法释放端口"; return 1
        fi ;;
      3)
        while true; do
          read -rp "请输入端口号 (1024-65535): " manual_port
          if [[ "$manual_port" =~ ^[0-9]+$ ]] && [ "$manual_port" -ge 1024 ] && [ "$manual_port" -le 65535 ]; then
            if ! check_port_conflict "$manual_port"; then ACTUAL_PORT="$manual_port"; return 0; fi
            warn "端口仍被占用"
          fi
        done ;;
      0) return 1 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# 路径冲突检测与自动解决
# ═══════════════════════════════════════════════════════════
resolve_path_conflicts() {
  if [ -d "${APP_DIR}" ]; then
    local dir_owner; dir_owner=$(stat -c '%U:%G' "${APP_DIR}" 2>/dev/null || echo "unknown")
    local is_empty; is_empty=$(find "${APP_DIR}" -maxdepth 1 -not -name "$(basename "${APP_DIR}")" | wc -l)

    if [ "$is_empty" -le 0 ]; then
      info "安装目录 ${APP_DIR} 为空，自动清理"
      rmdir "${APP_DIR}" 2>/dev/null || rm -rf "${APP_DIR}"
      return
    fi

    if [ -f "${MARKER_FILE}" ]; then
      warn "检测到之前的安装目录 ${APP_DIR}"
      return
    fi

    echo ""
    warn "安装目录 ${APP_DIR} 已存在且非 Metapi 创建 (owner: ${dir_owner})"
    echo ""
    echo -e "  ${BOLD}冲突解决选项:${NC}"
    echo -e "    ${GREEN}1${NC}) 备份后使用（将现有目录重命名为 ${APP_DIR}.bak）"
    echo -e "    ${YELLOW}2${NC}) 直接覆盖（删除现有目录内容）"
    echo -e "    ${BLUE}3${NC}) 更改安装路径"
    echo -e "    ${RED}0${NC}) 取消安装"
    echo ""

    read -rp "请选择 [0-3]: " dir_choice
    case "$dir_choice" in
      1) local backup_path="${APP_DIR}.bak.$(date +%Y%m%d%H%M%S)"; info "备份 ${APP_DIR} → ${backup_path}"; mv "${APP_DIR}" "${backup_path}"; mkdir -p "${APP_DIR}" ;;
      2) warn "删除 ${APP_DIR} 中的内容..."; rm -rf "${APP_DIR:?}"/* "${APP_DIR}"/.[!.]* 2>/dev/null || true ;;
      3) read -rp "请输入新的安装路径: " new_dir; if [ -n "$new_dir" ] && [ ! -e "$new_dir" ]; then echo "$new_dir" > /tmp/.metapi_custom_dir; mkdir -p "$new_dir"; else error "路径无效或已存在"; return 1; fi ;;
      0) return 1 ;;
      *) warn "无效选项"; return 1 ;;
    esac
  fi

  # Node.js PATH 冲突
  if command -v node &>/dev/null; then
    local node_count; node_count=$(which -a node 2>/dev/null | wc -l)
    if [ "$node_count" -gt 1 ]; then
      warn "检测到多个 Node.js 安装，使用: $(which node)"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# 用户冲突检测与自动解决
# ═══════════════════════════════════════════════════════════
resolve_user_conflict() {
  if ! id "${APP_USER}" &>/dev/null; then return 0; fi
  local user_home; user_home=$(getent passwd "${APP_USER}" | cut -d: -f6)
  if [ "$user_home" = "${APP_DIR}" ]; then info "用户 '${APP_USER}' 已存在（匹配）"; return 0; fi

  echo ""
  warn "系统用户 '${APP_USER}' 已存在但 home 目录不同 (当前: ${user_home}, 期望: ${APP_DIR})"
  echo ""
  echo -e "  ${BOLD}冲突解决选项:${NC}"
  echo -e "    ${GREEN}1${NC}) 修改用户 home 目录为 ${APP_DIR}（推荐）"
  echo -e "    ${YELLOW}2${NC}) 使用其他用户名"
  echo -e "    ${RED}0${NC}) 取消安装"
  echo ""

  read -rp "请选择 [0-2]: " user_choice
  case "$user_choice" in
    1) usermod -d "${APP_DIR}" -m "${APP_USER}" 2>/dev/null || usermod -d "${APP_DIR}" "${APP_USER}"; success "已修改用户 home 目录" ;;
    2) read -rp "请输入新的用户名: " new_user; if [ -n "$new_user" ] && ! id "$new_user" &>/dev/null; then echo "$new_user" > /tmp/.metapi_custom_user; else error "用户名无效或已存在"; return 1; fi ;;
    0) return 1 ;;
    *) warn "无效选项"; return 1 ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# 环境检测
# ═══════════════════════════════════════════════════════════
check_environment() {
  echo ""
  separator
  echo -e "${BOLD}  环境检测${NC}"
  separator

  local found_issues=0

  id "${APP_USER}" &>/dev/null && warn "用户 '${APP_USER}' 已存在" || info "用户 '${APP_USER}' 不存在 ✓"
  [ -d "${APP_DIR}" ] && { warn "安装目录 ${APP_DIR} 已存在"; found_issues=1; } || info "安装目录不存在 ✓"
  [ -f "${SERVICE_FILE}" ] && { warn "systemd 服务文件已存在"; found_issues=1; } || info "systemd 服务文件不存在 ✓"
  systemctl is-enabled "${SERVICE_NAME}" &>/dev/null && { warn "systemd 服务已启用"; found_issues=1; } || info "systemd 服务未启用 ✓"
  check_port_conflict "${DEFAULT_PORT}" && { warn "端口 ${DEFAULT_PORT} 被占用"; found_issues=1; } || info "端口 ${DEFAULT_PORT} 未被占用 ✓"

  if command -v node &>/dev/null; then
    local node_major; node_major=$(node -v | sed 's/v//' | cut -d. -f1)
    [ "$node_major" -ge "$NODE_MAJOR" ] && success "Node.js $(node -v) ✓" || { warn "Node.js $(node -v) 版本过低"; found_issues=1; }
  else
    if [ "${INSTALL_MODE}" = "source" ]; then info "Node.js 未安装（源码编译模式需要）"; found_issues=1; else info "Node.js 未安装（预编译模式不需要编译，但仍需 Node.js 运行时）"; fi
  fi

  local available_mb; available_mb=$(check_disk_space "/opt" 300)
  [ "$available_mb" -lt 300 ] && { warn "磁盘可用空间仅 ${available_mb}MB"; found_issues=1; } || info "磁盘可用空间 ${available_mb}MB ✓"
  check_network "https://github.com" 5 || found_issues=1

  [ "$found_issues" -eq 1 ] && warn "检测到冲突或残留项，安装时将自动处理" || success "环境干净，无冲突"
  return "$found_issues"
}

# ═══════════════════════════════════════════════════════════
# 清理残留
# ═══════════════════════════════════════════════════════════
cleanup_residuals() {
  info "正在清理残留..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true

  if command -v pm2 &>/dev/null && pm2 describe "${APP_NAME}" &>/dev/null 2>&1; then
    pm2 delete "${APP_NAME}" 2>/dev/null || true
    pm2 save 2>/dev/null || true
  fi

  rm -f "${MARKER_FILE}"
  rm -f /tmp/.metapi_custom_dir /tmp/.metapi_custom_user 2>/dev/null || true
  success "残留清理完成"
}

# ═══════════════════════════════════════════════════════════
# 安装模式选择
# ═══════════════════════════════════════════════════════════
choose_install_mode() {
  echo ""
  separator
  echo -e "${BOLD}  选择安装模式${NC}"
  separator
  echo ""
  echo -e "  ${GREEN}1${NC}) 预编译下载（推荐）— 从 GitHub Release 下载预编译包，${BOLD}无需服务器编译${NC}"
  echo -e "      优势: 快速、低资源占用，适合 2核1G 服务器"
  echo ""
  echo -e "  ${YELLOW}2${NC}) 源码编译 — 在服务器上 git clone + npm build"
  echo -e "      优势: 可自定义修改，需要 >= 2G 内存和较长编译时间"
  echo ""
  echo -e "  ${RED}0${NC}) 取消"
  echo ""

  # 自动推荐
  local mem_mb; mem_mb=$(get_memory_mb)
  if [ "$mem_mb" -lt 2048 ]; then
    echo -e "  ${CYAN}当前内存 ${mem_mb}MB，推荐使用「预编译下载」模式${NC}"
  fi

  while true; do
    read -rp "请选择 [0-2] (默认 1): " mode_choice
    mode_choice="${mode_choice:-1}"
    case "$mode_choice" in
      1) INSTALL_MODE="prebuilt"; info "已选择: 预编译下载模式"; return 0 ;;
      2) INSTALL_MODE="source"; info "已选择: 源码编译模式"; return 0 ;;
      0) return 1 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# [预编译] 下载并安装预编译包
# ═══════════════════════════════════════════════════════════
download_prebuilt() {
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)
  local arch; arch=$(detect_arch)

  info "系统架构: ${arch}"

  if [ "$arch" = "unknown" ]; then
    error "无法识别系统架构，请使用源码编译模式"
    return 1
  fi

  # 查询 GitHub Release
  info "查询最新版本..."
  local release_info
  release_info=$(get_latest_release)
  if [ -z "$release_info" ]; then
    error "无法获取最新版本信息"
    return 1
  fi

  local version; version=$(get_release_version "$release_info")
  info "最新版本: ${version}"

  # 查找对应架构的下载链接
  local download_url
  download_url=$(get_release_assets "$release_info" "$arch")

  if [ -z "$download_url" ]; then
    # 没有 GitHub Release 预编译包，尝试直接下载
    warn "GitHub Release 中未找到 ${arch} 架构的预编译包"
    echo ""
    echo -e "  ${BOLD}可能的原因:${NC}"
    echo -e "    - 项目尚未配置 CI/CD 自动构建"
    echo -e "    - 当前架构 (${arch}) 暂不支持预编译"
    echo ""
    echo -e "  ${BOLD}解决方案:${NC}"
    echo -e "    ${GREEN}1${NC}) 切换到「源码编译」模式（需要更多内存和时间）"
    echo -e "    ${GREEN}2${NC}) 在自己的 GitHub Fork 上配置 CI/CD（详见 DEPLOY-GUIDE.md）"
    echo -e "    ${GREEN}3${NC}) 在本地或其他高配机器上编译后上传"
    echo ""

    if confirm "是否切换到源码编译模式？"; then
      INSTALL_MODE="source"
      return 0
    fi
    return 1
  fi

  info "下载地址: ${download_url}"

  # 下载
  local tmp_dir; tmp_dir=$(mktemp -d)
  local filename; filename=$(basename "$download_url")
  local tmp_file="${tmp_dir}/${filename}"

  info "下载预编译包..."
  if ! curl -fSL --connect-timeout 30 --max-time 600 --progress-bar -o "$tmp_file" "$download_url" 2>&1; then
    error "下载失败"
    rm -rf "${tmp_dir}"
    return 1
  fi

  # 解压
  info "解压..."
  if ! tar -xzf "$tmp_file" -C "$tmp_dir" 2>&1; then
    error "解压失败，文件可能已损坏"
    rm -rf "${tmp_dir}"
    return 1
  fi

  # 找到解压后的目录
  local extracted_dir
  extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "metapi-*" | head -1)
  if [ -z "$extracted_dir" ]; then
    extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d | tail -1)
  fi

  if [ -z "$extracted_dir" ] || [ ! -d "${extracted_dir}/dist" ]; then
    error "预编译包结构异常，未找到 dist 目录"
    rm -rf "${tmp_dir}"
    return 1
  fi

  # 移动到安装目录
  info "安装到 ${target_dir}..."
  if [ -d "${target_dir}" ]; then
    # 保留已有的 .env 和 data/
    if [ -f "${target_dir}/.env" ]; then
      cp -a "${target_dir}/.env" "${tmp_dir}/env_backup"
    fi
    if [ -d "${target_dir}/data" ]; then
      cp -a "${target_dir}/data" "${tmp_dir}/data_backup"
    fi
    rm -rf "${target_dir:?}"/* "${target_dir}"/.[!.]* 2>/dev/null || true
  else
    mkdir -p "${target_dir}"
  fi

  # 复制文件
  cp -a "${extracted_dir}/." "${target_dir}/"

  # 恢复 .env 和 data/
  if [ -f "${tmp_dir}/env_backup" ]; then
    cp -a "${tmp_dir}/env_backup" "${target_dir}/.env"
  fi
  if [ -d "${tmp_dir}/data_backup" ]; then
    cp -a "${tmp_dir}/data_backup/." "${target_dir}/data/"
  fi

  # 清理临时文件
  rm -rf "${tmp_dir}"

  # 验证
  if [ ! -f "${target_dir}/dist/server/index.js" ]; then
    error "安装验证失败: dist/server/index.js 不存在"
    return 1
  fi

  if [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    warn "better-sqlite3 原生模块未找到，可能架构不匹配"
  fi

  success "预编译包安装完成 (版本: ${version})"
  return 0
}

# ═══════════════════════════════════════════════════════════
# [预编译] 安装 Node.js 运行时（仅运行时，不需要编译工具）
# ═══════════════════════════════════════════════════════════
install_node_runtime() {
  if command -v node &>/dev/null; then
    local current_major; current_major=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$current_major" -ge "$NODE_MAJOR" ]; then
      success "Node.js $(node -v) 已满足要求"
      return 0
    fi
    warn "当前 Node.js $(node -v) 版本过低，需要升级到 ${NODE_MAJOR}+"
  fi

  info "安装 Node.js ${NODE_MAJOR} 运行时..."

  # NodeSource 安装
  local retry=0
  while [ $retry -lt 3 ]; do
    if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - 2>&1; then
      break
    fi
    retry=$((retry + 1))
    warn "NodeSource 设置失败 (尝试 $retry/3)"
    sleep 5
  done

  if [ $retry -ge 3 ]; then
    error "NodeSource 安装失败，尝试官方二进制下载..."
    local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo "x64")
    local node_url="https://nodejs.org/dist/v${NODE_MAJOR}.0.0/node-v${NODE_MAJOR}.0.0-linux-${arch}.tar.xz"
    if curl -fsSL "$node_url" | tar -xJ -C /usr/local --strip-components=1; then
      success "Node.js $(node -v) 安装成功（官方二进制）"
      return 0
    else
      error "Node.js 安装失败，请手动安装"
      return 1
    fi
  fi

  if apt-get install -y -qq nodejs 2>&1; then
    success "Node.js $(node -v) 安装成功"
  else
    error "Node.js 安装失败"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════
# [源码] 安装系统依赖
# ═══════════════════════════════════════════════════════════
install_system_deps() {
  info "安装系统依赖..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  apt-get update -qq 2>&1 | tail -3 >> "${LOG_FILE}"

  if ! apt-get install -y -qq curl git python3 make g++ ca-certificates gnupg apt-transport-https lsb-release 2>&1; then
    error "系统依赖安装失败，尝试修复..."
    dpkg --configure -a 2>/dev/null
    apt-get install -f -y 2>/dev/null
    apt-get update -qq 2>/dev/null
    if ! apt-get install -y -qq curl git python3 make g++ ca-certificates gnupg apt-transport-https lsb-release 2>&1; then
      error "系统依赖安装仍然失败"
      return 1
    fi
  fi
  success "系统依赖安装完成"
}

# ═══════════════════════════════════════════════════════════
# [源码] 安装 Node.js（编译 + 运行时）
# ═══════════════════════════════════════════════════════════
install_node_full() {
  if command -v node &>/dev/null; then
    local current_major; current_major=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$current_major" -ge "$NODE_MAJOR" ]; then
      success "Node.js $(node -v) 已满足要求"
      return 0
    fi
  fi

  info "安装 Node.js ${NODE_MAJOR}（编译 + 运行时）..."

  # 检查 nvm 冲突
  if [ -d "${HOME}/.nvm" ]; then
    warn "检测到 nvm 安装，可能与 NodeSource 冲突"
    if confirm "是否跳过 nvm 使用 NodeSource？"; then
      export PATH=$(echo "$PATH" | sed "s|${HOME}/.nvm/versions/node/[^:]*:||g")
    fi
  fi

  local retry=0
  while [ $retry -lt 3 ]; do
    if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - 2>&1; then break; fi
    retry=$((retry + 1)); sleep 5
  done

  if [ $retry -ge 3 ]; then
    error "NodeSource 安装失败，尝试官方二进制..."
    local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo "x64")
    local node_url="https://nodejs.org/dist/v${NODE_MAJOR}.0.0/node-v${NODE_MAJOR}.0.0-linux-${arch}.tar.xz"
    if curl -fsSL "$node_url" | tar -xJ -C /usr/local --strip-components=1; then
      success "Node.js $(node -v) 安装成功（官方二进制）"; return 0
    else
      error "Node.js 安装失败"; return 1
    fi
  fi

  if apt-get install -y -qq nodejs 2>&1; then
    success "Node.js $(node -v) 安装成功"
  else
    error "Node.js 安装失败"; return 1
  fi
}

# ═══════════════════════════════════════════════════════════
# 创建隔离用户
# ═══════════════════════════════════════════════════════════
create_user() {
  local user="${APP_USER}"
  [ -f /tmp/.metapi_custom_user ] && user=$(cat /tmp/.metapi_custom_user)

  if id "${user}" &>/dev/null; then
    info "用户 '${user}' 已存在"; return 0
  fi

  info "创建隔离用户 '${user}'..."
  useradd -r -m -s /bin/bash -d "${APP_DIR}" "${user}"
  passwd -l "${user}" 2>/dev/null || true
  success "用户 '${user}' 创建完成"
}

# ═══════════════════════════════════════════════════════════
# [源码] 克隆代码并构建
# ═══════════════════════════════════════════════════════════
clone_and_build() {
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  info "克隆代码到 ${target_dir}..."

  if [ -d "${target_dir}/.git" ]; then
    cd "${target_dir}"
    git fetch --all 2>&1 | tail -3
    git reset --hard origin/main 2>&1 | tail -3
  else
    if ! check_network "${REPO_URL}" 10; then
      error "无法访问 GitHub"
      return 1
    fi
    mkdir -p "${target_dir}"
    git clone "${REPO_URL}" "${target_dir}" 2>&1 | tail -5
    cd "${target_dir}"
  fi

  # npm install（带智能重试）
  info "安装项目依赖..."
  local npm_retry=0
  while [ $npm_retry -lt 3 ]; do
    npm_retry=$((npm_retry + 1))
    if npm ci --ignore-scripts --no-audit --no-fund 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then break; fi
    warn "npm ci 失败 (尝试 ${npm_retry}/3)"

    if grep -qi "EACCES" "${BUILD_LOG}" 2>/dev/null; then
      mkdir -p "${target_dir}/.npm"; chown -R "$(whoami)" "${target_dir}/.npm" 2>/dev/null; npm cache clean --force 2>/dev/null
    fi
    if grep -qi "ENOTFOUND\|ECONNREFUSED\|ETIMEDOUT" "${BUILD_LOG}" 2>/dev/null; then
      if ! check_network "https://registry.npmjs.org" 5; then npm config set registry https://registry.npmmirror.com 2>/dev/null; fi
    fi
    [ $npm_retry -lt 3 ] && { info "5秒后重试..."; sleep 5; }
  done

  if [ $npm_retry -ge 3 ]; then
    error "npm ci 多次重试后仍然失败"; return 1
  fi

  # 重建原生模块
  info "重建原生模块..."
  if ! npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
    warn "原生模块重建出现问题"
    if [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
      cd "${target_dir}/node_modules/better-sqlite3"; npm run build-release 2>&1 | tail -5 >> "${BUILD_LOG}" || true; cd "${target_dir}"
    fi
  fi

  # 构建前端
  info "构建前端..."
  if ! npm run build:web 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
    warn "清理缓存后重试..."
    rm -rf "${target_dir}/node_modules/.vite" "${target_dir}/node_modules/.cache"
    if ! npm run build:web 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then error "前端构建失败"; return 1; fi
  fi

  # 构建后端
  info "构建后端..."
  if ! npm run build:server 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then error "后端构建失败"; return 1; fi

  # 清理开发依赖
  npm prune --omit=dev --no-audit --no-fund 2>&1 | tail -3 >> "${BUILD_LOG}"

  # 验证
  if [ ! -f "${target_dir}/dist/server/index.js" ]; then error "构建验证失败"; return 1; fi

  success "项目构建完成"
}

# ═══════════════════════════════════════════════════════════
# 配置环境变量
# ═══════════════════════════════════════════════════════════
configure_env() {
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)
  local env_file="${target_dir}/.env"

  if [ -f "${env_file}" ]; then
    info ".env 文件已存在，保留当前配置"
    local configured_port; configured_port=$(grep "^PORT=" "${env_file}" 2>/dev/null | cut -d= -f2)
    [ -n "$configured_port" ] && ACTUAL_PORT="$configured_port"
    return 0
  fi

  info "配置环境变量..."

  echo ""
  echo -e "${CYAN}请设置 Metapi 的认证令牌：${NC}"
  echo -e "${YELLOW}  AUTH_TOKEN   = 管理后台登录令牌${NC}"
  echo -e "${YELLOW}  PROXY_TOKEN  = 下游客户端调用 API 的令牌${NC}"
  echo ""

  local auth_token proxy_token
  while true; do read -rp "AUTH_TOKEN: " auth_token; [ -z "$auth_token" ] || [ "$auth_token" = "change-me-admin-token" ] && { warn "请设置安全令牌"; continue; } || break; done
  while true; do read -rp "PROXY_TOKEN: " proxy_token; [ -z "$proxy_token" ] || [ "$proxy_token" = "change-me-proxy-sk-token" ] && { warn "请设置安全令牌"; continue; } || break; done

  local mem_limit; mem_limit=$(get_memory_limit)

  cat > "${env_file}" << EOF
# Metapi 环境变量配置
# 由部署脚本自动生成，可手动修改
AUTH_TOKEN=${auth_token}
PROXY_TOKEN=${proxy_token}
PORT=${ACTUAL_PORT}
DATA_DIR=${target_dir}/data
CHECKIN_CRON=0 8 * * *
BALANCE_REFRESH_CRON=0 * * * *
TZ=Asia/Shanghai
NODE_OPTIONS=--max-old-space-size=${mem_limit}

# 自动更新源（GitHub Release API）
UPDATE_CHECK_URL=https://api.github.com/repos/zczy-k/metapi/releases/latest
EOF

  chmod 600 "${env_file}"
  success ".env 配置完成 (端口: ${ACTUAL_PORT})"
}

# ═══════════════════════════════════════════════════════════
# 配置 Swap
# ═══════════════════════════════════════════════════════════
configure_swap() {
  local total_mem; total_mem=$(get_memory_mb)
  if [ "$total_mem" -ge 2048 ]; then info "内存充足 (${total_mem}MB)，无需配置 Swap"; return 0; fi

  local current_swap_mb; current_swap_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  if [ "$current_swap_mb" -ge 1024 ]; then info "Swap 已有 ${current_swap_mb}MB，满足要求"; return 0; fi

  echo ""
  warn "内存仅 ${total_mem}MB，建议配置 Swap 以防 OOM"
  if ! confirm "是否创建 1GB Swap？"; then return 0; fi

  if [ -f "${SWAP_FILE}" ]; then swapoff "${SWAP_FILE}" 2>/dev/null || true; rm -f "${SWAP_FILE}"; fi

  info "创建 1GB swap..."
  if ! fallocate -l 1G "${SWAP_FILE}" 2>/dev/null; then
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=1024 status=progress
  fi

  chmod 600 "${SWAP_FILE}"; mkswap "${SWAP_FILE}"; swapon "${SWAP_FILE}"
  grep -q "${SWAP_FILE}" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab

  sysctl vm.swappiness=10 >/dev/null
  grep -q "vm.swappiness" "${SYSCTL_CONF}" 2>/dev/null || echo "vm.swappiness=10" > "${SYSCTL_CONF}"
  success "Swap 配置完成"
}

# ═══════════════════════════════════════════════════════════
# 安装 systemd 服务
# ═══════════════════════════════════════════════════════════
install_systemd_service() {
  info "配置 systemd 服务..."

  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)
  local target_user="${APP_USER}"
  [ -f /tmp/.metapi_custom_user ] && target_user=$(cat /tmp/.metapi_custom_user)
  local target_data="${target_dir}/data"
  local env_file="${target_dir}/.env"
  local node_path; node_path=$(which node)
  local mem_limit; mem_limit=$(get_memory_limit)

  local env_block=""
  if [ -f "${env_file}" ]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*#.*$ ]] && continue
      [[ -z "$key" ]] && continue
      key=$(echo "$key" | xargs); [[ -z "$key" ]] && continue
      env_block+="Environment=${key}=${value}"$'\n'
    done < "${env_file}"
  fi

  cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Metapi - AI API Aggregation Gateway
Documentation=https://metapi.cita777.me
After=network.target
ConditionPathExists=${target_dir}/dist/server/index.js

[Service]
Type=simple
User=${target_user}
Group=${target_user}
WorkingDirectory=${target_dir}

Environment=NODE_ENV=production
Environment=DATA_DIR=${target_data}
Environment=NODE_OPTIONS=--max-old-space-size=${mem_limit}
${env_block}
ExecStartPre=${node_path} dist/server/db/migrate.js
ExecStart=${node_path} dist/server/index.js

Restart=on-failure
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=60

StandardOutput=journal
StandardError=journal
SyslogIdentifier=metapi

NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${target_data} ${target_dir}/drizzle
ProtectHome=true
PrivateTmp=true

LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  success "systemd 服务配置完成"
}

# ═══════════════════════════════════════════════════════════
# 设置文件权限
# ═══════════════════════════════════════════════════════════
set_permissions() {
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)
  local target_user="${APP_USER}"
  [ -f /tmp/.metapi_custom_user ] && target_user=$(cat /tmp/.metapi_custom_user)

  info "设置文件权限..."
  mkdir -p "${target_dir}/data"
  chown -R "${target_user}:${target_user}" "${target_dir}"
  chmod 700 "${target_dir}"
  chmod 600 "${target_dir}/.env" 2>/dev/null
  chmod 700 "${target_dir}/data"
  success "权限设置完成"
}

# ═══════════════════════════════════════════════════════════
# 写入安装标记
# ═══════════════════════════════════════════════════════════
write_marker() {
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)
  local target_user="${APP_USER}"
  [ -f /tmp/.metapi_custom_user ] && target_user=$(cat /tmp/.metapi_custom_user)

  cat > "${MARKER_FILE}" << EOF
version=${MARKER_VERSION}
install_time=$(date '+%Y-%m-%d %H:%M:%S')
node_version=$(node -v 2>/dev/null || echo "unknown")
user=${target_user}
dir=${target_dir}
service=${SERVICE_FILE}
port=${ACTUAL_PORT}
swap=${SWAP_FILE}
install_mode=${INSTALL_MODE}
EOF
  chown "${target_user}:${target_user}" "${MARKER_FILE}" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# 启动服务（带智能诊断）
# ═══════════════════════════════════════════════════════════
start_service() {
  info "启动 Metapi 服务..."
  systemctl start "${SERVICE_NAME}"

  local retry=0
  while [ $retry -lt 20 ]; do
    if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then success "服务启动成功"; return 0; fi
    retry=$((retry + 1)); sleep 1
  done

  error "服务启动失败，正在诊断..."
  echo ""
  systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
  echo ""
  journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null || true

  echo ""
  echo -e "${BOLD}  智能诊断:${NC}"
  if check_port_conflict "${ACTUAL_PORT}"; then warn "▸ 端口 ${ACTUAL_PORT} 被占用"; fi
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "Cannot find module\|MODULE_NOT_FOUND"; then warn "▸ 模块加载失败 → 执行依赖修复"; fi
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "ENOMEM\|out of memory\|killed"; then warn "▸ 内存不足 → 配置 Swap 或降低内存限制"; fi
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "better-sqlite3\|native\|\.node"; then warn "▸ 原生模块问题 → 架构可能不匹配"; fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# 防火墙提示
# ═══════════════════════════════════════════════════════════
show_firewall_hint() {
  local port="${ACTUAL_PORT}"

  echo ""
  bold_separator
  echo -e "${BOLD}${YELLOW}  防火墙端口提示${NC}"
  bold_separator
  echo ""
  echo -e "  Metapi 服务运行在端口 ${CYAN}${port}${NC}，请确保该端口在防火墙中开放。"
  echo ""

  local fw_type="未知" fw_active=false
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then fw_type="ufw"; fw_active=true
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then fw_type="firewalld"; fw_active=true
  elif command -v iptables &>/dev/null && iptables -L -n 2>/dev/null | grep -q "INPUT"; then fw_type="iptables"; fw_active=true
  fi

  if [ "$fw_active" = true ]; then
    echo -e "  ${YELLOW}检测到防火墙: ${fw_type} (已启用)${NC}"
    echo -e "  ${BOLD}执行以下命令开放端口:${NC}"
    case "$fw_type" in
      ufw) echo -e "    ${CYAN}ufw allow ${port}/tcp && ufw reload${NC}" ;;
      firewalld) echo -e "    ${CYAN}firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload${NC}" ;;
      iptables) echo -e "    ${CYAN}iptables -A INPUT -p tcp --dport ${port} -j ACCEPT${NC}" ;;
    esac
  else
    echo -e "  ${GREEN}未检测到活动的防火墙${NC}"
  fi

  echo ""
  echo -e "  ${BOLD}${YELLOW}⚠ 云服务器需在安全组中放行端口 ${port}/TCP${NC}"
  echo ""

  # 端口可达性验证
  if command -v curl &>/dev/null; then
    info "验证本地端口连通性..."
    sleep 2
    if curl -sf --connect-timeout 3 "http://127.0.0.1:${port}" >/dev/null 2>&1; then
      success "端口 ${port} 本地可达 ✓"
    else
      warn "端口 ${port} 本地暂未响应（服务可能仍在启动中）"
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# 功能：新装
# ═══════════════════════════════════════════════════════════
do_install() {
  COMPLETED_STEPS=()
  FAILED_STEPS=()

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║          Metapi 新装部署                      ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  # 步骤 0: 安装模式选择
  if ! choose_install_mode; then return 1; fi

  # 步骤 1: 资源预检
  separator
  info "预检..."
  local avail_mb; avail_mb=$(check_disk_space "/opt" 300)
  if [ "$avail_mb" -lt 300 ]; then
    error "磁盘可用空间仅 ${avail_mb}MB，至少需要 300MB"
    if ! confirm "是否仍要继续？"; then return 1; fi
  fi

  local need_mb=500
  [ "${INSTALL_MODE}" = "prebuilt" ] && need_mb=300
  if ! check_network "https://github.com" 10; then
    warn "网络检测未通过，安装可能失败"
    if ! confirm "是否继续？"; then return 1; fi
  fi

  # 步骤 2: 环境检测
  check_environment
  local env_result=$?

  # 步骤 3: 冲突解决
  separator
  info "冲突检测与自动解决..."
  if ! resolve_port_conflict; then error "端口冲突无法解决"; return 1; fi
  if ! resolve_path_conflicts; then error "路径冲突无法解决"; return 1; fi
  if ! resolve_user_conflict; then error "用户冲突无法解决"; return 1; fi

  # 如有残留，先清理
  if [ "$env_result" -ne 0 ]; then
    if confirm "是否清理残留后继续安装？"; then cleanup_residuals
    else error "请先执行卸载操作"; return 1; fi
  fi

  echo ""
  info "冲突解决完成，开始安装..."
  echo ""

  # ═══════ 根据安装模式执行不同步骤 ═══════

  if [ "${INSTALL_MODE}" = "prebuilt" ]; then
    # ── 预编译模式 ──
    separator
    if ! step_wrapper "安装 Node.js 运行时" install_node_runtime; then show_failure_report; return 1; fi

    separator
    if ! step_wrapper "下载预编译包" download_prebuilt; then show_failure_report; return 1; fi

    # 如果预编译下载失败切换到源码模式
    if [ "${INSTALL_MODE}" = "source" ]; then
      warn "已切换到源码编译模式"
    fi
  fi

  if [ "${INSTALL_MODE}" = "source" ]; then
    # ── 源码编译模式 ──
    separator
    if ! step_wrapper "安装系统依赖" install_system_deps; then show_failure_report; return 1; fi

    separator
    if ! step_wrapper "安装 Node.js（编译+运行时）" install_node_full; then show_failure_report; return 1; fi

    separator
    if ! step_wrapper "创建隔离用户" create_user; then show_failure_report; return 1; fi

    separator
    if ! step_wrapper "克隆代码并构建" clone_and_build; then show_failure_report; return 1; fi
  else
    # 预编译模式也需要创建用户
    separator
    if ! step_wrapper "创建隔离用户" create_user; then show_failure_report; return 1; fi
  fi

  # ═══════ 通用步骤 ═══════
  separator
  if ! step_wrapper "配置环境变量" configure_env; then show_failure_report; return 1; fi

  separator
  if ! step_wrapper "配置 Swap" configure_swap; then
    warn "Swap 配置失败，不影响安装，但低内存时可能出现 OOM"
  fi

  separator
  if ! step_wrapper "安装服务并设置权限" _install_service_and_perms; then show_failure_report; return 1; fi

  separator
  if ! step_wrapper "启动服务" start_service; then show_failure_report; return 1; fi

  # 完成
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  echo ""
  bold_separator
  echo -e "${BOLD}${GREEN}  安装完成！${NC}"
  bold_separator
  echo ""
  local ip_addr; ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')
  echo -e "  安装模式:    ${CYAN}${INSTALL_MODE}${NC}"
  echo -e "  访问地址:    ${CYAN}http://${ip_addr}:${ACTUAL_PORT}${NC}"
  echo -e "  管理令牌:    .env 中的 AUTH_TOKEN"
  echo ""
  echo -e "  ${BOLD}常用命令:${NC}"
  echo -e "    ${CYAN}systemctl status ${SERVICE_NAME}${NC}         查看状态"
  echo -e "    ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}       查看日志"
  echo -e "    ${CYAN}systemctl restart ${SERVICE_NAME}${NC}      重启服务"
  echo ""
  echo -e "  ${BOLD}自动更新:${NC}"
  echo -e "    ${CYAN}sudo bash ${target_dir}/deploy/bare-metal/metapi-updater.sh --check${NC}  检查更新"
  echo -e "    ${CYAN}sudo bash ${target_dir}/deploy/bare-metal/metapi-updater.sh${NC}           执行更新"
  echo ""
  echo -e "  配置文件:    ${CYAN}${target_dir}/.env${NC}"
  echo -e "  数据目录:    ${CYAN}${target_dir}/data${NC}"
  echo -e "  部署日志:    ${CYAN}${LOG_FILE}${NC}"
  echo ""

  show_firewall_hint
  rm -f /tmp/.metapi_custom_dir /tmp/.metapi_custom_user 2>/dev/null || true
}

_install_service_and_perms() {
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)
  mkdir -p "${target_dir}/data"
  install_systemd_service
  set_permissions
  write_marker
}

# ═══════════════════════════════════════════════════════════
# 功能：依赖修复
# ═══════════════════════════════════════════════════════════
do_repair() {
  COMPLETED_STEPS=()
  FAILED_STEPS=()

  echo ""
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${YELLOW}║          依赖修复                            ║${NC}"
  echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  if [ ! -f "${MARKER_FILE}" ] && [ ! -d "${target_dir}" ]; then
    error "未检测到安装记录，请先执行新装"; return 1
  fi

  info "当前环境诊断："
  echo ""

  local issues=0

  # Node.js
  echo -e "${BOLD}  [1] Node.js${NC}"
  if ! command -v node &>/dev/null; then error "  ✗ 未安装"; issues=$((issues + 1))
  else
    local node_major; node_major=$(node -v | sed 's/v//' | cut -d. -f1)
    [ "$node_major" -lt "$NODE_MAJOR" ] && { error "  ✗ 版本过低"; issues=$((issues + 1)); } || success "  ✓ $(node -v)"
  fi

  # 安装目录
  echo -e "${BOLD}  [2] 安装目录${NC}"
  [ ! -d "${target_dir}" ] && { error "  ✗ 目录不存在"; issues=$((issues + 1)); } || success "  ✓ ${target_dir}"

  # 构建产物
  echo -e "${BOLD}  [3] 构建产物${NC}"
  [ ! -f "${target_dir}/dist/server/index.js" ] && { error "  ✗ dist/server/index.js 缺失"; issues=$((issues + 1)); } || success "  ✓ dist/server/index.js"

  # 原生模块
  echo -e "${BOLD}  [4] 原生模块${NC}"
  [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ] && { error "  ✗ better-sqlite3 未编译"; issues=$((issues + 1)); } || success "  ✓ better-sqlite3"

  # systemd 服务
  echo -e "${BOLD}  [5] systemd 服务${NC}"
  [ ! -f "${SERVICE_FILE}" ] && { error "  ✗ 服务文件不存在"; issues=$((issues + 1)); } || {
    success "  ✓ 服务文件存在"
    systemctl is-active "${SERVICE_NAME}" &>/dev/null || { warn "  ! 服务未运行"; issues=$((issues + 1)); }
  }

  # 配置
  echo -e "${BOLD}  [6] 配置文件${NC}"
  [ ! -f "${target_dir}/.env" ] && { error "  ✗ .env 不存在"; issues=$((issues + 1)); } || success "  ✓ .env"

  echo ""
  [ "$issues" -eq 0 ] && { success "所有依赖正常"; return 0; }

  warn "发现 ${issues} 个问题"
  if ! confirm "是否开始修复？"; then return 0; fi

  echo ""
  step_wrapper "修复 Node.js" install_node_runtime || true

  # 如果是源码编译安装的，重新构建
  local install_mode; install_mode=$(grep '^install_mode=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
  if [ "$install_mode" = "source" ] && [ -d "${target_dir}/.git" ]; then
    step_wrapper "重新构建" clone_and_build || true
  fi

  # 修复原生模块
  if [ -f "${target_dir}/node_modules/better-sqlite3/package.json" ] && [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    info "重新编译 better-sqlite3..."
    cd "${target_dir}/node_modules/better-sqlite3"; npm run build-release 2>&1 | tail -5; cd "${target_dir}"
  fi

  [ ! -f "${target_dir}/.env" ] && step_wrapper "修复配置文件" configure_env || true
  [ ! -f "${SERVICE_FILE}" ] && step_wrapper "修复 systemd 服务" install_systemd_service || true
  set_permissions

  # 重启
  [ -f "${SERVICE_FILE}" ] && { systemctl daemon-reload; systemctl restart "${SERVICE_NAME}" || true; }

  echo ""
  [ ${#FAILED_STEPS[@]} -eq 0 ] && success "依赖修复完成" || { warn "部分修复失败"; show_failure_report; }
  systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
# 功能：卸载 - 保留数据
# ═══════════════════════════════════════════════════════════
do_uninstall_keep_data() {
  echo ""
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${YELLOW}║     卸载（保留数据）                          ║${NC}"
  echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  echo -e "  ${CYAN}将保留:${NC}  ${target_dir}/data, ${target_dir}/.env"
  echo -e "  ${YELLOW}将删除:${NC}  systemd 服务, 代码和 node_modules, 系统用户, Swap"
  echo ""

  if ! confirm "确认执行？"; then return 0; fi

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  local backup_dir="${target_dir}/data_backup_$(date '+%Y%m%d_%H%M%S')"
  [ -d "${target_dir}/data" ] && { mkdir -p "${backup_dir}"; cp -a "${target_dir}/data/." "${backup_dir}/" 2>/dev/null || true; }

  local temp_data="/tmp/metapi_data_$$" temp_env="/tmp/metapi_env_$$"
  [ -d "${target_dir}/data" ] && mv "${target_dir}/data" "${temp_data}"
  [ -f "${target_dir}/.env" ] && cp -a "${target_dir}/.env" "${temp_env}"

  rm -rf "${target_dir:?}"/* "${target_dir}"/.[!.]* 2>/dev/null || true
  mkdir -p "${target_dir}"
  [ -d "${temp_data}" ] && mv "${temp_data}" "${target_dir}/data"
  [ -f "${temp_env}" ] && mv "${temp_env}" "${target_dir}/.env"

  rm -f "${SERVICE_FILE}"; systemctl daemon-reload 2>/dev/null || true
  if command -v pm2 &>/dev/null && pm2 describe "${APP_NAME}" &>/dev/null 2>&1; then pm2 delete "${APP_NAME}" 2>/dev/null || true; pm2 save 2>/dev/null || true; fi
  id "${APP_USER}" &>/dev/null && userdel "${APP_USER}" 2>/dev/null || true

  [ -f "${SWAP_FILE}" ] && { swapoff "${SWAP_FILE}" 2>/dev/null || true; rm -f "${SWAP_FILE}"; sed -i "\|${SWAP_FILE}|d" /etc/fstab; }
  rm -f "${SYSCTL_CONF}" "${MARKER_FILE}"

  echo ""
  success "卸载完成（数据已保留）"
  echo -e "  数据目录: ${CYAN}${target_dir}/data${NC}"
  echo -e "  配置文件: ${CYAN}${target_dir}/.env${NC}"
}

# ═══════════════════════════════════════════════════════════
# 功能：卸载 - 完整卸载
# ═══════════════════════════════════════════════════════════
do_uninstall_full() {
  echo ""
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║       完整卸载（不保留数据）                   ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${RED}警告：此操作将删除所有 Metapi 相关数据，不可恢复！${NC}"
  echo ""

  if ! confirm "确认「完整卸载」？所有数据将丢失！"; then return 0; fi
  echo ""
  read -rp "请输入 'DELETE ALL' 确认: " confirm_text
  [ "$confirm_text" != "DELETE ALL" ] && { info "已取消"; return 0; }

  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"; systemctl daemon-reload 2>/dev/null || true

  if command -v pm2 &>/dev/null && pm2 describe "${APP_NAME}" &>/dev/null 2>&1; then pm2 delete "${APP_NAME}" 2>/dev/null || true; pm2 save 2>/dev/null || true; fi

  rm -rf "${target_dir}"
  id "${APP_USER}" &>/dev/null && userdel -r "${APP_USER}" 2>/dev/null || true
  rm -rf "/home/${APP_USER}"

  [ -f "${SWAP_FILE}" ] && { swapoff "${SWAP_FILE}" 2>/dev/null || true; rm -f "${SWAP_FILE}"; sed -i "\|${SWAP_FILE}|d" /etc/fstab; }
  rm -f "${SYSCTL_CONF}"; rm -rf "${LOG_DIR}"; rm -f /tmp/metapi_* /tmp/.metapi_custom_* 2>/dev/null || true

  echo ""
  warn "Node.js 未卸载（可能被其他应用依赖），如需卸载: apt-get remove --purge nodejs"
  success "完整卸载完成"
}

# ═══════════════════════════════════════════════════════════
# 卸载菜单
# ═══════════════════════════════════════════════════════════
menu_uninstall() {
  while true; do
    echo ""
    echo -e "${BOLD}  卸载选项${NC}"
    separator
    echo -e "  ${GREEN}1${NC}) 保留数据卸载"
    echo -e "  ${RED}2${NC}) 完整卸载（不可恢复）"
    echo -e "  ${BLUE}0${NC}) 返回上级"
    echo ""
    read -rp "请选择 [0-2]: " uninstall_choice
    case "$uninstall_choice" in
      1) do_uninstall_keep_data ;;
      2) do_uninstall_full ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════════════════════════
show_banner() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║                                                      ║${NC}"
  echo -e "${BOLD}${CYAN}║     __  __       _   _ ___ ___ ___                    ║${NC}"
  echo -e "${BOLD}${CYAN}║    |  \\/  | __ _| |_| |_ _| _ ) _ \\                   ║${NC}"
  echo -e "${BOLD}${CYAN}║    | |\\/| |/ _\` |  _  || || _ \\|  _/                  ║${NC}"
  echo -e "${BOLD}${CYAN}║    |_|  |_|\\__,_|\\_,_|___|___/_|                      ║${NC}"
  echo -e "${BOLD}${CYAN}║                                                      ║${NC}"
  echo -e "${BOLD}${CYAN}║     AI API 聚合网关 · 部署管理脚本 v3                 ║${NC}"
  echo -e "${BOLD}${CYAN}║     预编译下载 · 源码编译 · 智能冲突解决              ║${NC}"
  echo -e "${BOLD}${CYAN}║                                                      ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
}

show_main_menu() {
  echo ""
  separator
  echo -e "${BOLD}  主菜单${NC}"
  separator

  if [ -f "${MARKER_FILE}" ]; then
    local install_time; install_time=$(grep '^install_time' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    local install_port; install_port=$(grep '^port' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    local install_mode; install_mode=$(grep '^install_mode' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    echo -e "  安装状态: ${GREEN}已安装${NC} (${install_time})"
    echo -e "  安装模式: ${CYAN}${install_mode:-未知}${NC}"
    echo -e "  运行端口: ${CYAN}${install_port:-${DEFAULT_PORT}}${NC}"
  else
    echo -e "  安装状态: ${YELLOW}未安装${NC}"
  fi

  if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
    echo -e "  服务状态: ${GREEN}运行中${NC}"
  elif [ -f "${SERVICE_FILE}" ]; then
    echo -e "  服务状态: ${RED}已停止${NC}"
  else
    echo -e "  服务状态: ${CYAN}未配置${NC}"
  fi

  local mem_avail; mem_avail=$(get_available_memory_mb)
  local disk_avail; disk_avail=$(check_disk_space "/opt" 0)
  echo -e "  内存可用: ${CYAN}${mem_avail}MB${NC}  磁盘可用: ${CYAN}${disk_avail}MB${NC}"

  echo ""
  echo -e "  ${GREEN}1${NC}) 新装"
  echo -e "  ${YELLOW}2${NC}) 依赖修复"
  echo -e "  ${RED}3${NC}) 卸载"
  echo -e "  ${BLUE}4${NC}) 退出"
  echo ""
}

main() {
  preflight_check
  show_banner

  while true; do
    show_main_menu
    read -rp "请选择 [1-4]: " choice
    case "$choice" in
      1) do_install ;;
      2) do_repair ;;
      3) menu_uninstall ;;
      4) info "再见！"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
    press_any_key
  done
}

main "$@"
