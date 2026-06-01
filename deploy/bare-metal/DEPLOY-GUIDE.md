# Metapi 裸机部署完整指南

> 本文档独立于项目主 README，避免上游更新时被覆盖。
> 适用于 Ubuntu 22.04，2核1G 及以下低配置服务器。

---

## 目录

- [架构说明](#架构说明)
- [部署方式对比](#部署方式对比)
- [方式一：交互式脚本部署（推荐）](#方式一交互式脚本部署推荐)
- [方式二：手动部署（预编译下载）](#方式二手动部署预编译下载)
- [方式三：手动部署（源码编译）](#方式三手动部署源码编译)
- [方式四：Alpine 精简版 Docker](#方式四alpine-精简版-docker)
- [CI/CD 预编译发布](#cicd-预编译发布)
- [更新与升级](#更新与升级)
- [自动更新配置](#自动更新配置)
- [上游同步与保护策略](#上游同步与保护策略)
- [常用运维命令](#常用运维命令)
- [Nginx 反向代理](#nginx-反向代理)
- [故障排除](#故障排除)

---

## 架构说明

### 编译在哪里发生？

```
┌─────────────────────────────────────────────────────────┐
│  GitHub Actions CI/CD（编译发生在云端）                    │
│                                                         │
│  git push → npm ci → npm build → 打包 tar.gz            │
│                           ↓                             │
│                    GitHub Release                        │
└─────────────────────────────┬───────────────────────────┘
                              │ 下载预编译包
                              ↓
┌─────────────────────────────────────────────────────────┐
│  你的服务器（2核1G）                                      │
│                                                         │
│  下载 tar.gz → 解压 → 启动（无需编译！）                   │
│                                                         │
│  资源需求: 仅需 Node.js 运行时，不需要 python3/make/g++    │
│  磁盘占用: ~300MB（vs 源码编译 ~500MB）                   │
└─────────────────────────────────────────────────────────┘
```

**预编译下载模式（推荐）**：编译在 GitHub 上完成，服务器只下载和运行，对服务器配置要求最低。

**源码编译模式（备选）**：服务器上 `git clone` + `npm build`，需要更多内存和时间。

---

## 部署方式对比

| 部署方式 | 预估内存 | 磁盘占用 | 编译位置 | 适用场景 |
|---------|---------|---------|---------|---------|
| **预编译下载（推荐）** | **~115-180MB** | **~300MB** | **GitHub CI** | **2核1G 低配服务器** |
| 源码编译 | ~200-300MB | ~500MB | 服务器本地 | 需要自定义修改 |
| Docker Compose（官方） | ~200-350MB | ~800MB | Docker 内 | 有 Docker 环境 |
| Docker Alpine Lite | ~150-280MB | ~300MB | Docker 内 | 需要 Docker 但想省资源 |

---

## 方式一：交互式脚本部署（推荐）

### 一键安装

```bash
# 方式 A：从 GitHub Release 下载预编译包（最低资源需求）
# 先在 GitHub Releases 页面下载最新包
curl -fsSLO https://github.com/zczy-k/metapi/releases/latest/download/metapi-XXX-linux-amd64.tar.gz
tar -xzf metapi-*.tar.gz
cd metapi-*/
sudo bash deploy/bare-metal/metapi-deploy.sh

# 方式 B：克隆仓库（包含部署脚本）
git clone https://github.com/zczy-k/metapi.git /tmp/metapi
cd /tmp/metapi
sudo bash deploy/bare-metal/metapi-deploy.sh
```

### 脚本菜单

```
  1) 新装       — 选择「预编译下载」或「源码编译」模式
  2) 依赖修复   — 诊断并修复环境问题
  3) 卸载
     ├── 保留数据   — 删除程序，保留数据库和配置
     └── 完整卸载   — 删除一切（需二次确认）
  4) 退出
```

### 两种安装模式

| 模式 | 服务器要求 | 安装时间 | 说明 |
|------|----------|---------|------|
| **预编译下载** | Node.js 运行时 + 300MB 磁盘 | ~2 分钟 | 从 GitHub Release 下载已编译好的包 |
| 源码编译 | Node.js + python3/make/g++ + 500MB 磁盘 + 1G+ 内存 | ~10-20 分钟 | 在服务器上克隆并编译 |

预编译下载模式会自动检测系统架构（amd64/arm64），从 GitHub Release 下载对应的预编译包。

---

## 方式二：手动部署（预编译下载）

适用于不想用交互脚本、只需要最简单的步骤：

```bash
# 1. 下载预编译包（替换版本号和架构）
VERSION=1.3.0  # 查看 https://github.com/zczy-k/metapi/releases/latest
ARCH=amd64     # amd64 或 arm64
curl -fsSLO "https://github.com/zczy-k/metapi/releases/download/v${VERSION}/metapi-${VERSION}-linux-${ARCH}.tar.gz"

# 2. 解压到安装目录
tar -xzf metapi-${VERSION}-linux-${ARCH}.tar.gz
sudo mv metapi-${VERSION}-linux-${ARCH} /opt/metapi

# 3. 安装 Node.js 运行时（如果还没有）
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 4. 配置环境变量
cd /opt/metapi
cp deploy/bare-metal/.env.example .env
# 编辑 .env，设置 AUTH_TOKEN 和 PROXY_TOKEN
sudo vim .env

# 5. 创建用户并启动
sudo useradd -r -s /bin/false metapi
sudo chown -R metapi:metapi /opt/metapi
sudo -u metapi node dist/server/db/migrate.js
sudo -u metapi node dist/server/index.js
```

---

## 方式三：手动部署（源码编译）

### 1. 安装 Node.js 22+

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### 2. 安装编译依赖

```bash
sudo apt-get install -y python3 make g++ git curl
```

### 3. 克隆并构建

```bash
git clone https://github.com/zczy-k/metapi.git /opt/metapi
cd /opt/metapi

npm ci --ignore-scripts --no-audit --no-fund
npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund
npm run build:web
npm run build:server
npm prune --omit=dev --no-audit --no-fund
```

### 4. 配置环境变量

```bash
cp deploy/bare-metal/.env.example .env
vim .env  # 修改 AUTH_TOKEN 和 PROXY_TOKEN
```

### 5. 启动（同方式二步骤 5）

---

## 方式四：Alpine 精简版 Docker

```bash
docker build -f docker/Dockerfile.alpine -t metapi:alpine .
docker run -d --name metapi \
  -p 4000:4000 \
  -e AUTH_TOKEN=your-admin-token \
  -e PROXY_TOKEN=your-proxy-sk-token \
  -e TZ=Asia/Shanghai \
  -v ./data:/app/data \
  --restart unless-stopped \
  metapi:alpine
```

---

## CI/CD 预编译发布

项目已配置 GitHub Actions 自动构建（`.github/workflows/build-release.yml`）：

### 触发方式

| 方式 | 说明 |
|------|------|
| 推送 tag | `git tag v1.3.0 && git push origin v1.3.0` 自动构建并发布 |
| 手动触发 | GitHub → Actions → Build & Release → Run workflow |

### 构建产物

每次发布会生成：
- `metapi-{version}-linux-amd64.tar.gz` — x86_64 服务器
- `metapi-{version}-linux-arm64.tar.gz` — ARM64 服务器

### 在自己的 Fork 上启用

1. Fork `zczy-k/metapi` 到你的 GitHub 账号
2. 在 Fork 仓库的 Settings → Actions → General 中启用 Actions
3. 推送 tag 或手动触发 workflow 即可
4. 修改 `.env` 中的 `UPDATE_CHECK_URL` 指向你的 Fork：

```bash
UPDATE_CHECK_URL=https://api.github.com/repos/YOUR_USERNAME/metapi/releases/latest
```

---

## 更新与升级

### 自动更新（推荐）

```bash
# 检查更新
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh --check

# 执行更新
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh
```

更新脚本会根据安装模式自动选择：
- **预编译安装** → 从 GitHub Release 下载新版本
- **源码安装** → git pull + 重新构建

### 手动更新（预编译模式）

```bash
# 1. 下载新版本
curl -fsSLO https://github.com/zczy-k/metapi/releases/download/vX.Y.Z/metapi-X.Y.Z-linux-amd64.tar.gz

# 2. 停止服务
sudo systemctl stop metapi

# 3. 备份 .env 和 data/
cp /opt/metapi/.env /tmp/metapi-env-backup
cp -a /opt/metapi/data /tmp/metapi-data-backup

# 4. 解压覆盖
tar -xzf metapi-*.tar.gz
rm -rf /opt/metapi/* /opt/metapi/.[!.]* 2>/dev/null
cp -a metapi-*/. /opt/metapi/

# 5. 恢复配置和数据
cp /tmp/metapi-env-backup /opt/metapi/.env
cp -a /tmp/metapi-data-backup/. /opt/metapi/data/

# 6. 重启
sudo systemctl start metapi
```

### 手动更新（源码模式）

```bash
cd /opt/metapi
git stash
git pull origin main
git stash pop

npm ci --ignore-scripts --no-audit --no-fund
npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund
npm run build:web && npm run build:server
npm prune --omit=dev --no-audit --no-fund

sudo systemctl restart metapi
```

---

## 自动更新配置

### 方案 A：systemd timer（推荐）

```bash
# 安装 timer
sudo cp /opt/metapi/deploy/bare-metal/metapi-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now metapi-update.timer

# 查看状态
systemctl list-timers metapi-update.timer
```

**自定义检查频率：**

```bash
# 修改为每 6 小时
sudo systemctl edit metapi-update.timer
# 添加:
# [Timer]
# OnCalendar=*-*-* 00/6:00:00
```

### 方案 B：cron

```bash
echo '0 3 * * * root /opt/metapi/deploy/bare-metal/metapi-updater.sh --yes >> /var/log/metapi/update.log 2>&1' | sudo tee /etc/cron.d/metapi-update
```

### 更新通知

在 `.env` 中配置 Webhook：

```bash
WEBHOOK_URL=https://hooks.slack.com/services/xxx
```

---

## 上游同步与保护策略

### 覆盖风险分析

| 文件 | 风险 | 说明 |
|------|------|------|
| `README.md` | ⚠️ 高 | 上游频繁更新 → 已移出详细内容到本文档 |
| `deploy/bare-metal/*` | ✅ 低 | 新目录，上游不太可能有同名文件 |
| `.github/workflows/build-release.yml` | ⚠️ 中 | 上游可能未来添加自己的 workflow |
| `.env` / `data/` | ✅ 无 | 本地文件，不在 git 追踪中 |

### 推荐策略：Fork + CI/CD

1. Fork 仓库到你的 GitHub 账号
2. 在 Fork 上启用 GitHub Actions
3. 推送 tag 触发构建
4. 服务器从你的 Fork Release 下载

### 预编译模式天然保护

**使用预编译下载模式时，服务器上没有 `.git` 目录，上游更新不会覆盖你的文件。** 更新由 `metapi-updater.sh` 控制，它会：
- 保护 `.env` 和 `data/` 不被覆盖
- 备份当前版本
- 失败时自动回滚

---

## 常用运维命令

```bash
# systemd 方式
systemctl status metapi         # 查看状态
journalctl -u metapi -f         # 查看实时日志
systemctl restart metapi         # 重启
systemctl stop metapi            # 停止

# 更新
bash /opt/metapi/deploy/bare-metal/metapi-updater.sh --check  # 检查
bash /opt/metapi/deploy/bare-metal/metapi-updater.sh           # 更新

# 数据库备份
cp -a /opt/metapi/data /backup/metapi-data-$(date +%Y%m%d)
```

---

## Nginx 反向代理

```nginx
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 300s;
        gzip on;
        gzip_types text/plain text/css application/json application/javascript text/xml;
    }
}
```

---

## 故障排除

| 问题 | 解决方案 |
|------|---------|
| 预编译包无对应架构 | 使用源码编译模式，或在 Fork 上配置 CI/CD 构建你的架构 |
| `better-sqlite3` 加载失败 | 架构不匹配，确认下载了正确的预编译包（amd64/arm64） |
| 内存不足 | 增加 swap，降低 `--max-old-space-size` 值 |
| 端口被占用 | 修改 `.env` 中的 `PORT` 值 |
| GitHub Release 未找到 | 项目可能尚未发布预编译包，使用源码编译模式 |
| 更新后服务无法启动 | `journalctl -u metapi -n 50` 查看日志，或执行依赖修复 |
