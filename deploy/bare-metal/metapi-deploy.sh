#!/usr/bin/env bash
#
# ╔════════════════════════════════════════════════════════════╗
# ║  Metapi 一键部署脚本 v6 (Ubuntu/Debian)                    ║
# ║  交互菜单 → 环境检查 → 残留清理 → 下载预编译包 → 启动     ║
# ╚════════════════════════════════════════════════════════════╝
#
# 用法:
#   sudo bash metapi-deploy.sh                    # 交互式菜单部署
#   sudo bash metapi-deploy.sh --uninstall        # 卸载（保留数据）
#   sudo bash metapi-deploy.sh --uninstall-all    # 完整卸载
#   sudo bash metapi-deploy.sh --repair           # 依赖修复
#   sudo bash metapi-deploy.sh --token TOKEN --proxy-token PT  # 非交互式
#
# 一键安装（远程）:
#   curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh | sudo bash -s --

set -uo pipefail

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
readonly NODE_MAJOR=22
readonly RELEASE_API="https://api.github.com/repos/zczy-k/metapi/releases/latest"
readonly SCRIPT_URL="https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh"
readonly DEFAULT_PORT=4000
readonly MARKER_FILE="${APP_DIR}/.metapi_installed"
readonly MARKER_VERSION="6"
readonly SWAP_FILE="/swapfile_metapi"
readonly SYSCTL_CONF="/etc/sysctl.d/99-metapi.conf"
readonly NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
readonly NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
readonly NGINX_METAPI_CONF="${NGINX_AVAILABLE_DIR}/metapi.conf"
readonly NGINX_METAPI_ENABLED="${NGINX_ENABLED_DIR}/metapi.conf"
readonly NGINX_SSL_DIR="/etc/letsencrypt/live"

ACTUAL_PORT="${DEFAULT_PORT}"
FORCE_MODE=""
CLI_AUTH_TOKEN=""
CLI_PROXY_TOKEN=""
DOMAIN_NAME=""
DOMAIN_LISTEN_PORT=""
CERTBOT_EMAIL=""
SKIP_MENU=0

declare -a COMPLETED_STEPS=()
declare -a FAILED_STEPS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; log "INFO" "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN" "$*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; log "ERROR" "$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; log "OK" "$*"; }
step()    { echo -e "${CYAN}[>>>]${NC} $*"; log "STEP" "$*"; }
log() { local lvl="$1"; shift; [ -d "${LOG_DIR}" ] || mkdir -p "${LOG_DIR}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$lvl] $*" >> "${LOG_FILE}" 2>/dev/null || true; }

separator() { echo -e "${CYAN}──────────────────────────────────────────${NC}"; }

prompt_read() {
  if [ -t 0 ] || [ -e /dev/tty ]; then
    read -rp "$1" "$2" < /dev/tty
  else
    read -rp "$1" "$2"
  fi
}

prompt_read_silent() {
  if [ -t 0 ] || [ -e /dev/tty ]; then
    stty -echo < /dev/tty
    read -rp "$1" "$2" < /dev/tty
    stty echo < /dev/tty
  else
    read -rp "$1" "$2"
  fi
  echo ""
}

cleanup_terminal() {
  printf '\033[0m'
  stty echo 2>/dev/null
}

trap_cleanup() {
  cleanup_terminal
  echo -e "\n  ${YELLOW}操作已取消，返回菜单...${NC}"
}

register_trap() {
  trap 'trap_cleanup' INT
  trap 'trap_cleanup' TSTP
}

deregister_trap() {
  trap - INT TSTP
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uninstall)      FORCE_MODE="uninstall"; shift ;;
      --uninstall-all)  FORCE_MODE="uninstall-all"; shift ;;
      --repair)         FORCE_MODE="repair"; shift ;;
      --token)          CLI_AUTH_TOKEN="${2:-}"; SKIP_MENU=1; shift 2 ;;
      --proxy-token)    CLI_PROXY_TOKEN="${2:-}"; SKIP_MENU=1; shift 2 ;;
      --domain)         DOMAIN_NAME="${2:-}"; SKIP_MENU=1; shift 2 ;;
      --listen-port)    DOMAIN_LISTEN_PORT="${2:-}"; shift 2 ;;
      --cert-email)     CERTBOT_EMAIL="${2:-}"; shift 2 ;;
      --yes|-y)         SKIP_MENU=1; shift ;;
      --help|-h)
        echo "用法: sudo bash metapi-deploy.sh [选项]"
        echo ""
        echo "选项:"
        echo "  (无)              交互式菜单部署"
        echo "  --uninstall       卸载（保留数据）"
        echo "  --uninstall-all   完整卸载（不保留数据）"
        echo "  --repair          依赖修复"
        echo "  --token TOKEN     指定 AUTH_TOKEN（跳过交互菜单）"
        echo "  --proxy-token PT  指定 PROXY_TOKEN（跳过交互菜单）"
        echo "  --domain DOMAIN   指定域名（自动配置 Nginx 反向代理）"
        echo "  --listen-port PT  指定外部访问端口（默认 443 或 4000）"
        echo "  --cert-email EMAIL 指定邮箱，自动申请 Let's Encrypt 证书"
        echo "  --yes, -y         非交互式确认"
        echo "  --help, -h        显示帮助"
        exit 0 ;;
      *) warn "未知参数: $1"; shift ;;
    esac
  done
}

run_step() {
  local step_name="$1"; shift
  local step_fn="$1"; shift

  step "${step_name}..."
  local start_time; start_time=$(date +%s)

  if "$step_fn" "$@"; then
    local end_time; end_time=$(date +%s)
    success "${step_name} 完成 ($(( end_time - start_time ))s)"
    COMPLETED_STEPS+=("${step_name}")
    return 0
  else
    local exit_code=$?
    local end_time; end_time=$(date +%s)
    FAILED_STEPS+=("${step_name}")
    error "${step_name} 失败 (exit=${exit_code}, $(( end_time - start_time ))s)"
    return $exit_code
  fi
}

show_failure_report() {
  echo ""
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║            部署失败                          ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"

  echo ""
  echo -e "${BOLD}  失败步骤:${NC}"
  for s in "${FAILED_STEPS[@]}"; do echo -e "    ${RED}✗${NC} ${s}"; done

  if [ ${#COMPLETED_STEPS[@]} -gt 0 ]; then
    echo ""
    echo -e "${BOLD}  已完成步骤:${NC}"
    for s in "${COMPLETED_STEPS[@]}"; do echo -e "    ${GREEN}✓${NC} ${s}"; done
  fi

  echo ""
  echo -e "${BOLD}  系统状态:${NC}"
  echo -e "    内存:     $(free -h 2>/dev/null | awk '/Mem:/{print $3 " 已用 / " $2 " 总计"}' || echo '未知')"
  echo -e "    磁盘:     $(df -h /opt 2>/dev/null | awk 'NR==2{print $3 " 已用 / " $2 " 总计 (" $5 " 使用率)"}' || echo '未知')"

  echo ""
  echo -e "${BOLD}  日志:${NC}"
  echo -e "    部署: ${CYAN}${LOG_FILE}${NC}"
  echo -e "    服务: ${CYAN}journalctl -u ${SERVICE_NAME} -n 50 --no-pager${NC}"

  echo ""
  echo -e "  ${CYAN}修复建议: sudo bash ${SCRIPT_URL} --repair${NC}"
  echo ""
}

preflight_check() {
  if [ "$(id -u)" -ne 0 ]; then
    error "需要 root 权限，请使用: sudo bash $0"
    exit 1
  fi

  if ! command -v apt-get &>/dev/null; then
    error "当前系统不支持 apt-get，本脚本仅适用于 Debian/Ubuntu 系列"
    error "如需在其他系统部署，请使用 Docker 方式"
    exit 1
  fi

  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"
  log "INFO" "===== 脚本 v6 启动 ====="
}

detect_arch() {
  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf)  echo "armv7l" ;;
    *)             echo "unknown" ;;
  esac
}

detect_os() {
  if [ ! -f /etc/os-release ]; then echo "unknown"; return; fi
  source /etc/os-release 2>/dev/null
  echo "${ID:-unknown}"
}

get_memory_mb()   { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
get_avail_mb()    { awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo; }
get_disk_mb()     { local kb; kb=$(df -P /opt 2>/dev/null | awk 'NR==2{print $4}'); echo $(( kb / 1024 )); }
get_swap_mb()     { awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo; }

get_memory_limit() {
  local mem; mem=$(get_memory_mb)
  if [ "$mem" -lt 1024 ]; then echo "192"
  elif [ "$mem" -lt 2048 ]; then echo "256"
  else echo "384"
  fi
}

check_network() {
  local target="${1:-https://github.com}" timeout="${2:-10}"
  curl -sf --connect-timeout "$timeout" --max-time "$timeout" "$target" >/dev/null 2>&1
}

get_latest_release() {
  local api_url="${1:-${RELEASE_API}}"
  curl -sL --connect-timeout 15 --max-time 15 \
    -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null
}

get_latest_release_via_web() {
  curl -sL --connect-timeout 15 --max-time 15 \
    -H "Accept: application/json" \
    "https://github.com/zczy-k/metapi/releases/latest" 2>/dev/null
}

get_release_version() {
  echo "$1" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' 2>/dev/null | head -1
}

get_release_asset_url() {
  local release_info="$1" target_arch="$2"
  echo "$release_info" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' 2>/dev/null | grep "linux-${target_arch}" | head -1
}

port_in_use() { ss -tlnp 2>/dev/null | grep -qP ":${1}\b"; }

find_available_port() {
  local port="$1"
  while [ "$port" -le 65535 ]; do
    if ! port_in_use "$port"; then echo "$port"; return 0; fi
    port=$((port + 1))
  done
  echo "0"; return 1
}

auto_resolve_port() {
  if ! port_in_use "${ACTUAL_PORT}"; then return 0; fi
  local new_port; new_port=$(find_available_port $((ACTUAL_PORT + 1)))
  if [ "$new_port" = "0" ]; then
    error "未找到可用端口"
    return 1
  fi
  warn "端口 ${ACTUAL_PORT} 已被占用，自动选择 ${new_port}"
  ACTUAL_PORT="$new_port"
}

detect_nginx() {
  command -v nginx &>/dev/null && nginx -v 2>&1 | grep -q nginx
}

install_nginx() {
  if detect_nginx; then
    info "Nginx 已安装，直接复用"
    return 0
  fi
  info "安装 Nginx..."
  apt-get install -y -qq nginx 2>&1 || { error "Nginx 安装失败"; return 1; }
  systemctl enable --now nginx 2>/dev/null || true
  success "Nginx 安装完成"
}

reload_nginx() {
  if detect_nginx; then
    systemctl is-active nginx &>/dev/null && nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
  fi
}

remove_nginx_metapi_conf() {
  local found=0
  if [ -f "${NGINX_METAPI_ENABLED}" ]; then
    warn "发现 Metapi Nginx 配置（已启用），正在移除..."
    rm -f "${NGINX_METAPI_ENABLED}"
    found=1
  fi
  if [ -f "${NGINX_METAPI_CONF}" ]; then
    warn "发现 Metapi Nginx 配置文件，正在移除..."
    rm -f "${NGINX_METAPI_CONF}"
    found=1
  fi
  if [ "$found" -eq 1 ]; then
    reload_nginx
  fi
}

configure_nginx_proxy() {
  local domain="$1" listen_port="$2" upstream_port="$3"

  info "写入 Nginx 反向代理配置..."

  if [ -n "$domain" ]; then
    cat > "${NGINX_METAPI_CONF}" << NGINX_EOF
server {
    listen ${listen_port};
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_cache off;
    }
}
NGINX_EOF
  else
    cat > "${NGINX_METAPI_CONF}" << NGINX_EOF
server {
    listen ${listen_port};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${upstream_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_cache off;
    }
}
NGINX_EOF
  fi

  ln -sf "${NGINX_METAPI_CONF}" "${NGINX_METAPI_ENABLED}"

  if nginx -t 2>/dev/null; then
    reload_nginx
    success "Nginx 配置生效"
  else
    error "Nginx 配置测试失败，请检查"
    nginx -t 2>&1
    return 1
  fi
}

setup_ssl_cert() {
  local domain="$1" email="$2"

  if [ ! -d "${NGINX_SSL_DIR}/${domain}" ]; then
    if ! command -v certbot &>/dev/null; then
      info "安装 certbot..."
      apt-get install -y -qq certbot python3-certbot-nginx 2>&1 || { error "certbot 安装失败"; return 1; }
    fi

    info "申请 Let's Encrypt 证书..."
    local certbot_args="-n --nginx -d ${domain}"
    [ -n "$email" ] && certbot_args="$certbot_args -m ${email}" || certbot_args="$certbot_args --register-unsafely-without-email"

    if certbot $certbot_args --agree-tos --redirect 2>&1; then
      success "SSL 证书申请成功"
    else
      warn "certbot 自动配置失败，尝试手动..."
      certbot certonly --nginx -d "${domain}" 2>&1 || { warn "证书申请暂时失败，可稍后手动执行: certbot --nginx -d ${domain}"; return 1; }
    fi
  else
    info "SSL 证书已存在: ${NGINX_SSL_DIR}/${domain}"
  fi
}

detect_nginx_metapi_conf() {
  [ -f "${NGINX_METAPI_CONF}" ] || [ -f "${NGINX_METAPI_ENABLED}" ]
}

install_node() {
  if command -v node &>/dev/null; then
    local major; major=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$major" -ge "$NODE_MAJOR" ]; then
      success "Node.js $(node -v) 已安装"
      return 0
    fi
    warn "Node.js $(node -v) 版本过低，需要 ${NODE_MAJOR}+"
  fi

  info "安装 Node.js ${NODE_MAJOR}..."

  local retry=0
  while [ $retry -lt 3 ]; do
    if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - 2>&1; then break; fi
    retry=$((retry + 1)); sleep 3
  done

  if [ $retry -lt 3 ] && apt-get install -y -qq nodejs 2>&1; then
    success "Node.js $(node -v) 安装成功"
    return 0
  fi

  warn "NodeSource 安装失败，使用官方二进制..."
  local arch; arch=$(detect_arch)
  local node_arch="$arch"
  [ "$arch" = "amd64" ] && node_arch="x64"

  local node_ver="${NODE_MAJOR}.0.0"
  local node_url="https://nodejs.org/dist/v${node_ver}/node-v${node_ver}-linux-${node_arch}.tar.xz"

  if curl -fsSL "$node_url" | tar -xJ -C /usr/local --strip-components=1 2>&1; then
    success "Node.js $(node -v) 安装成功（官方二进制）"
    return 0
  fi

  error "Node.js 安装失败，请手动安装 Node.js ${NODE_MAJOR}+"
  return 1
}

pre_install_cleanup() {
  echo ""
  echo -e "${BOLD}${CYAN}  ── 环境检查与残留清理 ──${NC}"
  echo ""

  info "检查系统环境..."
  local arch; arch=$(detect_arch)
  if [ "$arch" = "unknown" ]; then
    error "无法识别系统架构 ($(uname -m))"
    return 1
  fi

  local mem_mb; mem_mb=$(get_memory_mb)
  local disk_mb; disk_mb=$(get_disk_mb)
  info "架构: ${arch} | 内存: ${mem_mb}MB | 磁盘: ${disk_mb}MB 可用"

  if [ "$disk_mb" -lt 300 ]; then
    error "磁盘可用空间仅 ${disk_mb}MB，至少需要 300MB"
    return 1
  fi

  if ! check_network "https://github.com" 10; then
    error "无法连接 GitHub，请检查网络"
    return 1
  fi

  echo ""
  info "检查残留文件..."

  local found_residual=0

  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    warn "发现正在运行的 ${SERVICE_NAME} 服务，正在停止..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    found_residual=1
  fi

  if [ -f "${SERVICE_FILE}" ]; then
    warn "发现残留 systemd 服务文件，正在清理..."
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    found_residual=1
  fi

  if [ -f "${SERVICE_FILE}.bak" ] || [ -f "/etc/systemd/system/${SERVICE_NAME}.service.bak" ]; then
    warn "发现残留服务备份文件，正在清理..."
    rm -f "${SERVICE_FILE}.bak" "/etc/systemd/system/${SERVICE_NAME}.service.bak"
    found_residual=1
  fi

  if id "${APP_USER}" &>/dev/null; then
    warn "发现残留用户 '${APP_USER}'，正在清理..."
    userdel "${APP_USER}" 2>/dev/null || true
    found_residual=1
  fi

  if [ -f "${SWAP_FILE}" ]; then
    warn "发现残留 Swap 文件，正在清理..."
    swapoff "${SWAP_FILE}" 2>/dev/null || true
    rm -f "${SWAP_FILE}"
    sed -i "\|${SWAP_FILE}|d" /etc/fstab 2>/dev/null || true
    found_residual=1
  fi

  if [ -f "${SYSCTL_CONF}" ]; then
    warn "发现残留 sysctl 配置，正在清理..."
    rm -f "${SYSCTL_CONF}"
    found_residual=1
  fi

  if detect_nginx_metapi_conf; then
    remove_nginx_metapi_conf
    found_residual=1
  fi

  if [ -d "${APP_DIR}" ]; then
    local has_data="no"
    [ -d "${APP_DIR}/data" ] && [ "$(ls -A "${APP_DIR}/data" 2>/dev/null)" ] && has_data="yes"
    local has_env="no"
    [ -f "${APP_DIR}/.env" ] && has_env="yes"

    if [ "$has_data" = "yes" ] || [ "$has_env" = "yes" ]; then
      info "发现已有配置/数据，将保留 .env 和 data/ 目录"
      if [ -f "${ENV_FILE}" ]; then
        cp -a "${ENV_FILE}" "/tmp/metapi_env_cleanup_$$"
      fi
      if [ -d "${DATA_DIR}" ]; then
        cp -a "${DATA_DIR}" "/tmp/metapi_data_cleanup_$$"
      fi
      rm -rf "${APP_DIR:?}"/* "${APP_DIR}"/.[!.]* 2>/dev/null || true
      [ -f "/tmp/metapi_env_cleanup_$$" ] && mv "/tmp/metapi_env_cleanup_$$" "${ENV_FILE}"
      [ -d "/tmp/metapi_data_cleanup_$$" ] && mv "/tmp/metapi_data_cleanup_$$" "${APP_DIR}/data"
      found_residual=1
    else
      warn "发现残留安装目录，正在清理..."
      rm -rf "${APP_DIR}"
      found_residual=1
    fi
  fi

  if [ -d "${LOG_DIR}" ]; then
    rm -rf "${LOG_DIR}"
    mkdir -p "${LOG_DIR}"
    touch "${LOG_FILE}"
    found_residual=1
  fi

  rm -f "${MARKER_FILE}" 2>/dev/null

  if [ "$found_residual" -eq 1 ]; then
    success "残留清理完成"
  else
    success "环境检查通过，无残留文件"
  fi

  echo ""
}

download_prebuilt() {
  local arch; arch=$(detect_arch)

  info "系统架构: ${arch}"

  if [ "$arch" = "unknown" ]; then
    error "无法识别系统架构 ($(uname -m))"
    return 1
  fi

  info "查询最新版本..."
  local release_info
  release_info=$(get_latest_release)

  if [ -z "$release_info" ]; then
    warn "GitHub API 返回为空，尝试备用方式..."
    release_info=$(get_latest_release_via_web)
  fi

  if [ -z "$release_info" ]; then
    error "无法获取 GitHub Release 信息"
    echo ""
    echo -e "  ${YELLOW}可能的原因:${NC}"
    echo -e "    - 网络无法访问 GitHub API"
    echo -e "    - 国内服务器可能被限制（建议配置代理或使用镜像）"
    echo ""
    return 1
  fi

  local version; version=$(get_release_version "$release_info")
  if [ -z "$version" ]; then
    error "无法解析版本号"
    return 1
  fi
  info "最新版本: ${version}"

  local download_url
  download_url=$(get_release_asset_url "$release_info" "$arch")

  if [ -z "$download_url" ]; then
    error "未找到 ${arch} 架构的预编译包"
    echo -e "  ${YELLOW}已发布的资产:${NC}"
    echo "$release_info" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' 2>/dev/null | while read -r url; do
      echo -e "    ${DIM}${url}${NC}"
    done
    return 1
  fi

  info "下载地址: ${download_url}"

  local tmp_dir; tmp_dir=$(mktemp -d)
  local filename; filename=$(basename "$download_url")
  local tmp_file="${tmp_dir}/${filename}"

  info "下载预编译包..."
  if ! curl -fSL --connect-timeout 30 --max-time 600 --progress-bar -o "$tmp_file" "$download_url" 2>&1; then
    error "下载失败，请检查网络"
    rm -rf "${tmp_dir}"
    return 1
  fi

  info "解压..."
  if ! tar -xzf "$tmp_file" -C "$tmp_dir" 2>&1; then
    error "解压失败，文件可能已损坏"
    rm -rf "${tmp_dir}"
    return 1
  fi

  local extracted_dir
  extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "metapi-*" | head -1)
  [ -z "$extracted_dir" ] && extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d | tail -1)

  if [ -z "$extracted_dir" ] || [ ! -d "${extracted_dir}/dist" ]; then
    error "预编译包结构异常"
    rm -rf "${tmp_dir}"
    return 1
  fi

  info "安装到 ${APP_DIR}..."

  if [ -f "${ENV_FILE}" ]; then
    cp -a "${ENV_FILE}" "${tmp_dir}/env_backup"
  fi
  if [ -d "${APP_DIR}/data" ]; then
    cp -a "${APP_DIR}/data" "${tmp_dir}/data_backup"
  fi

  rm -rf "${APP_DIR:?}"/* "${APP_DIR}"/.[!.]* 2>/dev/null || true
  mkdir -p "${APP_DIR}"
  cp -a "${extracted_dir}/." "${APP_DIR}/"

  [ -f "${tmp_dir}/env_backup" ] && cp -a "${tmp_dir}/env_backup" "${APP_DIR}/.env"
  [ -d "${tmp_dir}/data_backup" ] && cp -a "${tmp_dir}/data_backup/." "${APP_DIR}/data/"

  rm -rf "${tmp_dir}"

  [ ! -f "${APP_DIR}/dist/server/index.js" ] && { error "验证失败: dist/server/index.js 缺失"; return 1; }

  success "预编译包安装完成 (版本: ${version}, 架构: ${arch})"
}

create_user() {
  if id "${APP_USER}" &>/dev/null; then
    info "用户 '${APP_USER}' 已存在"
    local home; home=$(getent passwd "${APP_USER}" | cut -d: -f6)
    [ "$home" != "${APP_DIR}" ] && usermod -d "${APP_DIR}" "${APP_USER}"
    return 0
  fi

  info "创建隔离用户 '${APP_USER}'..."
  useradd -r -m -s /bin/bash -d "${APP_DIR}" "${APP_USER}"
  passwd -l "${APP_USER}" 2>/dev/null || true
  success "用户创建完成"
}

configure_env() {
  if [ -f "${ENV_FILE}" ]; then
    info ".env 已存在，更新配置..."

    if [ -n "${CLI_AUTH_TOKEN}" ]; then
      sed -i "s|^AUTH_TOKEN=.*|AUTH_TOKEN=${CLI_AUTH_TOKEN}|" "${ENV_FILE}"
    fi
    if [ -n "${CLI_PROXY_TOKEN}" ]; then
      sed -i "s|^PROXY_TOKEN=.*|PROXY_TOKEN=${CLI_PROXY_TOKEN}|" "${ENV_FILE}"
    fi
    sed -i "s|^PORT=.*|PORT=${ACTUAL_PORT}|" "${ENV_FILE}"

    local configured_port; configured_port=$(grep "^PORT=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$configured_port" ] && ACTUAL_PORT="$configured_port"
    return 0
  fi

  info "写入配置文件..."

  local auth_token="${CLI_AUTH_TOKEN}"
  local proxy_token="${CLI_PROXY_TOKEN}"
  local mem_limit; mem_limit=$(get_memory_limit)

  cat > "${ENV_FILE}" << EOF
AUTH_TOKEN=${auth_token}
PROXY_TOKEN=${proxy_token}
PORT=${ACTUAL_PORT}
DATA_DIR=${APP_DIR}/data
CHECKIN_CRON=0 8 * * *
BALANCE_REFRESH_CRON=0 * * * *
TZ=Asia/Shanghai
NODE_OPTIONS=--max-old-space-size=${mem_limit}
UPDATE_CHECK_URL=${RELEASE_API}
EOF

  chmod 600 "${ENV_FILE}"
  success ".env 配置完成 (端口: ${ACTUAL_PORT})"
}

configure_swap() {
  local total_mem; total_mem=$(get_memory_mb)
  local swap_mb; swap_mb=$(get_swap_mb)

  if [ "$total_mem" -ge 2048 ]; then
    info "内存 ${total_mem}MB，无需 Swap"
    return 0
  fi

  if [ "$swap_mb" -ge 1024 ]; then
    info "Swap 已有 ${swap_mb}MB"
    return 0
  fi

  info "内存仅 ${total_mem}MB，自动配置 1GB Swap..."

  if [ -f "${SWAP_FILE}" ]; then
    swapoff "${SWAP_FILE}" 2>/dev/null || true
    rm -f "${SWAP_FILE}"
  fi

  if ! fallocate -l 1G "${SWAP_FILE}" 2>/dev/null; then
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=1024 status=progress 2>&1
  fi

  chmod 600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}" >/dev/null 2>&1
  swapon "${SWAP_FILE}" 2>/dev/null || true
  grep -q "${SWAP_FILE}" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
  sysctl vm.swappiness=10 >/dev/null 2>&1
  grep -q "vm.swappiness" "${SYSCTL_CONF}" 2>/dev/null || echo "vm.swappiness=10" > "${SYSCTL_CONF}"

  success "Swap 配置完成 (1GB)"
}

install_systemd_service() {
  info "配置 systemd 服务..."

  local node_path; node_path=$(which node)
  local mem_limit; mem_limit=$(get_memory_limit)

  cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Metapi - AI API Aggregation Gateway
After=network.target
ConditionPathExists=${APP_DIR}/dist/server/index.js

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}

Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=${mem_limit}
EnvironmentFile=-${ENV_FILE}
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
ReadWritePaths=${DATA_DIR} ${APP_DIR}/drizzle
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" 2>/dev/null
  success "systemd 服务配置完成"
}

set_permissions() {
  info "设置文件权限..."
  mkdir -p "${APP_DIR}/data"
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
  chmod 700 "${APP_DIR}"
  chmod 600 "${APP_DIR}/.env" 2>/dev/null
  chmod 700 "${APP_DIR}/data"
  success "权限设置完成"
}

write_marker() {
  local current_version="unknown"
  if [ -f "${APP_DIR}/.build-info" ]; then
    current_version=$(grep '^version=' "${APP_DIR}/.build-info" 2>/dev/null | cut -d= -f2 || echo "unknown")
  fi

  cat > "${MARKER_FILE}" << EOF
version=${MARKER_VERSION}
app_version=${current_version}
install_time=$(date '+%Y-%m-%d %H:%M:%S')
node_version=$(node -v 2>/dev/null || echo "unknown")
arch=$(detect_arch)
user=${APP_USER}
dir=${APP_DIR}
service=${SERVICE_FILE}
port=${ACTUAL_PORT}
domain=${DOMAIN_NAME}
listen_port=${DOMAIN_LISTEN_PORT}
cert_email=${CERTBOT_EMAIL}
EOF
  chown "${APP_USER}:${APP_USER}" "${MARKER_FILE}" 2>/dev/null
}

start_service() {
  info "启动服务..."
  systemctl start "${SERVICE_NAME}"

  local retry=0
  while [ $retry -lt 30 ]; do
    if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
      if curl -sf --connect-timeout 2 "http://127.0.0.1:${ACTUAL_PORT}" >/dev/null 2>&1; then
        success "服务启动成功 (端口 ${ACTUAL_PORT} 已响应)"
        return 0
      fi
    else
      error "服务启动后异常退出"
      echo ""
      journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null
      return 1
    fi
    retry=$((retry + 1)); sleep 1
  done

  if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
    warn "服务已运行但端口 ${ACTUAL_PORT} 暂未响应"
    warn "可能原因: 应用仍在初始化数据库"
    echo ""
    journalctl -u "${SERVICE_NAME}" -n 15 --no-pager 2>/dev/null
    return 0
  else
    error "服务启动失败"
    echo ""
    journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null
    return 1
  fi
}

show_firewall_hint() {
  echo ""
  separator
  echo -e "${YELLOW}  防火墙提示${NC}"
  separator

  local fw_cmd=""
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    fw_cmd="ufw allow ${DOMAIN_LISTEN_PORT:-$ACTUAL_PORT}/tcp"
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    fw_cmd="firewall-cmd --permanent --add-port=${DOMAIN_LISTEN_PORT:-$ACTUAL_PORT}/tcp && firewall-cmd --reload"
  fi

  if [ -n "$fw_cmd" ]; then
    echo -e "  ${YELLOW}请执行:${NC} ${CYAN}${fw_cmd}${NC}"
  fi

  local ports_to_check="${DOMAIN_LISTEN_PORT:-$ACTUAL_PORT}"
  echo -e "  ${YELLOW}请在云服务器安全组放行 ${ports_to_check}/TCP${NC}"

  if curl -sf --connect-timeout 3 "http://127.0.0.1:${ACTUAL_PORT}" >/dev/null 2>&1; then
    success "Metapi 服务本地可达 ✓"
  else
    warn "Metapi 服务暂未响应（可能仍在启动中）"
  fi
}

show_interactive_menu() {
  register_trap

  local arch; arch=$(detect_arch)
  local os; os=$(detect_os)

  local menu_page="main"
  local choice=""

  while true; do
    local mem_mb; mem_mb=$(get_memory_mb)
    local disk_mb; disk_mb=$(get_disk_mb)

    local is_installed="no"
    [ -f "${MARKER_FILE}" ] && is_installed="yes"

    local svc_status="未安装"
    if [ "$is_installed" = "yes" ]; then
      if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        svc_status="运行中"
      elif systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        svc_status="已停止"
      else
        svc_status="异常"
      fi
    fi

    clear

    echo ""
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        Metapi 管理面板              ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════╝${NC}"
    echo -e "  ${DIM}${os} / ${arch} | 内存 ${mem_mb}MB | 磁盘 ${disk_mb}MB 可用${NC}"
    echo -e "  ${DIM}服务状态: $( [ "$svc_status" = "运行中" ] && echo "${GREEN}${svc_status}${NC}" || [ "$svc_status" = "已停止" ] && echo "${YELLOW}${svc_status}${NC}" || echo "${RED}${svc_status}${NC}" )${NC}"
    echo ""

    if [ "$menu_page" = "main" ]; then
      echo -e "  ${GREEN}1)${NC} 安装/重装部署"
      echo -e "  ${GREEN}2)${NC} 查看状态"
      echo -e "  ${GREEN}3)${NC} 修复依赖"
      if [ "$is_installed" = "yes" ]; then
        if [ "$svc_status" = "运行中" ]; then
          echo -e "  ${GREEN}4)${NC} 重启服务"
          echo -e "  ${GREEN}5)${NC} 停止服务"
        else
          echo -e "  ${GREEN}4)${NC} 启动服务"
          echo -e "  ${DIM}5) 停止服务（服务已停止）${NC}"
        fi
        echo -e "  ${GREEN}6)${NC} 卸载（保留数据）"
        echo -e "  ${GREEN}7)${NC} 完整卸载（删除数据）"
        echo -e "  ${GREEN}8)${NC} 升级到最新版本"
        echo -e "  ${GREEN}9)${NC} 查看运行日志"
        echo -e "  ${GREEN}10)${NC} 配置 SSL 证书 / 域名"
      else
        echo -e "  ${DIM}4) 启动服务（未安装）${NC}"
        echo -e "  ${DIM}5) 停止服务（未安装）${NC}"
        echo -e "  ${DIM}6) 卸载（未安装）${NC}"
        echo -e "  ${DIM}7) 完整卸载（未安装）${NC}"
      fi
      echo ""
      echo -e "  ${CYAN}0)${NC} 退出"
      echo ""
      local max_opt=7; [ "$is_installed" = "yes" ] && max_opt=10
      prompt_read "  请输入数字 [0-${max_opt}]: " choice
      echo ""

      case "$choice" in
        1)
          deregister_trap
          _installation_wizard
          register_trap
          ;;
        2)
          deregister_trap
          show_status_info
          echo ""
          prompt_read "  按回车键返回菜单" _
          register_trap
          ;;
        3)
          deregister_trap
          do_repair
          echo ""
          prompt_read "  按回车键返回菜单" _
          register_trap
          ;;
        4)
          if [ "$is_installed" = "yes" ]; then
            deregister_trap
            if [ "$svc_status" = "运行中" ]; then
              echo -e "  ${YELLOW}正在重启服务...${NC}"
              systemctl restart "${SERVICE_NAME}" 2>/dev/null
              if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
                echo -e "  ${GREEN}服务已重启${NC}"
              else
                echo -e "  ${RED}服务重启失败！${NC}"
              fi
            else
              echo -e "  ${YELLOW}正在启动服务...${NC}"
              systemctl start "${SERVICE_NAME}" 2>/dev/null
              if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
                echo -e "  ${GREEN}服务已启动${NC}"
              else
                echo -e "  ${RED}服务启动失败！${NC}"
              fi
            fi
            echo ""
            prompt_read "  按回车键返回菜单" _
            register_trap
          fi
          ;;
        5)
          if [ "$is_installed" = "yes" ] && [ "$svc_status" = "运行中" ]; then
            deregister_trap
            echo -e "  ${YELLOW}正在停止服务...${NC}"
            systemctl stop "${SERVICE_NAME}" 2>/dev/null
            if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
              echo -e "  ${GREEN}服务已停止${NC}"
            else
              echo -e "  ${RED}服务停止失败！${NC}"
            fi
            echo ""
            prompt_read "  按回车键返回菜单" _
            register_trap
          fi
          ;;
        6)
          if [ "$is_installed" = "yes" ]; then
            deregister_trap
            echo -e "  ${YELLOW}卸载将保留 /opt/metapi/data 目录下的数据${NC}"
            prompt_read "  确认卸载？[y/N]: " confirm
            echo ""
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
              do_uninstall
              echo ""
              prompt_read "  按回车键返回菜单" _
            fi
            register_trap
          fi
          ;;
        7)
          if [ "$is_installed" = "yes" ]; then
            deregister_trap
            echo -e "  ${RED}⚠ 完整卸载将删除所有数据，不可恢复！${NC}"
            prompt_read "  确认完整卸载？[y/N]: " confirm
            echo ""
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
              do_uninstall_all
              echo ""
              prompt_read "  按回车键返回菜单" _
            fi
            register_trap
          fi
          ;;
        8)
          if [ "$is_installed" = "yes" ]; then
            deregister_trap
            do_upgrade
            echo ""
            prompt_read "  按回车键返回菜单" _
            register_trap
          fi
          ;;
        9)
          if [ "$is_installed" = "yes" ]; then
            deregister_trap
            view_service_logs
            echo ""
            prompt_read "  按回车键返回菜单" _
            register_trap
          fi
          ;;
        10)
          if [ "$is_installed" = "yes" ]; then
            if [ -f "${MARKER_FILE}" ]; then
              local mk_domain; mk_domain=$(grep '^domain=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "")
              local mk_listen_port; mk_listen_port=$(grep '^listen_port=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "")
              local mk_cert_email; mk_cert_email=$(grep '^cert_email=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "")
              [ -n "$mk_domain" ] && DOMAIN_NAME="$mk_domain"
              [ -n "$mk_listen_port" ] && DOMAIN_LISTEN_PORT="$mk_listen_port"
              [ -n "$mk_cert_email" ] && CERTBOT_EMAIL="$mk_cert_email"
            fi
            deregister_trap
            _configure_ssl_domain_interactive
            register_trap
          fi
          ;;
        0|q|Q)
          deregister_trap
          cleanup_terminal
          echo -e "  ${YELLOW}已退出${NC}"
          exit 0
          ;;
        *)
          echo -e "  ${RED}无效选择，请重新输入${NC}"
          prompt_read "  按回车键继续" _
          ;;
      esac

    fi
  done
}

show_status_info() {
  echo ""
  echo -e "${BOLD}${CYAN}  ── 服务状态 ──${NC}"
  echo ""

  if [ ! -f "${MARKER_FILE}" ]; then
    echo -e "  ${YELLOW}Metapi 尚未安装${NC}"
    return 0
  fi

  local install_time; install_time=$(grep '^install_time=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "未知")
  local app_version; app_version=$(grep '^app_version=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "未知")
  echo -e "  应用版本:  ${BOLD}${app_version}${NC}"
  echo -e "  安装时间:  ${BOLD}${install_time}${NC}"

  echo ""
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo -e "  服务状态:  ${GREEN}${BOLD}运行中${NC}"
  else
    echo -e "  服务状态:  ${RED}${BOLD}已停止${NC}"
  fi

  local configured_port; configured_port=$(grep '^PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "${DEFAULT_PORT}")
  echo -e "  监听端口:  ${BOLD}${configured_port}${NC}"

  local mk_domain; mk_domain=$(grep '^domain=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "")
  if [ -n "$mk_domain" ]; then
    local mk_listen_port; mk_listen_port=$(grep '^listen_port=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "")
    echo -e "  域名:      ${CYAN}${mk_domain}${NC}"
    [ -n "$mk_listen_port" ] && echo -e "  外部端口:  ${BOLD}${mk_listen_port}${NC}"
    if [ -d "${NGINX_SSL_DIR}/${mk_domain}" ]; then
      echo -e "  SSL 证书:  ${GREEN}✓ 已签发${NC}"
    fi
  fi

  local pid; pid=$(systemctl show "${SERVICE_NAME}" --property=MainPID --value 2>/dev/null || echo "")
  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    echo -e "  进程 PID:  ${BOLD}${pid}${NC}"
    local mem_info; mem_info=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.0fMB", $1/1024}')
    echo -e "  内存占用:  ${BOLD}${mem_info}${NC}"
    local uptime_info; uptime_info=$(ps -p "$pid" -o etime= 2>/dev/null | xargs || echo "")
    [ -n "$uptime_info" ] && echo -e "  运行时长:  ${BOLD}${uptime_info}${NC}"
  fi

  local ip_addr; ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || echo '服务器IP')
  echo -e "  访问地址:  ${CYAN}http://${ip_addr}:${configured_port}${NC}"

  local app_size; app_size=$(du -sh "${APP_DIR}" 2>/dev/null | awk '{print $1}' || echo "未知")
  echo -e "  磁盘占用:  ${BOLD}${app_size}${NC}"

  echo ""
  echo -e "  ${DIM}── 最近日志 ──${NC}"
  journalctl -u "${SERVICE_NAME}" --no-pager -n 3 2>/dev/null | sed 's/^/  /' || echo "  （无日志）"
}

_installation_wizard() {
  local wizard_port="${ACTUAL_PORT}"
  local wizard_auth_token="${CLI_AUTH_TOKEN}"
  local wizard_proxy_token="${CLI_PROXY_TOKEN}"
  local wizard_domain="${DOMAIN_NAME}"
  local wizard_listen_port="${DOMAIN_LISTEN_PORT}"
  local wizard_cert_email="${CERTBOT_EMAIL}"

  if [ -f "${ENV_FILE}" ]; then
    local env_port; env_port=$(grep '^PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$env_port" ] && wizard_port="$env_port"
    local env_auth; env_auth=$(grep '^AUTH_TOKEN=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$env_auth" ] && wizard_auth_token="$env_auth"
    local env_proxy; env_proxy=$(grep '^PROXY_TOKEN=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$env_proxy" ] && wizard_proxy_token="$env_proxy"
  fi

  if [ -f "${MARKER_FILE}" ]; then
    local mk_domain; mk_domain=$(grep '^domain=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$mk_domain" ] && wizard_domain="$mk_domain"
    local mk_listen_port; mk_listen_port=$(grep '^listen_port=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$mk_listen_port" ] && wizard_listen_port="$mk_listen_port"
    local mk_cert_email; mk_cert_email=$(grep '^cert_email=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    [ -n "$mk_cert_email" ] && wizard_cert_email="$mk_cert_email"
  fi

  echo ""
  echo -e "${BOLD}${CYAN}╔════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║       安装部署向导                  ║${NC}"
  echo -e "${BOLD}${CYAN}╚════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${DIM}按步骤填入信息，中途可按 Ctrl+C 取消${NC}"
  echo ""

  echo -e "  ${YELLOW}管理令牌 = 管理后台登录密码${NC}"
  prompt_read_silent "  第一步：请输入管理令牌: " wizard_auth_token
  if [ -z "$wizard_auth_token" ]; then
    echo -e "  ${RED}管理令牌不能为空，安装已取消${NC}"
    prompt_read "  按回车键返回主菜单" _
    return
  fi
  echo ""

  echo -e "  ${YELLOW}代理令牌 = 下游 API 调用密钥${NC}"
  prompt_read_silent "  第二步：请输入代理令牌: " wizard_proxy_token
  if [ -z "$wizard_proxy_token" ]; then
    echo -e "  ${RED}代理令牌不能为空，安装已取消${NC}"
    prompt_read "  按回车键返回主菜单" _
    return
  fi
  echo ""

  prompt_read "  第三步：Metapi 内部端口 [${wizard_port}]: " input_port
  if [ -n "$input_port" ]; then
    if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
      wizard_port="$input_port"
    else
      echo -e "  ${YELLOW}无效端口，使用默认值 ${wizard_port}${NC}"
    fi
  fi
  echo ""

  echo -e "  ${YELLOW}域名配置（可选，留空则跳过）${NC}"
  prompt_read "  第四步：输入域名（如 api.example.com）: " input_domain
  if [ -n "$input_domain" ]; then
    wizard_domain="$input_domain"
    local default_lp="443"
    prompt_read "  外部访问端口 [${default_lp}]: " input_lp
    wizard_listen_port="${input_lp:-$default_lp}"
    echo ""
    prompt_read "  证书邮箱（Let's Encrypt 通知，留空不申请证书）: " wizard_cert_email
    echo ""
    echo -e "  ${GREEN}✓ 域名配置完成:${NC}"
    echo -e "    域名:  ${CYAN}${wizard_domain}:${wizard_listen_port}${NC}"
    [ -n "$wizard_cert_email" ] && echo -e "    邮箱:  ${CYAN}${wizard_cert_email}${NC}" || echo -e "    证书:  ${YELLOW}未设置（部署后可在主菜单 10 配置）${NC}"
  else
    wizard_domain=""
    wizard_listen_port=""
    wizard_cert_email=""
    echo -e "  ${DIM}跳过域名配置，仅 IP 访问${NC}"
  fi
  echo ""

  separator
  echo -e "  ${BOLD}安装摘要${NC}"
  separator
  echo -e "  Metapi 端口:  ${CYAN}${wizard_port}${NC}"
  echo -e "  管理令牌:     ${CYAN}已设置${NC}"
  echo -e "  代理令牌:     ${CYAN}已设置${NC}"
  if [ -n "$wizard_domain" ]; then
    echo -e "  域名:         ${CYAN}${wizard_domain}:${wizard_listen_port}${NC}"
  else
    echo -e "  域名:         ${DIM}未设置（仅 IP 访问）${NC}"
  fi
  echo ""

  prompt_read "  确认开始安装？[Y/n]: " confirm_start
  if [ "$confirm_start" = "n" ] || [ "$confirm_start" = "N" ]; then
    echo -e "  ${YELLOW}已取消${NC}"
    prompt_read "  按回车键返回主菜单" _
    return
  fi

  ACTUAL_PORT="$wizard_port"
  CLI_AUTH_TOKEN="$wizard_auth_token"
  CLI_PROXY_TOKEN="$wizard_proxy_token"
  DOMAIN_NAME="$wizard_domain"
  DOMAIN_LISTEN_PORT="${wizard_listen_port:-${wizard_domain:+443}}"
  CERTBOT_EMAIL="$wizard_cert_email"

  SKIP_MENU=1
  do_install
}

do_install() {
  COMPLETED_STEPS=()
  FAILED_STEPS=()

  if [ "$SKIP_MENU" -eq 0 ]; then
    show_interactive_menu
  fi

  if [ -z "${CLI_AUTH_TOKEN}" ]; then
    error "非交互模式必须通过 --token 指定管理令牌"
    return 1
  fi
  if [ -z "${CLI_PROXY_TOKEN}" ]; then
    error "非交互模式必须通过 --proxy-token 指定代理令牌"
    return 1
  fi

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║       Metapi 开始部署                        ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local arch; arch=$(detect_arch)
  local os; os=$(detect_os)
  local mem_mb; mem_mb=$(get_memory_mb)
  local disk_mb; disk_mb=$(get_disk_mb)

  echo -e "  平台:    ${CYAN}${os} / ${arch}${NC}"
  echo -e "  内存:    ${CYAN}${mem_mb}MB${NC}"
  echo -e "  磁盘:    ${CYAN}${disk_mb}MB 可用${NC}"
  echo -e "  端口:    ${CYAN}${ACTUAL_PORT}${NC}"
  echo ""

  if ! run_step "环境检查与残留清理" pre_install_cleanup; then show_failure_report; return 1; fi

  auto_resolve_port

  if ! run_step "安装 Node.js 运行时" install_node; then show_failure_report; return 1; fi
  if ! run_step "下载预编译包 (${arch})" download_prebuilt; then show_failure_report; return 1; fi
  if ! run_step "创建隔离用户" create_user; then show_failure_report; return 1; fi
  if ! run_step "配置环境变量" configure_env; then show_failure_report; return 1; fi

  run_step "配置 Swap" configure_swap || true

  if ! run_step "安装服务并设置权限" _install_service_and_perms; then show_failure_report; return 1; fi
  if ! run_step "启动服务" start_service; then show_failure_report; return 1; fi

  if [ -n "$DOMAIN_NAME" ] || [ -n "$DOMAIN_LISTEN_PORT" ]; then
    run_step "配置 Nginx 反向代理" _setup_nginx_proxy || true
  fi

  if [ -n "$DOMAIN_NAME" ] && [ -n "$CERTBOT_EMAIL" ]; then
    run_step "申请 SSL 证书" _setup_ssl_cert || true
  fi

  write_marker

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║            部署完成！                        ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local ip_addr; ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || echo '服务器IP')
  if [ -n "$DOMAIN_NAME" ]; then
    echo -e "  访问地址:  ${CYAN}http://${DOMAIN_NAME}:${DOMAIN_LISTEN_PORT}${NC}"
    echo -e "  （SSL 证书设置后可用 HTTPS: ${CYAN}https://${DOMAIN_NAME}${NC}）"
  fi
  echo -e "  IP 直连:   ${CYAN}http://${ip_addr}:${DOMAIN_LISTEN_PORT:-$ACTUAL_PORT}${NC}"
  echo -e "  管理令牌:  .env 中的 AUTH_TOKEN"
  echo ""
  echo -e "  ${BOLD}常用命令:${NC}"
  echo -e "    ${CYAN}systemctl status metapi${NC}            查看状态"
  echo -e "    ${CYAN}journalctl -u metapi -f${NC}            查看日志"
  echo -e "    ${CYAN}systemctl restart metapi${NC}           重启"
  echo ""
  echo -e "  ${BOLD}自动更新:${NC}"
  echo -e "    ${CYAN}sudo bash ${APP_DIR}/deploy/bare-metal/metapi-updater.sh --check${NC}  检查更新"
  echo -e "    ${CYAN}sudo bash ${APP_DIR}/deploy/bare-metal/metapi-updater.sh${NC}           执行更新"
  echo ""
  echo -e "  配置文件:  ${CYAN}${ENV_FILE}${NC}"
  echo -e "  数据目录:  ${CYAN}${DATA_DIR}${NC}"
  echo ""

  show_firewall_hint
}

_install_service_and_perms() {
  mkdir -p "${APP_DIR}/data"
  install_systemd_service
  set_permissions
  write_marker
}

_setup_nginx_proxy() {
  install_nginx || return 1
  configure_nginx_proxy "${DOMAIN_NAME}" "${DOMAIN_LISTEN_PORT}" "${ACTUAL_PORT}"
}

_setup_ssl_cert() {
  setup_ssl_cert "${DOMAIN_NAME}" "${CERTBOT_EMAIL}"
}

_configure_ssl_domain_interactive() {
  echo ""
  echo -e "${BOLD}${CYAN}  ── SSL 域名配置向导 ──${NC}"
  echo ""

  local current_domain="${DOMAIN_NAME}"
  local current_port="${DOMAIN_LISTEN_PORT}"
  local current_email="${CERTBOT_EMAIL}"

  if [ -n "$current_domain" ]; then
    echo -e "  当前配置:  ${CYAN}${current_domain}:${current_port:-443}${NC}"
    [ -n "$current_email" ] && echo -e "  当前邮箱:  ${CYAN}${current_email}${NC}"
    echo ""
    echo -e "  ${DIM}直接回车保留当前配置，输入新内容修改或清空。${NC}"
    echo ""
  fi

  prompt_read "  域名（留空则移除域名和 SSL 配置）: " new_domain
  if [ -z "$new_domain" ] && [ -n "$current_domain" ]; then
    DOMAIN_NAME=""
    DOMAIN_LISTEN_PORT=""
    CERTBOT_EMAIL=""
    remove_nginx_metapi_conf
    echo -e "  ${YELLOW}域名配置已移除，Nginx 配置已清理${NC}"
    prompt_read "  按回车键返回" _
    return 0
  fi

  local set_domain="${new_domain:-$current_domain}"
  [ -z "$set_domain" ] && { prompt_read "  按回车键返回" _; return 0; }

  DOMAIN_NAME="$set_domain"

  local default_port="${current_port:-443}"
  prompt_read "  外部访问端口 (默认 ${default_port}): " new_port
  DOMAIN_LISTEN_PORT="${new_port:-$default_port}"

  prompt_read "  证书邮箱（用于 Let's Encrypt，留空不申请证书）: " new_email
  [ -n "$new_email" ] && DOMAIN_LISTEN_PORT="${DOMAIN_LISTEN_PORT:-443}" && CERTBOT_EMAIL="$new_email" || CERTBOT_EMAIL=""

  echo ""
  echo -e "  ${BOLD}── 配置摘要 ──${NC}"
  echo -e "  域名:  ${CYAN}${DOMAIN_NAME}${NC}"
  echo -e "  端口:  ${CYAN}${DOMAIN_LISTEN_PORT}${NC}"
  [ -n "$CERTBOT_EMAIL" ] && echo -e "  邮箱:  ${CYAN}${CERTBOT_EMAIL}${NC}" || echo -e "  证书:  ${YELLOW}未设置${NC}"
  echo ""
  prompt_read "  确认配置？[Y/n]: " confirm

  if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
    echo -e "  ${YELLOW}已取消${NC}"
    prompt_read "  按回车键返回" _
    return 0
  fi

  ACTUAL_PORT="$(grep '^PORT=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || echo "${DEFAULT_PORT}")"

  info "安装/配置 Nginx..."
  install_nginx
  configure_nginx_proxy "${DOMAIN_NAME}" "${DOMAIN_LISTEN_PORT}" "${ACTUAL_PORT}"

  if [ -n "$CERTBOT_EMAIL" ]; then
    info "申请 SSL 证书..."
    setup_ssl_cert "${DOMAIN_NAME}" "${CERTBOT_EMAIL}"
  fi

  write_marker

  echo ""
  if [ -d "${NGINX_SSL_DIR}/${DOMAIN_NAME}" ]; then
    success "SSL 配置完成，访问: ${CYAN}https://${DOMAIN_NAME}${NC}"
  else
    success "Nginx 配置完成，访问: ${CYAN}http://${DOMAIN_NAME}:${DOMAIN_LISTEN_PORT}${NC}"
  fi

  prompt_read "  按回车键返回" _
}

do_repair() {
  COMPLETED_STEPS=()
  FAILED_STEPS=()

  echo ""
  echo -e "${BOLD}${YELLOW}  依赖修复${NC}"
  separator

  if [ ! -f "${MARKER_FILE}" ] && [ ! -d "${APP_DIR}" ]; then
    error "未检测到安装记录，请先执行安装"
    return 1
  fi

  info "诊断环境..."

  local issues=0

  if ! command -v node &>/dev/null; then
    error "✗ Node.js 未安装"; issues=$((issues + 1))
  else
    local major; major=$(node -v | sed 's/v//' | cut -d. -f1)
    [ "$major" -lt "$NODE_MAJOR" ] && { error "✗ Node.js 版本过低"; issues=$((issues + 1)); } || success "✓ Node.js $(node -v)"
  fi

  [ ! -d "${APP_DIR}" ] && { error "✗ 安装目录不存在"; issues=$((issues + 1)); } || success "✓ ${APP_DIR}"
  [ ! -f "${APP_DIR}/dist/server/index.js" ] && { error "✗ dist 缺失"; issues=$((issues + 1)); } || success "✓ dist 正常"
  [ ! -f "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" ] && { error "✗ better-sqlite3 未编译"; issues=$((issues + 1)); } || success "✓ better-sqlite3"
  [ ! -f "${SERVICE_FILE}" ] && { error "✗ systemd 服务缺失"; issues=$((issues + 1)); } || success "✓ 服务文件存在"
  [ ! -f "${ENV_FILE}" ] && { error "✗ .env 缺失"; issues=$((issues + 1)); } || success "✓ .env"

  echo ""
  [ "$issues" -eq 0 ] && { success "所有依赖正常"; return 0; }

  warn "发现 ${issues} 个问题，开始自动修复..."

  run_step "修复 Node.js" install_node || true

  if [ ! -f "${APP_DIR}/dist/server/index.js" ]; then
    run_step "下载预编译包" download_prebuilt || true
  fi
  if [ ! -f "${ENV_FILE}" ]; then
    run_step "配置环境变量" configure_env || true
  fi
  if [ ! -f "${SERVICE_FILE}" ]; then
    run_step "安装服务" install_systemd_service || true
  fi

  set_permissions

  [ -f "${SERVICE_FILE}" ] && { systemctl daemon-reload; systemctl restart "${SERVICE_NAME}" || true; }

  echo ""
  [ ${#FAILED_STEPS[@]} -eq 0 ] && success "修复完成" || warn "部分修复失败"
  systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
}

do_uninstall() {
  echo ""
  echo -e "${BOLD}${YELLOW}  卸载（保留数据）${NC}"
  separator

  echo -e "  ${CYAN}保留:${NC}  ${APP_DIR}/data, ${ENV_FILE}"
  echo -e "  ${YELLOW}删除:${NC}  服务, 代码, 用户, Swap"
  echo ""

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  local temp_data="/tmp/metapi_data_$$" temp_env="/tmp/metapi_env_$$"
  [ -d "${APP_DIR}/data" ] && mv "${APP_DIR}/data" "${temp_data}"
  [ -f "${ENV_FILE}" ] && cp -a "${ENV_FILE}" "${temp_env}"

  rm -rf "${APP_DIR:?}"/* "${APP_DIR}"/.[!.]* 2>/dev/null || true
  [ -d "${temp_data}" ] && mv "${temp_data}" "${APP_DIR}/data"
  [ -f "${temp_env}" ] && mv "${temp_env}" "${ENV_FILE}"

  rm -f "${SERVICE_FILE}"; systemctl daemon-reload 2>/dev/null || true
  id "${APP_USER}" &>/dev/null && userdel "${APP_USER}" 2>/dev/null || true

  [ -f "${SWAP_FILE}" ] && { swapoff "${SWAP_FILE}" 2>/dev/null || true; rm -f "${SWAP_FILE}"; sed -i "\|${SWAP_FILE}|d" /etc/fstab; }
  rm -f "${SYSCTL_CONF}" "${MARKER_FILE}"

  remove_nginx_metapi_conf

  echo ""
  success "卸载完成（数据已保留）"
  echo -e "  数据: ${CYAN}${APP_DIR}/data${NC}"
  echo -e "  配置: ${CYAN}${ENV_FILE}${NC}"
}

do_uninstall_all() {
  echo ""
  echo -e "${BOLD}${RED}  完整卸载（不保留数据）${NC}"
  separator
  echo -e "  ${RED}⚠ 所有数据将丢失！${NC}"
  echo ""

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${SERVICE_FILE}"; systemctl daemon-reload 2>/dev/null || true

  rm -rf "${APP_DIR}"
  id "${APP_USER}" &>/dev/null && userdel -r "${APP_USER}" 2>/dev/null || true

  [ -f "${SWAP_FILE}" ] && { swapoff "${SWAP_FILE}" 2>/dev/null || true; rm -f "${SWAP_FILE}"; sed -i "\|${SWAP_FILE}|d" /etc/fstab; }
  rm -f "${SYSCTL_CONF}"; rm -rf "${LOG_DIR}"

  remove_nginx_metapi_conf

  echo ""
  success "完整卸载完成"
}

do_upgrade() {
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║       Metapi 版本升级                         ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  if [ ! -f "${MARKER_FILE}" ]; then
    error "未检测到安装记录"
    return 1
  fi

  local current_version; current_version=$(grep '^app_version=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
  [ -z "$current_version" ] && current_version="未知"

  local arch; arch=$(detect_arch)
  if [ "$arch" = "unknown" ]; then
    error "无法识别系统架构 ($(uname -m))"
    return 1
  fi

  info "检查最新版本..."
  local release_info; release_info=$(get_latest_release)
  if [ -z "$release_info" ]; then
    error "无法获取最新版本信息（网络或 API 错误）"
    return 1
  fi

  local latest_version; latest_version=$(get_release_version "$release_info")
  if [ -z "$latest_version" ]; then
    error "无法解析最新版本号"
    return 1
  fi

  echo -e "  当前版本: ${CYAN}${current_version}${NC}"
  info "最新版本: ${latest_version}"

  if [ "$current_version" = "$latest_version" ]; then
    info "已是最新版本，无需升级"
    return 0
  fi

  local download_url; download_url=$(get_release_asset_url "$release_info" "$arch")
  if [ -z "$download_url" ]; then
    error "未找到 ${arch} 架构的预编译包"
    return 1
  fi

  echo ""
  echo -e "  ${YELLOW}版本: ${latest_version} | 架构: ${arch}${NC}"
  prompt_read "  确认升级？[y/N]: " confirm
  echo ""
  [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { info "已取消"; return 0; }

  info "下载 ${latest_version}..."
  local tmp_dir; tmp_dir=$(mktemp -d)
  local filename; filename=$(basename "$download_url")
  local tmp_file="${tmp_dir}/${filename}"

  if ! curl -fSL --connect-timeout 30 --max-time 600 --progress-bar -o "$tmp_file" "$download_url" 2>&1; then
    error "下载失败"
    rm -rf "${tmp_dir}"
    return 1
  fi

  info "解压..."
  if ! tar -xzf "$tmp_file" -C "$tmp_dir" 2>&1; then
    error "解压失败"
    rm -rf "${tmp_dir}"
    return 1
  fi

  local extracted_dir
  extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "metapi-*" | head -1)
  [ -z "$extracted_dir" ] && extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d | tail -1)

  if [ -z "$extracted_dir" ] || [ ! -d "${extracted_dir}/dist" ]; then
    error "预编译包结构异常"
    rm -rf "${tmp_dir}"
    return 1
  fi

  local env_backup="/tmp/metapi_env_upgrade_$$"
  local data_backup="/tmp/metapi_data_upgrade_$$"
  [ -f "${ENV_FILE}" ] && cp -a "${ENV_FILE}" "${env_backup}"
  [ -d "${DATA_DIR}" ] && cp -a "${DATA_DIR}" "${data_backup}"

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  rm -rf "${APP_DIR:?}"/* "${APP_DIR}"/.[!.]* 2>/dev/null || true
  cp -a "${extracted_dir}/." "${APP_DIR}/"

  [ -f "${env_backup}" ] && cp -a "${env_backup}" "${ENV_FILE}"
  [ -d "${data_backup}" ] && cp -a "${data_backup}/." "${DATA_DIR}/"
  rm -rf "${tmp_dir}" "${env_backup}" "${data_backup}"

  write_marker
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" 2>/dev/null || true
  install_systemd_service
  systemctl start "${SERVICE_NAME}"

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    success "升级完成，${SERVICE_NAME} ${latest_version} 已启动"
    return 0
  else
    error "升级完成，但服务启动失败"
    journalctl -u "${SERVICE_NAME}" -n 15 --no-pager 2>/dev/null
    return 1
  fi
}

view_service_logs() {
  echo ""
  echo -e "${BOLD}${CYAN}  ── 运行日志（最近 30 行） ──${NC}"
  echo ""
  if [ ! -f "${SERVICE_FILE}" ]; then
    echo -e "  ${YELLOW}服务尚未安装${NC}"
    return 0
  fi
  journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null || echo "  （无日志）"
  echo ""
}

main() {
  parse_args "$@"
  preflight_check

  case "${FORCE_MODE}" in
    uninstall)     do_uninstall ;;
    uninstall-all) do_uninstall_all ;;
    repair)        do_repair ;;
    *)             do_install ;;
  esac
}

main "$@"
