#!/usr/bin/env bash
#
# ╔════════════════════════════════════════════════════════════╗
# ║  Metapi 自动更新脚本 v3                                    ║
# ║  支持: GitHub Release 预编译下载 / 源码 git pull / 通知    ║
# ╚════════════════════════════════════════════════════════════╝
#
# 用法:
#   sudo bash metapi-updater.sh           # 交互式更新
#   sudo bash metapi-updater.sh --yes     # 非交互式（适合 cron）
#   sudo bash metapi-updater.sh --check   # 仅检查，不更新

set -uo pipefail

# ═══════════════════════════════════════════════════════════
# 常量
# ═══════════════════════════════════════════════════════════
readonly APP_NAME="metapi"
readonly APP_DIR="/opt/metapi"
readonly SERVICE_NAME="metapi"
readonly MARKER_FILE="${APP_DIR}/.metapi_installed"
readonly LOG_DIR="/var/log/${APP_NAME}"
readonly UPDATE_LOG="${LOG_DIR}/update.log"
readonly BACKUP_DIR="/var/backups/metapi"
readonly MAX_BACKUPS=5

# GitHub Release 配置
readonly DEFAULT_RELEASE_API="https://api.github.com/repos/zczy-k/metapi/releases/latest"
readonly REPO_URL="https://github.com/zczy-k/metapi.git"

# 需要保护的不追踪文件/目录
readonly PROTECTED_ITEMS=(".env" "data")

# ═══════════════════════════════════════════════════════════
# 颜色
# ═══════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; log "INFO" "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARN" "$*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; log "ERROR" "$*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; log "OK" "$*"; }
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $*" >> "${UPDATE_LOG}" 2>/dev/null || true; }

separator() { echo -e "${CYAN}──────────────────────────────────────────${NC}"; }

prompt_read() {
  if [ -t 0 ] || [ -e /dev/tty ]; then
    read -rp "$1" "$2" < /dev/tty
  else
    read -rp "$1" "$2"
  fi
}

# ═══════════════════════════════════════════════════════════
# 参数解析
# ═══════════════════════════════════════════════════════════
AUTO_YES=false
CHECK_ONLY=false
FORCE=false
MODE=""  # auto | release | source

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=true; shift ;;
    --check)  CHECK_ONLY=true; shift ;;
    --force)  FORCE=true; shift ;;
    --release) MODE="release"; shift ;;
    --source)  MODE="source"; shift ;;
    --help|-h)
      echo "用法: sudo bash $0 [--yes] [--check] [--force] [--release|--source]"
      echo ""
      echo "  --yes      非交互式，自动确认所有操作"
      echo "  --check    仅检查更新，不执行"
      echo "  --force    强制更新，即使版本相同"
      echo "  --release  仅使用 GitHub Release 预编译下载"
      echo "  --source   仅使用源码 git pull + 重建"
      echo "  (默认)     根据安装模式自动选择"
      exit 0
      ;;
    *) warn "未知参数: $1"; shift ;;
  esac
done

# ═══════════════════════════════════════════════════════════
# 前置检查
# ═══════════════════════════════════════════════════════════
preflight() {
  if [ "$(id -u)" -ne 0 ]; then
    error "需要 root 权限，请使用: sudo bash $0"
    exit 1
  fi

  if [ ! -f "${MARKER_FILE}" ] && [ ! -d "${APP_DIR}" ]; then
    error "安装目录 ${APP_DIR} 不存在，请先运行部署脚本"
    exit 1
  fi

  mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"
  touch "${UPDATE_LOG}"
}

# ═══════════════════════════════════════════════════════════
# 工具函数
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

get_current_version() {
  # 优先从 .build-info 读取
  if [ -f "${APP_DIR}/.build-info" ]; then
    grep '^version=' "${APP_DIR}/.build-info" 2>/dev/null | cut -d= -f2
    return
  fi
  # 从 git tag 读取
  if [ -d "${APP_DIR}/.git" ]; then
    cd "${APP_DIR}"
    git describe --tags --always 2>/dev/null | sed 's/^v//' || echo "unknown"
    return
  fi
  echo "unknown"
}

get_install_mode() {
  if [ -n "${MODE}" ]; then echo "${MODE}"; return; fi
  # 从 marker 读取
  if [ -f "${MARKER_FILE}" ]; then
    local mode; mode=$(grep '^install_mode=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2)
    if [ -n "$mode" ]; then echo "$mode"; return; fi
  fi
  # 推断
  if [ -d "${APP_DIR}/.git" ]; then echo "source"; else echo "release"; fi
}

get_release_api_url() {
  # 从 .env 读取自定义 URL
  local custom_url
  custom_url=$(grep '^UPDATE_CHECK_URL=' "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2)
  echo "${custom_url:-${DEFAULT_RELEASE_API}}"
}

# ═══════════════════════════════════════════════════════════
# 检查 GitHub Release 更新
# ═══════════════════════════════════════════════════════════
check_release_update() {
  local api_url; api_url=$(get_release_api_url)
  local current_version; current_version=$(get_current_version)
  local arch; arch=$(detect_arch)

  info "当前版本: ${current_version} (架构: ${arch})"
  info "检查 GitHub Release 更新..."
  info "Release API: ${api_url}"

  local release_info
  release_info=$(curl -sf --connect-timeout 15 --max-time 15 \
    -H "Accept: application/vnd.github+json" \
    "$api_url" 2>/dev/null)

  if [ -z "$release_info" ]; then
    error "无法获取 GitHub Release 信息，请检查网络"
    return 1
  fi

  local latest_version
  latest_version=$(echo "$release_info" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1 | sed 's/^v//')

  if [ -z "$latest_version" ]; then
    error "无法解析最新版本号"
    return 1
  fi

  info "最新版本: ${latest_version}"

  # 版本比较
  if [ "$current_version" = "$latest_version" ] && [ "${FORCE}" = false ]; then
    info "已是最新版本 (${latest_version})，无需更新"
    return 2  # 无需更新
  fi

  # 查找下载链接
  local download_url
  download_url=$(echo "$release_info" | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' | grep "linux-${arch}")

  if [ -z "$download_url" ]; then
    warn "GitHub Release 中未找到 ${arch} 架构的预编译包"
    if [ "$(get_install_mode)" = "source" ] || [ "${MODE}" = "source" ]; then
      info "将尝试源码更新模式..."
      return 3  # 回退到源码模式
    fi
    error "无可用的预编译包，请使用 --source 模式或手动更新"
    return 1
  fi

  # 显示更新信息
  local release_notes
  release_notes=$(echo "$release_info" | grep -oP '"body"\s*:\s*"\K[^"]*' | head -1 | sed 's/\\n/\n/g' | head -20)

  echo ""
  separator
  echo -e "${BOLD}  发现新版本${NC}"
  separator
  echo -e "  当前版本:  ${CYAN}${current_version}${NC}"
  echo -e "  最新版本:  ${GREEN}${latest_version}${NC}"
  echo -e "  下载地址:  ${DIM}${download_url}${NC}"
  echo ""

  # 保存给后面用
  LATEST_VERSION="$latest_version"
  DOWNLOAD_URL="$download_url"

  return 0
}

# ═══════════════════════════════════════════════════════════
# 检查源码更新（git pull）
# ═══════════════════════════════════════════════════════════
check_source_update() {
  local current_commit
  current_commit=$(cd "${APP_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

  info "当前版本: ${current_commit}"
  info "检查源码更新..."

  cd "${APP_DIR}"

  if ! git fetch origin main 2>&1; then
    error "无法获取远程更新"
    return 1
  fi

  local new_commit
  new_commit=$(git rev-parse --short origin/main 2>/dev/null)

  if [ "$current_commit" = "$new_commit" ] && [ "${FORCE}" = false ]; then
    info "已是最新版本 (${current_commit})"
    return 2
  fi

  local commit_count
  commit_count=$(git rev-list "${current_commit}..origin/main" --count 2>/dev/null || echo "?")

  echo ""
  separator
  echo -e "${BOLD}  发现源码更新${NC}"
  separator
  echo -e "  当前:  ${CYAN}${current_commit}${NC}"
  echo -e "  最新:  ${GREEN}${new_commit}${NC}"
  echo -e "  提交数: ${commit_count}"
  echo ""

  if [ "$commit_count" != "?" ] && [ "$commit_count" -gt 0 ]; then
    echo -e "  ${BOLD}更新内容:${NC}"
    git log --oneline "${current_commit}..origin/main" 2>/dev/null | head -15 | while read -r line; do
      echo -e "    ${DIM}${line}${NC}"
    done
  fi

  NEW_COMMIT="$new_commit"
  return 0
}

# ═══════════════════════════════════════════════════════════
# 备份当前版本
# ═══════════════════════════════════════════════════════════
backup_current() {
  local backup_name="metapi-$(date '+%Y%m%d_%H%M%S')-$(get_current_version).tar.gz"
  local backup_path="${BACKUP_DIR}/${backup_name}"

  info "备份当前版本..."

  tar -czf "${backup_path}" \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='data/*.db-wal' \
    --exclude='data/*.db-shm' \
    -C "$(dirname "${APP_DIR}")" \
    "$(basename "${APP_DIR}")" 2>/dev/null || true

  if [ -f "${backup_path}" ]; then
    local size; size=$(du -sh "${backup_path}" 2>/dev/null | cut -f1)
    success "备份完成: ${backup_path} (${size})"
  else
    warn "备份失败，继续更新（风险自担）"
  fi

  # 清理旧备份
  local count; count=$(find "${BACKUP_DIR}" -name "metapi-*.tar.gz" | wc -l)
  if [ "$count" -gt "${MAX_BACKUPS}" ]; then
    find "${BACKUP_DIR}" -name "metapi-*.tar.gz" -printf '%T+ %p\n' | sort | head -n $((count - MAX_BACKUPS)) | awk '{print $2}' | xargs rm -f
  fi
}

# ═══════════════════════════════════════════════════════════
# [Release 模式] 下载并安装预编译包
# ═══════════════════════════════════════════════════════════
do_release_update() {
  local download_url="$1"
  local version="$2"

  info "下载预编译包 v${version}..."

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

  # 找到解压后的目录
  local extracted_dir
  extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "metapi-*" | head -1)
  [ -z "$extracted_dir" ] && extracted_dir=$(find "$tmp_dir" -maxdepth 1 -type d | tail -1)

  if [ -z "$extracted_dir" ] || [ ! -d "${extracted_dir}/dist" ]; then
    error "预编译包结构异常"
    rm -rf "${tmp_dir}"
    return 1
  fi

  # 停止服务
  info "停止服务..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

  # 保护 .env 和 data/
  local temp_env="/tmp/metapi_env_$$" temp_data="/tmp/metapi_data_$$"
  [ -f "${APP_DIR}/.env" ] && cp -a "${APP_DIR}/.env" "${temp_env}"
  [ -d "${APP_DIR}/data" ] && cp -a "${APP_DIR}/data" "${temp_data}"

  # 替换文件
  info "替换文件..."
  rm -rf "${APP_DIR:?}"/* "${APP_DIR}"/.[!.]* 2>/dev/null || true
  cp -a "${extracted_dir}/." "${APP_DIR}/"

  # 恢复 .env 和 data/
  [ -f "${temp_env}" ] && cp -a "${temp_env}" "${APP_DIR}/.env" && rm -f "${temp_env}"
  [ -d "${temp_data}" ] && cp -a "${temp_data}/." "${APP_DIR}/data/" && rm -rf "${temp_data}"

  # 清理
  rm -rf "${tmp_dir}"

  # 验证
  if [ ! -f "${APP_DIR}/dist/server/index.js" ]; then
    error "更新验证失败: dist/server/index.js 不存在"
    return 1
  fi

  success "预编译包更新完成"
  return 0
}

# ═══════════════════════════════════════════════════════════
# [Source 模式] git pull + 重建
# ═══════════════════════════════════════════════════════════
do_source_update() {
  cd "${APP_DIR}"

  info "停止服务..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

  # 保护本地文件
  info "保护本地修改..."
  local stashed=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    if ! git stash push -m "auto-update-$(date '+%Y%m%d_%H%M%S')" 2>&1; then
      error "git stash 失败，中止更新"
      return 1
    fi
    stashed=true
  fi

  # 保护 .env 和 data/
  local temp_env="/tmp/metapi_env_$$" temp_data="/tmp/metapi_data_$$"
  [ -f "${APP_DIR}/.env" ] && cp -a "${APP_DIR}/.env" "${temp_env}"
  [ -d "${APP_DIR}/data" ] && cp -a "${APP_DIR}/data" "${temp_data}"

  # git pull
  info "拉取更新..."
  if ! git merge --ff-only origin/main 2>&1; then
    warn "fast-forward 合并失败，尝试 rebase..."
    if ! git rebase origin/main 2>&1; then
      error "合并失败，回滚..."
      git rebase --abort 2>/dev/null || true
      [ "$stashed" = true ] && git stash pop 2>/dev/null || true
      return 1
    fi
  fi

  # 恢复 stash
  [ "$stashed" = true ] && { git stash pop 2>/dev/null || warn "stash pop 冲突，已保留本地修改"; }

  # 恢复 .env 和 data/
  [ -f "${temp_env}" ] && cp -a "${temp_env}" "${APP_DIR}/.env" && rm -f "${temp_env}"
  [ -d "${temp_data}" ] && cp -a "${temp_data}/." "${APP_DIR}/data/" && rm -rf "${temp_data}"

  # 重新构建
  info "重新构建..."
  local build_log="${LOG_DIR}/build.log"

  if ! npm ci --ignore-scripts --no-audit --no-fund 2>&1 | tee -a "${build_log}" | tail -5; then
    # 尝试镜像
    npm config set registry https://registry.npmmirror.com 2>/dev/null
    if ! npm ci --ignore-scripts --no-audit --no-fund 2>&1 | tail -5; then
      error "npm ci 失败"; npm config delete registry 2>/dev/null; return 1
    fi
    npm config delete registry 2>/dev/null
  fi

  npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund 2>&1 | tail -5 || true

  if ! npm run build:web 2>&1 | tee -a "${build_log}" | tail -5; then
    rm -rf node_modules/.vite node_modules/.cache 2>/dev/null
    if ! npm run build:web 2>&1 | tail -5; then error "前端构建失败"; return 1; fi
  fi

  if ! npm run build:server 2>&1 | tee -a "${build_log}" | tail -5; then
    error "后端构建失败"; return 1
  fi

  npm prune --omit=dev --no-audit --no-fund 2>&1 | tail -3

  if [ ! -f "dist/server/index.js" ]; then
    error "构建验证失败"; return 1
  fi

  success "源码更新并重建完成"
  return 0
}

# ═══════════════════════════════════════════════════════════
# 重启服务
# ═══════════════════════════════════════════════════════════
restart_service() {
  info "重启服务..."

  # 恢复权限
  local target_user; target_user=$(grep '^user=' "${MARKER_FILE}" 2>/dev/null | cut -d= -f2 || echo "metapi")
  chown -R "${target_user}:${target_user}" "${APP_DIR}" 2>/dev/null || true
  chmod 600 "${APP_DIR}/.env" 2>/dev/null || true

  # 数据库迁移
  info "执行数据库迁移..."
  sudo -u "${target_user}" node dist/server/db/migrate.js 2>&1 | tail -3 || true

  # 重启
  systemctl start "${SERVICE_NAME}"

  local retry=0
  while [ $retry -lt 20 ]; do
    if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
      success "服务启动成功"
      return 0
    fi
    retry=$((retry + 1)); sleep 1
  done

  error "服务启动失败"
  echo -e "  查看日志: ${CYAN}journalctl -u ${SERVICE_NAME} -n 50 --no-pager${NC}"
  return 1
}

# ═══════════════════════════════════════════════════════════
# 通知
# ═══════════════════════════════════════════════════════════
send_notification() {
  local status="$1" message="$2"

  local webhook_url
  webhook_url=$(grep '^WEBHOOK_URL=' "${APP_DIR}/.env" 2>/dev/null | cut -d= -f2)
  [ -z "$webhook_url" ] && return 0

  local color title
  [ "$status" = "success" ] && { color="3668174"; title="✅ Metapi 更新成功"; } || { color="15158332"; title="❌ Metapi 更新失败"; }

  curl -sf --connect-timeout 5 --max-time 10 \
    -H "Content-Type: application/json" \
    -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${message}\",\"color\":${color}}]}" \
    "${webhook_url}" >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════
# 主更新流程
# ═══════════════════════════════════════════════════════════
LATEST_VERSION=""
DOWNLOAD_URL=""
NEW_COMMIT=""
PREV_VERSION=""

do_update() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║     Metapi 自动更新                          ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  preflight

  # 确定更新模式
  local update_mode; update_mode=$(get_install_mode)
  if [ -n "${MODE}" ]; then update_mode="${MODE}"; fi

  info "更新模式: ${update_mode}"

  PREV_VERSION=$(get_current_version)

  # ═══════ 检查更新 ═══════

  if [ "$update_mode" = "release" ] || [ "$update_mode" = "prebuilt" ]; then
    # 预编译模式：先尝试 GitHub Release
    if ! check_release_update; then
      local result=$?
      if [ $result -eq 2 ]; then
        # 无需更新
        exit 0
      elif [ $result -eq 3 ]; then
        # 无预编译包，回退到源码模式
        if [ -d "${APP_DIR}/.git" ]; then
          warn "无可用的预编译包，回退到源码更新模式"
          update_mode="source"
        else
          error "无可用的预编译包，且非 git 仓库无法源码更新"
          exit 1
        fi
      else
        error "检查更新失败"
        exit 1
      fi
    fi
  fi

  if [ "$update_mode" = "source" ]; then
    if [ ! -d "${APP_DIR}/.git" ]; then
      error "非 git 仓库，无法使用源码更新模式"
      exit 1
    fi
    if ! check_source_update; then
      local result=$?
      [ $result -eq 2 ] && exit 0  # 无需更新
      exit 1
    fi
  fi

  # 仅检查模式
  if [ "${CHECK_ONLY}" = true ]; then
    echo ""
    info "检测到可用更新，使用不带 --check 的命令执行更新"
    exit 0
  fi

  # 确认
  if [ "${AUTO_YES}" = false ]; then
    echo ""
    prompt_read "是否执行更新？[y/N] " yn
    [[ "$yn" != "y" && "$yn" != "Y" ]] && { info "已取消"; exit 0; }
  fi

  # 备份
  separator
  backup_current

  # 执行更新
  separator
  local update_ok=false

  if [ "$update_mode" = "release" ] || [ "$update_mode" = "prebuilt" ]; then
    if do_release_update "$DOWNLOAD_URL" "$LATEST_VERSION"; then
      update_ok=true
    fi
  elif [ "$update_mode" = "source" ]; then
    if do_source_update; then
      update_ok=true
    fi
  fi

  if [ "$update_ok" = false ]; then
    error "更新失败"
    send_notification "failure" "更新失败 (模式: ${update_mode})"
    exit 1
  fi

  # 重启服务
  separator
  if ! restart_service; then
    send_notification "failure" "更新成功但服务启动失败 (v${PREV_VERSION} → ${LATEST_VERSION:-${NEW_COMMIT}})"
    exit 1
  fi

  # 更新 marker
  if [ -f "${MARKER_FILE}" ]; then
    local new_version="${LATEST_VERSION:-${NEW_COMMIT}}"
    sed -i "s/^install_time=.*/install_time=$(date '+%Y-%m-%d %H:%M:%S')/" "${MARKER_FILE}" 2>/dev/null || true
    sed -i "s/^version=.*/version=${new_version}/" "${MARKER_FILE}" 2>/dev/null || true
  fi

  # 完成
  local new_ver="${LATEST_VERSION:-${NEW_COMMIT}}"
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║     更新完成！                               ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  旧版本:  ${CYAN}${PREV_VERSION}${NC}"
  echo -e "  新版本:  ${GREEN}${new_ver}${NC}"
  echo -e "  更新模式: ${CYAN}${update_mode}${NC}"
  echo ""

  send_notification "success" "已从 v${PREV_VERSION} 更新到 v${new_ver} (模式: ${update_mode})"
}

do_update
