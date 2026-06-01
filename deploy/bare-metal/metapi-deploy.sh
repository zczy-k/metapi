#!/usr/bin/env bash
#
# ╔════════════════════════════════════════════════════════════╗
# ║  Metapi 部署管理脚本 v2 (Ubuntu 22.04)                    ║
# ║  适用于 2核1G 及以下低配置服务器                            ║
# ║  支持: 冲突自动解决 / 智能诊断 / 详细失败报告              ║
# ╚════════════════════════════════════════════════════════════╝
#
# 用法: sudo bash metapi-deploy.sh

set -uo pipefail
# 注意: 不使用 set -e，由 step_wrapper 统一处理错误

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
readonly DEFAULT_PORT=4000
readonly MARKER_FILE="${APP_DIR}/.metapi_installed"
readonly MARKER_VERSION="2"
readonly SWAP_FILE="/swapfile_metapi"
readonly SYSCTL_CONF="/etc/sysctl.d/99-metapi.conf"

# 运行时变量（可被冲突解决逻辑修改）
ACTUAL_PORT="${DEFAULT_PORT}"

# 安装步骤追踪
declare -a COMPLETED_STEPS=()
declare -a FAILED_STEPS=()

# ═══════════════════════════════════════════════════════════
# 颜色
# ═══════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════
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

  # 1. 失败步骤
  echo ""
  echo -e "${BOLD}  失败的步骤:${NC}"
  for step in "${FAILED_STEPS[@]}"; do
    echo -e "    ${RED}✗${NC} ${step}"
  done

  # 2. 已完成的步骤
  if [ ${#COMPLETED_STEPS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BOLD}  已完成的步骤:${NC}"
    for step in "${COMPLETED_STEPS[@]}"; do
      echo -e "    ${GREEN}✓${NC} ${step}"
    done
  fi

  # 3. 系统资源
  echo ""
  echo -e "${BOLD}  系统状态:${NC}"
  echo -e "    内存:        $(free -h 2>/dev/null | awk '/Mem:/{print $3 " 已用 / " $2 " 总计"}' || echo '未知')"
  echo -e "    磁盘:        $(df -h "${APP_DIR:-/opt}" 2>/dev/null | awk 'NR==2{print $3 " 已用 / " $2 " 总计 (" $5 " 使用率)"}' || echo '未知')"
  echo -e "    CPU 负载:    $(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo '未知')"

  # 4. 日志位置
  echo ""
  echo -e "${BOLD}  日志文件:${NC}"
  echo -e "    部署日志:    ${CYAN}${LOG_FILE}${NC}"
  [ -f "${BUILD_LOG}" ] && echo -e "    构建日志:    ${CYAN}${BUILD_LOG}${NC}"
  echo -e "    服务日志:    ${CYAN}journalctl -u ${SERVICE_NAME} -n 100 --no-pager${NC}"

  # 5. 常见原因分析
  echo ""
  echo -e "${BOLD}  常见失败原因及解决方案:${NC}"
  echo ""

  # 分析内存
  local mem_available
  mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
  if [ "$mem_available" -lt 200 ]; then
    echo -e "    ${YELLOW}▸ 内存不足${NC}  可用内存仅 ${mem_available}MB"
    echo -e "      解决: 配置 swap 后重试，或关闭其他内存占用服务"
  fi

  # 分析磁盘
  local disk_use_pct
  disk_use_pct=$(df "${APP_DIR:-/opt}" 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}')
  if [ -n "$disk_use_pct" ] && [ "$disk_use_pct" -gt 90 ]; then
    echo -e "    ${YELLOW}▸ 磁盘空间不足${NC}  使用率 ${disk_use_pct}%"
    echo -e "      解决: 清理磁盘空间，至少需要 500MB 可用空间"
  fi

  # 检查网络
  if ! curl -sf --connect-timeout 5 https://github.com >/dev/null 2>&1; then
    echo -e "    ${YELLOW}▸ 网络连接异常${NC}  无法访问 github.com"
    echo -e "      解决: 检查网络和 DNS，或设置代理: export https_proxy=http://proxy:port"
  fi

  # 检查 npm 构建日志
  if [ -f "${BUILD_LOG}" ]; then
    if grep -qi "error\|fatal\|EACCES\|ENOMEM" "${BUILD_LOG}" 2>/dev/null; then
      echo -e "    ${YELLOW}▸ 构建过程有错误${NC}"
      echo -e "      查看: tail -100 ${BUILD_LOG}"
    fi
  fi

  # 检查 better-sqlite3
  if [ -d "${APP_DIR}/node_modules" ] && [ ! -f "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    echo -e "    ${YELLOW}▸ better-sqlite3 原生模块编译失败${NC}"
    echo -e "      解决: 确保安装了 python3 make g++，然后执行「依赖修复」"
  fi

  echo ""
  echo -e "  ${CYAN}建议: 修复上述问题后，选择「2) 依赖修复」继续，无需从头开始${NC}"
  echo ""
}

# ═══════════════════════════════════════════════════════════
# 前置检查
# ═══════════════════════════════════════════════════════════
preflight_check() {
  # 检查 root
  if [ "$(id -u)" -ne 0 ]; then
    error "此脚本需要 root 权限运行，请使用: sudo bash $0"
    exit 1
  fi

  # 检查操作系统
  if [ ! -f /etc/os-release ]; then
    error "无法检测操作系统版本"
    exit 1
  fi

  source /etc/os-release
  if [ "$ID" != "ubuntu" ]; then
    warn "此脚本针对 Ubuntu 22.04 优化，当前系统: ${PRETTY_NAME}"
    if ! confirm "是否继续？"; then
      exit 0
    fi
  fi

  if [ -n "${VERSION_ID:-}" ] && [ "$VERSION_ID" != "22.04" ]; then
    warn "此脚本针对 Ubuntu 22.04 优化，当前版本: ${VERSION_ID}"
    if ! confirm "是否继续？"; then
      exit 0
    fi
  fi

  # 创建日志目录
  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  log "INFO" "===== 脚本启动 ====="
}

# ═══════════════════════════════════════════════════════════
# 系统资源检查
# ═══════════════════════════════════════════════════════════
get_memory_mb() {
  awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo
}

get_available_memory_mb() {
  awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo
}

get_memory_limit() {
  local mem
  mem=$(get_memory_mb)
  if [ "$mem" -lt 1024 ]; then
    echo "192"
  elif [ "$mem" -lt 2048 ]; then
    echo "256"
  else
    echo "384"
  fi
}

check_disk_space() {
  local path="${1:-/opt}"
  local needed_mb="${2:-500}"
  local available_kb
  available_kb=$(df -P "${path}" 2>/dev/null | awk 'NR==2{print $4}')
  local available_mb=$(( available_kb / 1024 ))
  echo "$available_mb"
}

# ═══════════════════════════════════════════════════════════
# 网络连通性检测
# ═══════════════════════════════════════════════════════════
check_network() {
  local target="${1:-https://github.com}"
  local timeout="${2:-10}"

  if curl -sf --connect-timeout "$timeout" --max-time "$timeout" "$target" >/dev/null 2>&1; then
    return 0
  else
    # 尝试 DNS 解析
    if ! host github.com >/dev/null 2>&1 && ! nslookup github.com >/dev/null 2>&1; then
      error "DNS 解析失败，无法解析 github.com"
      return 2
    fi
    error "无法连接到 ${target}，请检查网络或设置代理"
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════
# 端口冲突检测与自动解决
# ═══════════════════════════════════════════════════════════
check_port_conflict() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} "
}

get_port_user() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "未知"
}

find_available_port() {
  local start_port="$1"
  local max_tries=100
  local port="$start_port"

  while [ $max_tries -gt 0 ]; do
    if ! check_port_conflict "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
    max_tries=$((max_tries - 1))
  done

  echo "0"
  return 1
}

resolve_port_conflict() {
  local port="${ACTUAL_PORT}"

  if ! check_port_conflict "$port"; then
    # 无冲突
    ACTUAL_PORT="$port"
    return 0
  fi

  # 有冲突
  local conflict_proc
  conflict_proc=$(get_port_user "$port")

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
        local new_port
        new_port=$(find_available_port $((port + 1)))
        if [ "$new_port" = "0" ]; then
          error "未找到可用端口"
          return 1
        fi
        info "自动选择端口: ${new_port}"
        ACTUAL_PORT="$new_port"
        return 0
        ;;
      2)
        warn "即将停止进程: ${conflict_proc}"
        if confirm "确认停止？这可能影响其他服务"; then
          # 尝试找到并停止占用的进程
          local pid
          pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
          if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null && sleep 2
            if check_port_conflict "$port"; then
              kill -9 "$pid" 2>/dev/null && sleep 1
            fi
            if ! check_port_conflict "$port"; then
              success "端口 ${port} 已释放"
              ACTUAL_PORT="$port"
              return 0
            fi
          fi
          error "无法释放端口 ${port}，请手动处理"
          return 1
        fi
        ;;
      3)
        while true; do
          read -rp "请输入端口号 (1024-65535): " manual_port
          if [[ "$manual_port" =~ ^[0-9]+$ ]] && [ "$manual_port" -ge 1024 ] && [ "$manual_port" -le 65535 ]; then
            if check_port_conflict "$manual_port"; then
              warn "端口 ${manual_port} 仍被占用"
              continue
            fi
            ACTUAL_PORT="$manual_port"
            success "使用端口: ${ACTUAL_PORT}"
            return 0
          fi
          warn "无效端口号"
        done
        ;;
      0)
        info "已取消"
        return 1
        ;;
      *)
        warn "无效选项"
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════
# 路径冲突检测与自动解决
# ═══════════════════════════════════════════════════════════
resolve_path_conflicts() {
  # 1. 安装目录冲突
  if [ -d "${APP_DIR}" ]; then
    local dir_owner
    dir_owner=$(stat -c '%U:%G' "${APP_DIR}" 2>/dev/null || echo "unknown")
    local is_empty
    is_empty=$(find "${APP_DIR}" -maxdepth 1 -not -name "$(basename "${APP_DIR}")" | wc -l)

    if [ "$is_empty" -le 0 ]; then
      # 空目录，直接删除
      info "安装目录 ${APP_DIR} 为空，自动清理"
      rmdir "${APP_DIR}" 2>/dev/null || rm -rf "${APP_DIR}"
      return
    fi

    if [ -f "${MARKER_FILE}" ]; then
      # 之前安装的目录
      warn "检测到之前的安装目录 ${APP_DIR}"
      return
    fi

    # 非本脚本创建的目录
    echo ""
    warn "安装目录 ${APP_DIR} 已存在且非 Metapi 创建 (owner: ${dir_owner})"
    echo ""
    echo -e "  ${BOLD}冲突解决选项:${NC}"
    echo -e "    ${GREEN}1${NC}) 备份后使用（将现有目录重命名为 ${APP_DIR}.bak）"
    echo -e "    ${YELLOW}2${NC}) 直接覆盖（删除现有目录内容）"
    echo -e "    ${BLUE}3${NC}) 更改安装路径（使用其他目录）"
    echo -e "    ${RED}0${NC}) 取消安装"
    echo ""

    read -rp "请选择 [0-3]: " dir_choice
    case "$dir_choice" in
      1)
        local backup_path="${APP_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        info "备份 ${APP_DIR} → ${backup_path}"
        mv "${APP_DIR}" "${backup_path}"
        mkdir -p "${APP_DIR}"
        ;;
      2)
        warn "删除 ${APP_DIR} 中的内容..."
        rm -rf "${APP_DIR:?}"/*
        rm -rf "${APP_DIR}"/.[!.]* 2>/dev/null || true
        ;;
      3)
        read -rp "请输入新的安装路径: " new_dir
        if [ -n "$new_dir" ] && [ ! -e "$new_dir" ]; then
          # 修改全局变量（通过文件间接实现）
          echo "$new_dir" > /tmp/.metapi_custom_dir
          mkdir -p "$new_dir"
        else
          error "路径无效或已存在"
          return 1
        fi
        ;;
      0) return 1 ;;
      *) warn "无效选项"; return 1 ;;
    esac
  fi

  # 2. 检查 Node.js PATH 冲突
  if command -v node &>/dev/null; then
    local node_path
    node_path=$(which node)
    # 检查是否有多个 node（nvm 和 nodesource 冲突）
    local node_count
    node_count=$(which -a node 2>/dev/null | wc -l)
    if [ "$node_count" -gt 1 ]; then
      warn "检测到多个 Node.js 安装，使用: ${node_path}"
      warn "  如果构建失败，可能是 Node.js 版本冲突，请检查 PATH"
    fi
  fi

  # 3. 检查 npm 全局目录权限
  local npm_prefix
  npm_prefix=$(npm config get prefix 2>/dev/null || echo "/usr")
  if [ ! -w "$npm_prefix" ]; then
    warn "npm 全局目录 ${npm_prefix} 不可写，将使用 sudo 安装全局包"
  fi
}

# ═══════════════════════════════════════════════════════════
# 用户冲突检测与自动解决
# ═══════════════════════════════════════════════════════════
resolve_user_conflict() {
  if ! id "${APP_USER}" &>/dev/null; then
    return 0  # 无冲突
  fi

  local user_home
  user_home=$(getent passwd "${APP_USER}" | cut -d: -f6)

  if [ "$user_home" = "${APP_DIR}" ]; then
    # 是之前安装的同一用户，无冲突
    info "用户 '${APP_USER}' 已存在（home: ${APP_DIR}）"
    return 0
  fi

  # 用户存在但 home 不同 - 冲突
  echo ""
  warn "系统用户 '${APP_USER}' 已存在但 home 目录不同"
  warn "  当前 home: ${user_home}"
  warn "  期望 home: ${APP_DIR}"
  echo ""
  echo -e "  ${BOLD}冲突解决选项:${NC}"
  echo -e "    ${GREEN}1${NC}) 修改用户 home 目录为 ${APP_DIR}（推荐）"
  echo -e "    ${YELLOW}2${NC}) 使用其他用户名运行 Metapi"
  echo -e "    ${RED}0${NC}) 取消安装"
  echo ""

  read -rp "请选择 [0-2]: " user_choice
  case "$user_choice" in
    1)
      usermod -d "${APP_DIR}" -m "${APP_USER}" 2>/dev/null || \
        usermod -d "${APP_DIR}" "${APP_USER}"
      success "已修改用户 home 目录"
      ;;
    2)
      read -rp "请输入新的用户名: " new_user
      if [ -n "$new_user" ] && ! id "$new_user" &>/dev/null; then
        echo "$new_user" > /tmp/.metapi_custom_user
        success "将使用用户: ${new_user}"
      else
        error "用户名无效或已存在"
        return 1
      fi
      ;;
    0) return 1 ;;
    *) warn "无效选项"; return 1 ;;
  esac
}

# ═══════════════════════════════════════════════════════════
# 环境检测（完整版）
# ═══════════════════════════════════════════════════════════
check_environment() {
  echo ""
  separator
  echo -e "${BOLD}  环境检测${NC}"
  separator

  local found_issues=0

  # 1. 系统用户
  if id "${APP_USER}" &>/dev/null; then
    local user_home
    user_home=$(getent passwd "${APP_USER}" | cut -d: -f6)
    if [ "$user_home" != "${APP_DIR}" ]; then
      warn "用户 '${APP_USER}' 存在但 home 不匹配 (当前: ${user_home})"
      found_issues=1
    else
      info "用户 '${APP_USER}' 已存在（匹配） ✓"
    fi
  else
    info "用户 '${APP_USER}' 不存在 ✓"
  fi

  # 2. 安装目录
  if [ -d "${APP_DIR}" ]; then
    if [ -f "${MARKER_FILE}" ]; then
      warn "安装目录 ${APP_DIR} 存在，含安装标记"
    else
      warn "安装目录 ${APP_DIR} 已存在（非 Metapi 创建）"
    fi
    found_issues=1
  else
    info "安装目录不存在 ✓"
  fi

  # 3. systemd 服务
  if [ -f "${SERVICE_FILE}" ]; then
    warn "systemd 服务文件 ${SERVICE_FILE} 已存在"
    found_issues=1
  else
    info "systemd 服务文件不存在 ✓"
  fi

  if systemctl is-enabled "${SERVICE_NAME}" &>/dev/null; then
    warn "systemd 服务 '${SERVICE_NAME}' 已启用"
    found_issues=1
  else
    info "systemd 服务未启用 ✓"
  fi

  # 4. 端口
  if check_port_conflict "${DEFAULT_PORT}"; then
    local proc
    proc=$(get_port_user "${DEFAULT_PORT}")
    warn "端口 ${DEFAULT_PORT} 被 '${proc}' 占用"
    found_issues=1
  else
    info "端口 ${DEFAULT_PORT} 未被占用 ✓"
  fi

  # 5. Node.js
  if command -v node &>/dev/null; then
    local node_ver
    node_ver=$(node -v)
    local node_major
    node_major=$(echo "$node_ver" | sed 's/v//' | cut -d. -f1)
    if [ "$node_major" -ge "$NODE_MAJOR" ]; then
      success "Node.js ${node_ver} ✓"
    else
      warn "Node.js ${node_ver} 版本过低 (需要 >= ${NODE_MAJOR})"
      found_issues=1
    fi
  else
    info "Node.js 未安装"
  fi

  # 6. 磁盘空间
  local available_mb
  available_mb=$(check_disk_space "/opt" 500)
  if [ "$available_mb" -lt 500 ]; then
    warn "磁盘可用空间仅 ${available_mb}MB（建议 >= 500MB）"
    found_issues=1
  else
    info "磁盘可用空间 ${available_mb}MB ✓"
  fi

  # 7. 网络
  if ! check_network "https://github.com" 5; then
    found_issues=1
  else
    info "网络连通性 ✓"
  fi

  # 8. PM2
  if command -v pm2 &>/dev/null; then
    if pm2 describe "${APP_NAME}" &>/dev/null 2>&1; then
      warn "PM2 中存在 '${APP_NAME}' 进程"
      found_issues=1
    fi
  fi

  # 9. 数据目录
  if [ -d "${DATA_DIR}" ]; then
    local data_size
    data_size=$(du -sh "${DATA_DIR}" 2>/dev/null | cut -f1)
    warn "数据目录 ${DATA_DIR} 已存在 (${data_size})"
    found_issues=1
  fi

  echo ""
  if [ "$found_issues" -eq 1 ]; then
    warn "检测到冲突或残留项，安装时将自动处理"
  else
    success "环境干净，无冲突"
  fi

  return "$found_issues"
}

# ═══════════════════════════════════════════════════════════
# 清理残留（智能版）
# ═══════════════════════════════════════════════════════════
cleanup_residuals() {
  info "正在清理残留..."

  # 1. 停止并删除 systemd 服务
  if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
    info "停止 systemd 服务..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  fi
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true

  # 2. 停止 PM2 进程
  if command -v pm2 &>/dev/null; then
    if pm2 describe "${APP_NAME}" &>/dev/null 2>&1; then
      pm2 delete "${APP_NAME}" 2>/dev/null || true
      pm2 save 2>/dev/null || true
    fi
  fi

  # 3. 删除安装标记
  rm -f "${MARKER_FILE}"

  # 4. 清理临时文件
  rm -f /tmp/.metapi_custom_dir /tmp/.metapi_custom_user 2>/dev/null || true

  success "残留清理完成"
}

# ═══════════════════════════════════════════════════════════
# 安装系统依赖
# ═══════════════════════════════════════════════════════════
install_system_deps() {
  info "安装系统依赖..."

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  apt-get update -qq 2>&1 | tail -3 >> "${LOG_FILE}"

  if ! apt-get install -y -qq \
    curl git python3 make g++ ca-certificates gnupg \
    apt-transport-https lsb-release 2>&1; then
    error "系统依赖安装失败"
    # 智能修复: 尝试修复损坏的包
    warn "尝试修复损坏的包..."
    dpkg --configure -a 2>/dev/null
    apt-get install -f -y 2>/dev/null
    apt-get update -qq 2>/dev/null
    if ! apt-get install -y -qq \
      curl git python3 make g++ ca-certificates gnupg \
      apt-transport-https lsb-release 2>&1; then
      error "系统依赖安装仍然失败，请手动检查 apt"
      return 1
    fi
  fi

  success "系统依赖安装完成"
}

# ═══════════════════════════════════════════════════════════
# 安装 Node.js (NodeSource) + 冲突处理
# ═══════════════════════════════════════════════════════════
install_node() {
  if command -v node &>/dev/null; then
    local current_major
    current_major=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$current_major" -ge "$NODE_MAJOR" ]; then
      success "Node.js $(node -v) 已满足要求"
      return 0
    fi
    warn "当前 Node.js $(node -v) 版本过低，需要升级到 ${NODE_MAJOR}+"
  fi

  info "安装 Node.js ${NODE_MAJOR}..."

  # 检查是否有 nvm 安装的 Node（会冲突）
  if [ -d "${HOME}/.nvm" ]; then
    warn "检测到 nvm 安装，可能与 NodeSource 冲突"
    if confirm "是否跳过 nvm 使用 NodeSource 安装？"; then
      export PATH=$(echo "$PATH" | sed "s|${HOME}/.nvm/versions/node/[^:]*:||g")
    fi
  fi

  # NodeSource 安装（带重试）
  local retry=0
  local max_retries=3
  while [ $retry -lt $max_retries ]; do
    if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - 2>&1; then
      break
    fi
    retry=$((retry + 1))
    warn "NodeSource 设置失败 (尝试 $retry/$max_retries)"
    sleep 5
  done

  if [ $retry -ge $max_retries ]; then
    error "NodeSource 安装失败，尝试备选方案..."
    # 备选: 使用 Node.js 官方二进制
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "x64")
    local node_url="https://nodejs.org/dist/v${NODE_MAJOR}.0.0/node-v${NODE_MAJOR}.0.0-linux-${arch}.tar.xz"
    warn "尝试从官方下载 Node.js..."
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
# 创建隔离用户
# ═══════════════════════════════════════════════════════════
create_user() {
  # 检查自定义用户
  local user="${APP_USER}"
  if [ -f /tmp/.metapi_custom_user ]; then
    user=$(cat /tmp/.metapi_custom_user)
  fi

  if id "${user}" &>/dev/null; then
    info "用户 '${user}' 已存在"
    return 0
  fi

  info "创建隔离用户 '${user}'..."
  useradd -r -m -s /bin/bash -d "${APP_DIR}" "${user}"

  # 锁定密码登录（仅允许 su 切换）
  passwd -l "${user}" 2>/dev/null || true

  success "用户 '${user}' 创建完成"
}

# ═══════════════════════════════════════════════════════════
# 克隆代码并构建（智能版）
# ═══════════════════════════════════════════════════════════
clone_and_build() {
  local target_dir="${APP_DIR}"
  if [ -f /tmp/.metapi_custom_dir ]; then
    target_dir=$(cat /tmp/.metapi_custom_dir)
  fi

  info "克隆代码到 ${target_dir}..."

  if [ -d "${target_dir}/.git" ]; then
    info "代码已存在，拉取最新版本..."
    cd "${target_dir}"
    git fetch --all 2>&1 | tail -3
    git reset --hard origin/main 2>&1 | tail -3
  else
    # 网络检测
    if ! check_network "${REPO_URL}" 10; then
      error "无法访问 GitHub，请检查网络或设置代理"
      echo -e "  设置代理: ${CYAN}export https_proxy=http://your-proxy:port${NC}"
      echo -e "  设置代理后重新运行脚本"
      return 1
    fi

    mkdir -p "${target_dir}"
    git clone "${REPO_URL}" "${target_dir}" 2>&1 | tail -5
    cd "${target_dir}"
  fi

  # ── npm install（带智能重试） ──
  info "安装项目依赖..."
  local npm_retry=0
  local npm_max_retries=3

  while [ $npm_retry -lt $npm_max_retries ]; do
    npm_retry=$((npm_retry + 1))

    if npm ci --ignore-scripts --no-audit --no-fund 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
      break
    fi

    warn "npm ci 失败 (尝试 ${npm_retry}/${npm_max_retries})"

    # 智能诊断
    if grep -qi "EACCES" "${BUILD_LOG}" 2>/dev/null; then
      warn "检测到权限问题，修复 npm 缓存目录..."
      mkdir -p "${target_dir}/.npm"
      chown -R "$(whoami)" "${target_dir}/.npm" 2>/dev/null
      npm cache clean --force 2>/dev/null
    fi

    if grep -qi "ENOTFOUND\|ECONNREFUSED\|ETIMEDOUT" "${BUILD_LOG}" 2>/dev/null; then
      warn "检测到网络问题，检查网络连接..."
      if ! check_network "https://registry.npmjs.org" 5; then
        warn "npm registry 不可达，尝试使用镜像..."
        npm config set registry https://registry.npmmirror.com 2>/dev/null
      fi
    fi

    if [ $npm_retry -lt $npm_max_retries ]; then
      info "5秒后重试..."
      sleep 5
    fi
  done

  if [ $npm_retry -ge $npm_max_retries ]; then
    error "npm ci 多次重试后仍然失败，请查看构建日志: ${BUILD_LOG}"
    return 1
  fi

  # ── 重建原生模块 ──
  info "重建原生模块..."
  if ! npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
    warn "原生模块重建出现问题，尝试单独修复..."

    # better-sqlite3 常见问题修复
    if [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
      info "尝试修复 better-sqlite3..."
      cd "${target_dir}/node_modules/better-sqlite3"
      npm run build-release 2>&1 | tail -5 >> "${BUILD_LOG}" || true
      cd "${target_dir}"
    fi
  fi

  # ── 构建前端 ──
  info "构建前端..."
  if ! npm run build:web 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
    error "前端构建失败，查看日志: ${BUILD_LOG}"

    # 尝试修复: 清理缓存重试
    warn "清理缓存后重试..."
    rm -rf "${target_dir}/node_modules/.vite" "${target_dir}/node_modules/.cache"
    if ! npm run build:web 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
      error "前端构建仍然失败"
      return 1
    fi
  fi

  # ── 构建后端 ──
  info "构建后端..."
  if ! npm run build:server 2>&1 | tee -a "${BUILD_LOG}" | tail -5; then
    error "后端构建失败，查看日志: ${BUILD_LOG}"
    return 1
  fi

  # ── 清理开发依赖 ──
  info "清理开发依赖..."
  npm prune --omit=dev --no-audit --no-fund 2>&1 | tail -3 >> "${BUILD_LOG}"

  # ── 构建后验证 ──
  if [ ! -f "${target_dir}/dist/server/index.js" ]; then
    error "构建产物验证失败: dist/server/index.js 不存在"
    return 1
  fi

  if [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
    warn "better-sqlite3 原生模块未正确编译"
    warn "服务启动时可能出错，可执行「依赖修复」尝试解决"
  fi

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
    # 读取当前端口
    local configured_port
    configured_port=$(grep "^PORT=" "${env_file}" 2>/dev/null | cut -d= -f2)
    if [ -n "$configured_port" ]; then
      ACTUAL_PORT="$configured_port"
    fi
    return 0
  fi

  info "配置环境变量..."

  local auth_token proxy_token

  echo ""
  echo -e "${CYAN}请设置 Metapi 的认证令牌：${NC}"
  echo -e "${YELLOW}  AUTH_TOKEN   = 管理后台登录令牌${NC}"
  echo -e "${YELLOW}  PROXY_TOKEN  = 下游客户端调用 API 的令牌${NC}"
  echo ""

  while true; do
    read -rp "AUTH_TOKEN: " auth_token
    if [ -z "$auth_token" ] || [ "$auth_token" = "change-me-admin-token" ]; then
      warn "请设置一个安全的令牌，不能为空或使用默认值"
      continue
    fi
    break
  done

  while true; do
    read -rp "PROXY_TOKEN: " proxy_token
    if [ -z "$proxy_token" ] || [ "$proxy_token" = "change-me-proxy-sk-token" ]; then
      warn "请设置一个安全的令牌，不能为空或使用默认值"
      continue
    fi
    break
  done

  local mem_limit
  mem_limit=$(get_memory_limit)

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
EOF

  chmod 600 "${env_file}"
  success ".env 配置完成 (端口: ${ACTUAL_PORT})"
}

# ═══════════════════════════════════════════════════════════
# 配置 Swap（低内存服务器）
# ═══════════════════════════════════════════════════════════
configure_swap() {
  local total_mem
  total_mem=$(get_memory_mb)

  if [ "$total_mem" -ge 2048 ]; then
    info "内存充足 (${total_mem}MB)，无需配置 Swap"
    return 0
  fi

  local current_swap_mb
  current_swap_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)

  if [ "$current_swap_mb" -ge 1024 ]; then
    info "Swap 已有 ${current_swap_mb}MB，满足要求"
    return 0
  fi

  echo ""
  warn "内存仅 ${total_mem}MB，建议配置 Swap 以防 OOM"

  if ! confirm "是否创建 1GB Swap？"; then
    return 0
  fi

  if [ -f "${SWAP_FILE}" ]; then
    swapoff "${SWAP_FILE}" 2>/dev/null || true
    rm -f "${SWAP_FILE}"
  fi

  info "创建 1GB swap 文件..."
  if ! fallocate -l 1G "${SWAP_FILE}" 2>/dev/null; then
    # fallocate 可能不支持，使用 dd
    warn "fallocate 不可用，使用 dd 创建..."
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=1024 status=progress
  fi

  chmod 600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}"
  swapon "${SWAP_FILE}"

  if ! grep -q "${SWAP_FILE}" /etc/fstab; then
    echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
  fi

  # 降低 swappiness，减少对其他应用的影响
  sysctl vm.swappiness=10 >/dev/null
  if ! grep -q "vm.swappiness" "${SYSCTL_CONF}" 2>/dev/null; then
    echo "vm.swappiness=10" > "${SYSCTL_CONF}"
  fi

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

  local node_path
  node_path=$(which node)
  local mem_limit
  mem_limit=$(get_memory_limit)

  # 构建环境变量段落
  local env_block=""
  if [ -f "${env_file}" ]; then
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[[:space:]]*#.*$ ]] && continue
      [[ -z "$key" ]] && continue
      key=$(echo "$key" | xargs)
      [[ -z "$key" ]] && continue
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
  local target_data="${target_dir}/data"
  local env_file="${target_dir}/.env"

  info "设置文件权限..."

  mkdir -p "${target_data}"
  chown -R "${target_user}:${target_user}" "${target_dir}"
  chmod 700 "${target_dir}"
  chmod 600 "${env_file}" 2>/dev/null
  chmod 700 "${target_data}"
  chown "${target_user}:${target_user}" "${env_file}" 2>/dev/null

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
EOF
  chown "${target_user}:${target_user}" "${MARKER_FILE}" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# 启动服务（带智能诊断）
# ═══════════════════════════════════════════════════════════
start_service() {
  info "启动 Metapi 服务..."

  systemctl start "${SERVICE_NAME}"

  # 等待启动
  local retry=0
  while [ $retry -lt 20 ]; do
    if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
      success "Metapi 服务启动成功"
      return 0
    fi
    retry=$((retry + 1))
    sleep 1
  done

  # 启动失败，智能诊断
  error "服务启动失败，正在诊断..."

  echo ""
  echo -e "${BOLD}  服务状态:${NC}"
  systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true

  echo ""
  echo -e "${BOLD}  最近日志:${NC}"
  journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null || true

  # 常见原因诊断
  echo ""
  echo -e "${BOLD}  智能诊断:${NC}"

  # 1. 端口冲突
  if check_port_conflict "${ACTUAL_PORT}"; then
    local conflict_proc
    conflict_proc=$(get_port_user "${ACTUAL_PORT}")
    warn "▸ 端口 ${ACTUAL_PORT} 被进程 '${conflict_proc}' 占用"
    echo -e "  解决: 修改 ${ENV_FILE} 中的 PORT 值，然后执行: systemctl restart ${SERVICE_NAME}"
  fi

  # 2. 数据库迁移失败
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "migrate\|SQLITE\|database"; then
    warn "▸ 数据库迁移可能失败"
    echo -e "  解决: 检查数据目录权限和磁盘空间"
    echo -e "    ls -la ${DATA_DIR}"
    echo -e "    df -h ${DATA_DIR}"
  fi

  # 3. 模块加载失败
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "Cannot find module\|MODULE_NOT_FOUND"; then
    warn "▸ 模块加载失败"
    echo -e "  解决: 执行「2) 依赖修复」重新构建"
  fi

  # 4. 原生模块问题
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "better-sqlite3\|native\|\.node"; then
    warn "▸ 原生模块(better-sqlite3)加载失败"
    echo -e "  解决: 确保安装了 python3 make g++，然后执行「依赖修复」"
  fi

  # 5. 内存不足
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "ENOMEM\|out of memory\|killed"; then
    warn "▸ 内存不足 (OOM)"
    echo -e "  解决: 配置 Swap 或降低 NODE_OPTIONS 中的内存限制"
  fi

  # 6. 权限问题
  if journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>/dev/null | grep -qi "EACCES\|permission denied"; then
    warn "▸ 权限问题"
    echo -e "  解决: 检查文件权限"
    echo -e "    chown -R ${APP_USER}:${APP_USER} ${APP_DIR}"
  fi

  echo ""
  echo -e "  查看完整日志: ${CYAN}journalctl -u ${SERVICE_NAME} -n 100 --no-pager${NC}"
  echo ""

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

  # 检测防火墙类型
  local fw_type="未知"
  local fw_active=false

  if command -v ufw &>/dev/null; then
    fw_type="ufw"
    if ufw status 2>/dev/null | grep -q "active"; then
      fw_active=true
    fi
  elif command -v firewall-cmd &>/dev/null; then
    fw_type="firewalld"
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
      fw_active=true
    fi
  elif command -v iptables &>/dev/null; then
    fw_type="iptables"
    if iptables -L -n 2>/dev/null | grep -q "INPUT"; then
      fw_active=true
    fi
  fi

  if [ "$fw_active" = true ]; then
    echo -e "  ${YELLOW}检测到防火墙: ${fw_type} (已启用)${NC}"
    echo ""
    echo -e "  ${BOLD}执行以下命令开放端口:${NC}"
    echo ""

    case "$fw_type" in
      ufw)
        echo -e "    ${CYAN}ufw allow ${port}/tcp${NC}"
        echo -e "    ${CYAN}ufw reload${NC}"
        ;;
      firewalld)
        echo -e "    ${CYAN}firewall-cmd --permanent --add-port=${port}/tcp${NC}"
        echo -e "    ${CYAN}firewall-cmd --reload${NC}"
        ;;
      iptables)
        echo -e "    ${CYAN}iptables -A INPUT -p tcp --dport ${port} -j ACCEPT${NC}"
        echo -e "    ${CYAN}iptables-save > /etc/iptables/rules.v4${NC}  # 持久化"
        ;;
    esac
  else
    echo -e "  ${GREEN}未检测到活动的防火墙${NC}"
    echo ""
    echo -e "  如果后续启用防火墙，请开放端口 ${CYAN}${port}/tcp${NC}"
    echo ""
    echo -e "  ${BOLD}常用命令:${NC}"
    echo -e "    ${CYAN}ufw allow ${port}/tcp${NC}             (ufw)"
    echo -e "    ${CYAN}firewall-cmd --permanent --add-port=${port}/tcp${NC}  (firewalld)"
  fi

  # 云服务器安全组提示
  echo ""
  echo -e "  ${BOLD}${YELLOW}⚠ 如果是云服务器（阿里云/腾讯云/AWS等），还需在安全组中放行端口！${NC}"
  echo -e "  云控制台 → 安全组 → 添加入站规则 → TCP 端口 ${port}"
  echo ""

  # 验证端口是否可达
  if command -v curl &>/dev/null; then
    info "验证本地端口连通性..."
    if curl -sf --connect-timeout 3 "http://127.0.0.1:${port}" >/dev/null 2>&1; then
      success "端口 ${port} 本地可达 ✓"
    else
      # 可能服务还没完全就绪
      sleep 2
      if curl -sf --connect-timeout 3 "http://127.0.0.1:${port}" >/dev/null 2>&1; then
        success "端口 ${port} 本地可达 ✓"
      else
        warn "端口 ${port} 本地暂未响应（服务可能仍在启动中）"
      fi
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

  # 步骤 0: 资源预检
  separator
  info "预检: 磁盘空间..."
  local avail_mb
  avail_mb=$(check_disk_space "/opt" 500)
  if [ "$avail_mb" -lt 500 ]; then
    error "磁盘可用空间仅 ${avail_mb}MB，至少需要 500MB"
    if ! confirm "是否仍要继续？"; then
      return 1
    fi
  fi

  info "预检: 网络连通性..."
  if ! check_network "https://github.com" 10; then
    warn "网络检测未通过，安装过程可能失败"
    echo -e "  如需代理: ${CYAN}export https_proxy=http://your-proxy:port${NC}"
    if ! confirm "是否仍要继续？"; then
      return 1
    fi
  fi

  # 步骤 1: 环境检测
  check_environment
  local env_result=$?

  if [ "$env_result" -ne 0 ]; then
    echo ""
    warn "检测到冲突或残留项"
  fi

  # 冲突解决
  separator
  info "冲突检测与自动解决..."

  if ! resolve_port_conflict; then
    error "端口冲突无法解决，安装取消"
    return 1
  fi

  if ! resolve_path_conflicts; then
    error "路径冲突无法解决，安装取消"
    return 1
  fi

  if ! resolve_user_conflict; then
    error "用户冲突无法解决，安装取消"
    return 1
  fi

  # 如有残留，先清理
  if [ "$env_result" -ne 0 ]; then
    if confirm "是否清理残留后继续安装？"; then
      cleanup_residuals
    else
      error "请先执行卸载操作清理环境"
      return 1
    fi
  fi

  echo ""
  info "冲突解决完成，开始安装..."
  echo ""

  # 步骤 2-9: 逐步安装
  separator
  if ! step_wrapper "安装系统依赖" install_system_deps; then
    show_failure_report
    return 1
  fi

  separator
  if ! step_wrapper "安装 Node.js" install_node; then
    show_failure_report
    return 1
  fi

  separator
  if ! step_wrapper "创建隔离用户" create_user; then
    show_failure_report
    return 1
  fi

  separator
  if ! step_wrapper "克隆代码并构建" clone_and_build; then
    show_failure_report
    return 1
  fi

  separator
  if ! step_wrapper "配置环境变量" configure_env; then
    show_failure_report
    return 1
  fi

  separator
  if ! step_wrapper "配置 Swap" configure_swap; then
    # swap 失败不阻塞安装
    warn "Swap 配置失败，不影响安装，但低内存时可能出现 OOM"
  fi

  separator
  if ! step_wrapper "安装服务并设置权限" _install_service_and_perms; then
    show_failure_report
    return 1
  fi

  separator
  if ! step_wrapper "启动服务" start_service; then
    show_failure_report
    return 1
  fi

  # 完成
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  echo ""
  bold_separator
  echo -e "${BOLD}${GREEN}  安装完成！${NC}"
  bold_separator
  echo ""

  local ip_addr
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')

  echo -e "  访问地址:    ${CYAN}http://${ip_addr}:${ACTUAL_PORT}${NC}"
  echo -e "  管理令牌:    .env 中的 AUTH_TOKEN"
  echo ""
  echo -e "  ${BOLD}常用命令:${NC}"
  echo -e "    ${CYAN}systemctl status ${SERVICE_NAME}${NC}         查看状态"
  echo -e "    ${CYAN}journalctl -u ${SERVICE_NAME} -f${NC}       查看日志"
  echo -e "    ${CYAN}systemctl restart ${SERVICE_NAME}${NC}      重启服务"
  echo -e "    ${CYAN}systemctl stop ${SERVICE_NAME}${NC}         停止服务"
  echo ""
  echo -e "  配置文件:    ${CYAN}${target_dir}/.env${NC}"
  echo -e "  数据目录:    ${CYAN}${target_dir}/data${NC}"
  echo -e "  部署日志:    ${CYAN}${LOG_FILE}${NC}"
  echo ""

  # 防火墙提示
  show_firewall_hint

  # 清理临时文件
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
# 功能：依赖修复（智能版）
# ═══════════════════════════════════════════════════════════
do_repair() {
  COMPLETED_STEPS=()
  FAILED_STEPS=()

  echo ""
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${YELLOW}║          依赖修复                            ║${NC}"
  echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  # 读取安装信息
  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  # 即使没有 marker 也允许修复
  if [ ! -f "${MARKER_FILE}" ] && [ ! -d "${target_dir}" ]; then
    error "未检测到安装记录或安装目录，请先执行新装"
    return 1
  fi

  info "当前环境诊断："
  echo ""

  local issues=0

  # 逐项检查
  echo -e "${BOLD}  [1] Node.js${NC}"
  if ! command -v node &>/dev/null; then
    error "  ✗ Node.js 未安装"
    issues=$((issues + 1))
  else
    local node_major
    node_major=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$node_major" -lt "$NODE_MAJOR" ]; then
      error "  ✗ Node.js 版本过低: $(node -v) (需要 >= ${NODE_MAJOR})"
      issues=$((issues + 1))
    else
      success "  ✓ Node.js $(node -v)"
    fi
  fi

  echo -e "${BOLD}  [2] 系统依赖${NC}"
  for cmd in python3 make g++ git curl; do
    if ! command -v "$cmd" &>/dev/null; then
      error "  ✗ ${cmd} 缺失"
      issues=$((issues + 1))
    else
      success "  ✓ ${cmd}"
    fi
  done

  echo -e "${BOLD}  [3] 安装目录${NC}"
  if [ ! -d "${target_dir}" ]; then
    error "  ✗ 目录不存在: ${target_dir}"
    issues=$((issues + 1))
  else
    success "  ✓ ${target_dir}"
  fi

  echo -e "${BOLD}  [4] 构建产物${NC}"
  if [ ! -f "${target_dir}/dist/server/index.js" ]; then
    error "  ✗ dist/server/index.js 缺失"
    issues=$((issues + 1))
  else
    success "  ✓ dist/server/index.js"
  fi

  echo -e "${BOLD}  [5] 原生模块${NC}"
  for mod in better-sqlite3 sharp esbuild; do
    if [ ! -d "${target_dir}/node_modules/${mod}" ]; then
      error "  ✗ ${mod} 缺失"
      issues=$((issues + 1))
    elif [ "$mod" = "better-sqlite3" ] && [ ! -f "${target_dir}/node_modules/${mod}/build/Release/better_sqlite3.node" ]; then
      error "  ✗ ${mod} 编译产物缺失"
      issues=$((issues + 1))
    else
      success "  ✓ ${mod}"
    fi
  done

  echo -e "${BOLD}  [6] systemd 服务${NC}"
  if [ ! -f "${SERVICE_FILE}" ]; then
    error "  ✗ 服务文件不存在"
    issues=$((issues + 1))
  else
    success "  ✓ 服务文件存在"
    if ! systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
      warn "  ! 服务未运行"
      issues=$((issues + 1))
    else
      success "  ✓ 服务运行中"
    fi
  fi

  echo -e "${BOLD}  [7] 系统用户${NC}"
  if ! id "${APP_USER}" &>/dev/null; then
    error "  ✗ 用户 ${APP_USER} 不存在"
    issues=$((issues + 1))
  else
    success "  ✓ 用户 ${APP_USER}"
  fi

  echo -e "${BOLD}  [8] 配置文件${NC}"
  if [ ! -f "${target_dir}/.env" ]; then
    error "  ✗ .env 不存在"
    issues=$((issues + 1))
  else
    success "  ✓ .env"
  fi

  echo -e "${BOLD}  [9] 端口状态${NC}"
  local configured_port
  configured_port=$(grep "^PORT=" "${target_dir}/.env" 2>/dev/null | cut -d= -f2 || echo "${DEFAULT_PORT}")
  if check_port_conflict "${configured_port}" && ! systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
    error "  ✗ 端口 ${configured_port} 被其他进程占用"
    issues=$((issues + 1))
  else
    success "  ✓ 端口 ${configured_port}"
  fi

  echo ""
  if [ "$issues" -eq 0 ]; then
    success "所有依赖正常，无需修复"
    return 0
  fi

  warn "发现 ${issues} 个问题"
  echo ""
  if ! confirm "是否开始修复？"; then
    return 0
  fi

  # 修复
  echo ""
  step_wrapper "修复系统依赖" install_system_deps || true
  step_wrapper "修复 Node.js" install_node || true
  step_wrapper "修复系统用户" create_user || true

  # 修复构建
  if [ ! -f "${target_dir}/dist/server/index.js" ] || [ ! -d "${target_dir}/node_modules" ]; then
    cd "${target_dir}"
    info "重新构建项目..."
    npm ci --ignore-scripts --no-audit --no-fund 2>&1 | tail -5
    npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund 2>&1 | tail -5
    npm run build:web 2>&1 | tail -5
    npm run build:server 2>&1 | tail -5
    npm prune --omit=dev --no-audit --no-fund 2>&1 | tail -5
  fi

  # 修复原生模块
  if [ -d "${target_dir}/node_modules/better-sqlite3" ]; then
    if [ ! -f "${target_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]; then
      info "重新编译 better-sqlite3..."
      cd "${target_dir}/node_modules/better-sqlite3"
      npm run build-release 2>&1 | tail -5
      cd "${target_dir}"
    fi
  fi

  # 修复 .env
  if [ ! -f "${target_dir}/.env" ]; then
    step_wrapper "修复配置文件" configure_env || true
  fi

  # 修复 systemd
  if [ ! -f "${SERVICE_FILE}" ]; then
    step_wrapper "修复 systemd 服务" install_systemd_service || true
  fi

  # 修复端口冲突
  if check_port_conflict "${configured_port}" && ! systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
    warn "端口 ${configured_port} 被占用，自动解决..."
    ACTUAL_PORT="${configured_port}"
    resolve_port_conflict
    # 更新 .env 中的端口
    sed -i "s/^PORT=.*/PORT=${ACTUAL_PORT}/" "${target_dir}/.env"
  fi

  # 修复权限
  set_permissions

  # 重启服务
  if [ -f "${SERVICE_FILE}" ]; then
    info "重启服务..."
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" || true
  fi

  echo ""
  if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
    success "依赖修复完成"
  else
    warn "部分修复失败，请查看报告"
    show_failure_report
  fi

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

  echo -e "  ${CYAN}将保留:${NC}"
  echo -e "    - 数据目录: ${target_dir}/data"
  echo -e "    - 环境配置: ${target_dir}/.env"
  echo ""
  echo -e "  ${YELLOW}将删除:${NC}"
  echo -e "    - systemd 服务"
  echo -e "    - 代码和 node_modules"
  echo -e "    - 系统用户 ${APP_USER}"
  echo -e "    - Swap 配置（如由脚本创建）"
  echo ""

  if ! confirm "确认执行？"; then
    info "已取消"
    return 0
  fi

  # 停止服务
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  # 备份数据
  local backup_dir="${target_dir}/data_backup_$(date '+%Y%m%d_%H%M%S')"
  if [ -d "${target_dir}/data" ]; then
    info "备份数据到 ${backup_dir}..."
    mkdir -p "${backup_dir}"
    cp -a "${target_dir}/data/." "${backup_dir}/" 2>/dev/null || true
  fi

  # 备份 .env
  if [ -f "${target_dir}/.env" ]; then
    cp -a "${target_dir}/.env" "/tmp/metapi_env_backup_$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
  fi

  # 删除 systemd
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true

  # 删除 PM2
  if command -v pm2 &>/dev/null; then
    pm2 delete "${APP_NAME}" 2>/dev/null || true
    pm2 save 2>/dev/null || true
  fi

  # 保留数据，删除其他
  info "删除安装文件（保留数据和配置）..."
  local temp_data="/tmp/metapi_data_$$"
  local temp_env="/tmp/metapi_env_$$"

  [ -d "${target_dir}/data" ] && mv "${target_dir}/data" "${temp_data}"
  [ -f "${target_dir}/.env" ] && cp -a "${target_dir}/.env" "${temp_env}"

  rm -rf "${target_dir:?}"/* "${target_dir}"/.[!.]* 2>/dev/null || true

  mkdir -p "${target_dir}"
  [ -d "${temp_data}" ] && mv "${temp_data}" "${target_dir}/data"
  [ -f "${temp_env}" ] && mv "${temp_env}" "${target_dir}/.env"

  # 删除用户
  if id "${APP_USER}" &>/dev/null; then
    userdel "${APP_USER}" 2>/dev/null || true
  fi

  # 清理 Swap
  if [ -f "${SWAP_FILE}" ]; then
    info "移除 Swap..."
    swapoff "${SWAP_FILE}" 2>/dev/null || true
    rm -f "${SWAP_FILE}"
    sed -i "\|${SWAP_FILE}|d" /etc/fstab
  fi

  rm -f "${SYSCTL_CONF}" "${MARKER_FILE}"

  echo ""
  success "卸载完成（数据已保留）"
  echo -e "  数据目录: ${CYAN}${target_dir}/data${NC}"
  echo -e "  配置文件: ${CYAN}${target_dir}/.env${NC}"
  [ -d "${backup_dir}" ] && echo -e "  数据备份: ${CYAN}${backup_dir}${NC}"
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

  if ! confirm "确认执行「完整卸载」？所有数据将丢失！"; then
    info "已取消"
    return 0
  fi

  echo ""
  read -rp "请输入 'DELETE ALL' 确认: " confirm_text
  if [ "$confirm_text" != "DELETE ALL" ]; then
    info "确认文本不匹配，已取消"
    return 0
  fi

  local target_dir="${APP_DIR}"
  [ -f /tmp/.metapi_custom_dir ] && target_dir=$(cat /tmp/.metapi_custom_dir)

  # 停止服务
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  # 删除 systemd
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true

  # 删除 PM2
  if command -v pm2 &>/dev/null; then
    pm2 delete "${APP_NAME}" 2>/dev/null || true
    pm2 save 2>/dev/null || true
  fi

  # 删除安装目录
  info "删除安装目录 ${target_dir}..."
  rm -rf "${target_dir}"

  # 删除用户
  if id "${APP_USER}" &>/dev/null; then
    userdel -r "${APP_USER}" 2>/dev/null || true
  fi
  rm -rf "/home/${APP_USER}"

  # 清理 Swap
  if [ -f "${SWAP_FILE}" ]; then
    info "移除 Swap..."
    swapoff "${SWAP_FILE}" 2>/dev/null || true
    rm -f "${SWAP_FILE}"
    sed -i "\|${SWAP_FILE}|d" /etc/fstab
  fi

  # 清理其他
  rm -f "${SYSCTL_CONF}"
  rm -rf "${LOG_DIR}"
  rm -f /tmp/metapi_* /tmp/.metapi_custom_* 2>/dev/null || true

  echo ""
  warn "Node.js 未被卸载（可能被其他应用依赖），如需卸载:"
  echo -e "  ${CYAN}apt-get remove --purge nodejs${NC}"

  success "完整卸载完成，所有 Metapi 相关文件已清除"
}

# ═══════════════════════════════════════════════════════════
# 功能：卸载菜单
# ═══════════════════════════════════════════════════════════
menu_uninstall() {
  while true; do
    echo ""
    echo -e "${BOLD}  卸载选项${NC}"
    separator
    echo -e "  ${GREEN}1${NC}) 保留数据卸载（保留数据库和配置）"
    echo -e "  ${RED}2${NC}) 完整卸载（删除所有数据，不可恢复）"
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
  echo -e "${BOLD}${CYAN}║     AI API 聚合网关 · 部署管理脚本 v2                 ║${NC}"
  echo -e "${BOLD}${CYAN}║     Ubuntu 22.04 · 智能冲突解决 · 详细诊断            ║${NC}"
  echo -e "${BOLD}${CYAN}║                                                      ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
}

show_main_menu() {
  echo ""
  separator
  echo -e "${BOLD}  主菜单${NC}"
  separator

  # 安装状态
  if [ -f "${MARKER_FILE}" ]; then
    local install_time
    install_time=$(grep '^install_time' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    local install_port
    install_port=$(grep '^port' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    echo -e "  安装状态: ${GREEN}已安装${NC} (${install_time})"
    echo -e "  运行端口: ${CYAN}${install_port:-${DEFAULT_PORT}}${NC}"
  else
    echo -e "  安装状态: ${YELLOW}未安装${NC}"
  fi

  # 服务状态
  if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
    echo -e "  服务状态: ${GREEN}运行中${NC}"
  elif [ -f "${SERVICE_FILE}" ]; then
    echo -e "  服务状态: ${RED}已停止${NC}"
  else
    echo -e "  服务状态: ${CYAN}未配置${NC}"
  fi

  # 系统资源
  local mem_avail
  mem_avail=$(get_available_memory_mb)
  local disk_avail
  disk_avail=$(check_disk_space "/opt" 0)
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
      4)
        info "再见！"
        exit 0
        ;;
      *)
        warn "无效选项，请输入 1-4"
        ;;
    esac

    press_any_key
  done
}

# ═══════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════
main "$@"
