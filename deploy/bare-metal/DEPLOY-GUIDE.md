# Metapi 裸机部署完整指南

> 本文档独立于项目主 README，避免上游更新时被覆盖。
> 适用于 Ubuntu 22.04，2核1G 及以下低配置服务器。

---

## 目录

- [一键部署](#一键部署)
- [架构说明](#架构说明)
- [部署方式对比](#部署方式对比)
- [命令行参数](#命令行参数)
- [非交互式部署](#非交互式部署)
- [CI/CD 预编译发布](#cicd-预编译发布)
- [更新与升级](#更新与升级)
- [自动更新配置](#自动更新配置)
- [上游同步与保护策略](#上游同步与保护策略)
- [常用运维命令](#常用运维命令)
- [Nginx 反向代理](#nginx-反向代理)
- [故障排除](#故障排除)

---

## 一键部署

### 最简方式（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh | sudo bash -s --
```

脚本会**全自动完成**：

1. ✅ 检测系统平台（amd64 / arm64）
2. ✅ 检测网络连通性
3. ✅ 安装 Node.js 22 运行时
4. ✅ 从 GitHub Release 下载对应架构的预编译包
5. ✅ 创建隔离用户、配置 Swap（低内存自动）
6. ✅ 提示输入 `AUTH_TOKEN` 和 `PROXY_TOKEN`（唯一需要手动输入的步骤）
7. ✅ 安装 systemd 服务并启动
8. ✅ 如果预编译包不可用，自动切换到源码编译模式

**整个过程用户只需输入两个令牌，其他全部自动。**

### 非交互式部署

```bash
# 指定令牌，完全无需交互
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh | \
  sudo bash -s -- --token YOUR_ADMIN_TOKEN --proxy-token YOUR_PROXY_TOKEN
```

### 先下载再部署

```bash
# 如果 curl 管道方式不便使用
wget https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh
sudo bash metapi-deploy.sh
```

---

## 架构说明

```
┌─────────────────────────────────────────────────────────┐
│  GitHub Actions CI/CD（编译发生在云端）                    │
│                                                         │
│  git tag v* → npm ci → npm build → 打包 tar.gz          │
│                                    ↓                    │
│                             GitHub Release               │
└─────────────────────────────┬───────────────────────────┘
                              │ 下载预编译包
                              ↓
┌─────────────────────────────────────────────────────────┐
│  你的服务器（2核1G）                                      │
│                                                         │
│  metapi-deploy.sh 自动:                                  │
│    1. 检测架构 (amd64/arm64)                              │
│    2. 下载对应的 tar.gz                                   │
│    3. 解压 → 安装 Node.js → 配置 → 启动                  │
│                                                         │
│  资源需求: 仅需 Node.js 运行时，不需要 python3/make/g++    │
│  磁盘占用: ~300MB（vs 源码编译 ~500MB）                   │
└─────────────────────────────────────────────────────────┘
```

**预编译下载模式（默认）**：编译在 GitHub 上完成，服务器只下载和运行。

**源码编译模式（自动回退）**：当预编译包不可用时自动切换，在服务器上编译。

---

## 部署方式对比

| 部署方式 | 预估内存 | 磁盘占用 | 编译位置 | 适用场景 |
|---------|---------|---------|---------|---------|
| **预编译下载（默认）** | **~115-180MB** | **~300MB** | **GitHub CI** | **2核1G 低配服务器** |
| 源码编译（自动回退） | ~200-300MB | ~500MB | 服务器本地 | 预编译包不可用时 |
| Docker Compose（官方） | ~200-350MB | ~800MB | Docker 内 | 有 Docker 环境 |
| Docker Alpine Lite | ~150-280MB | ~300MB | Docker 内 | 需要 Docker 但想省资源 |

---

## 命令行参数

```bash
sudo bash metapi-deploy.sh [选项]
```

| 选项 | 说明 |
|------|------|
| （无） | 一键部署（自动检测平台，下载预编译包） |
| `--source` | 强制源码编译模式 |
| `--uninstall` | 卸载（保留数据） |
| `--uninstall-all` | 完整卸载（不保留数据） |
| `--repair` | 依赖修复 |
| `--token TOKEN` | 非交互式指定 AUTH_TOKEN |
| `--proxy-token PT` | 非交互式指定 PROXY_TOKEN |
| `--yes`, `-y` | 非交互式确认 |
| `--help`, `-h` | 显示帮助 |

---

## 非交互式部署

适合自动化工具（Ansible、Terraform 等）或批量部署：

```bash
# 完全非交互
sudo bash metapi-deploy.sh --token my-admin-token --proxy-token my-proxy-token

# 从远程一键部署
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh | \
  sudo bash -s -- --token my-admin-token --proxy-token my-proxy-token
```

---

## CI/CD 预编译发布

项目已配置 GitHub Actions 自动构建（`.github/workflows/build-release.yml`）。

### 触发方式

| 方式 | 说明 |
|------|------|
| 推送 tag | `git tag v1.3.0 && git push origin v1.3.0` 自动构建并发布 |
| 手动触发 | GitHub → Actions → Build & Release → Run workflow |

### 构建产物

每次发布会生成：

| 文件 | 架构 | 适用服务器 |
|------|------|-----------|
| `metapi-{version}-linux-amd64.tar.gz` | x86_64 | 普通 VPS / 云服务器 |
| `metapi-{version}-linux-arm64.tar.gz` | ARM64 | 树莓派5 / ARM 云服务器 |

### 在自己的 Fork 上启用

1. Fork `zczy-k/metapi` 到你的 GitHub 账号
2. 在 Fork 仓库的 Settings → Actions → General 中启用 Actions
3. 推送 tag 或手动触发 workflow
4. 修改 `.env` 中的 `UPDATE_CHECK_URL`：

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

### 手动更新

```bash
# 1. 下载新版本预编译包
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
curl -fsSLO "https://github.com/zczy-k/metapi/releases/latest/download/metapi-latest-linux-${ARCH}.tar.gz"

# 2. 停止并备份
sudo systemctl stop metapi
cp /opt/metapi/.env /tmp/metapi-env-backup
cp -a /opt/metapi/data /tmp/metapi-data-backup

# 3. 解压覆盖
tar -xzf metapi-*.tar.gz
sudo rm -rf /opt/metapi/* /opt/metapi/.[!.]* 2>/dev/null
sudo cp -a metapi-*/. /opt/metapi/

# 4. 恢复
cp /tmp/metapi-env-backup /opt/metapi/.env
cp -a /tmp/metapi-data-backup/. /opt/metapi/data/
sudo chown -R metapi:metapi /opt/metapi

# 5. 重启
sudo systemctl start metapi
```

---

## 自动更新配置

### 方案 A：systemd timer（推荐）

```bash
sudo cp /opt/metapi/deploy/bare-metal/metapi-update.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now metapi-update.timer

# 查看状态
systemctl list-timers metapi-update.timer
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
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh --check  # 检查
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh           # 更新

# 卸载（保留数据）
sudo bash /opt/metapi/deploy/bare-metal/metapi-deploy.sh --uninstall

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
| 预编译包无对应架构 | 脚本会自动切换到源码编译模式 |
| `better-sqlite3` 加载失败 | 架构不匹配，运行 `sudo bash metapi-deploy.sh --repair` |
| 内存不足 | 脚本会自动配置 Swap，也可手动增加 |
| 端口被占用 | 脚本会自动选择下一个可用端口 |
| GitHub Release 未找到 | 脚本会自动切换到源码编译，或使用 `--source` 参数 |
| 更新后服务无法启动 | `journalctl -u metapi -n 50` 查看日志，或 `sudo bash metapi-deploy.sh --repair` |
| Node.js 安装失败 | 检查网络或手动安装 Node.js 22+ |
