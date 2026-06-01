# Metapi 裸机部署完整指南

> 本文档独立于项目主 README，避免上游更新时被覆盖。
> 适用于 Ubuntu 22.04，2核1G 及以下低配置服务器。

---

## 目录

- [一键部署](#一键部署)
- [交互菜单说明](#交互菜单说明)
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

执行后**立即弹出交互菜单**，用户在菜单中完成配置后，脚本全自动完成部署。

### 先下载再部署

```bash
wget https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh
sudo bash metapi-deploy.sh
```

---

## 交互菜单说明

脚本启动后会显示如下交互界面：

```
╔══════════════════════════════════════════════════════╗
║                                                      ║
║          Metapi 一键部署                              ║
║                                                      ║
╚══════════════════════════════════════════════════════╝

  系统信息
  ──────────────────────────
  平台     ubuntu / amd64
  内存     1024MB
  磁盘     5000MB 可用

  部署配置
  ──────────────────────────
  [1] 安装模式    预编译下载（推荐低配服务器）
  [2] 访问端口    4000
  [3] 管理令牌    （未设置，必须填写）
  [4] 代理令牌    （未设置，必须填写）

  ──────────────────────────
  [0] 开始安装
  [q] 退出

  请选择 [0-4, q]:
```

### 菜单操作

| 选项 | 说明 |
|------|------|
| `[1]` 切换安装模式 | 在「预编译下载」和「源码编译」之间切换 |
| `[2]` 修改端口 | 输入自定义端口号（默认 4000） |
| `[3]` 设置管理令牌 | 输入 AUTH_TOKEN（管理后台登录密码，**必填**） |
| `[4]` 设置代理令牌 | 输入 PROXY_TOKEN（下游 API 调用密钥，**必填**） |
| `[0]` 开始安装 | 令牌设置完成后，选择此项开始自动部署 |
| `[q]` 退出 | 取消部署 |

### 交互流程

```
执行命令 → 弹出菜单 → 用户配置选项 → 选 [0] 开始 → 全自动部署 → 完成
```

**整个过程用户只需：**
1. 设置两个令牌（AUTH_TOKEN + PROXY_TOKEN）
2. 按需调整安装模式或端口
3. 选择开始安装

其余所有步骤自动完成：检测架构、下载预编译包、安装 Node.js、创建用户、配置 Swap、安装服务、启动。

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
| （无） | 交互式菜单部署 |
| `--source` | 强制源码编译模式 |
| `--uninstall` | 卸载（保留数据） |
| `--uninstall-all` | 完整卸载（不保留数据） |
| `--repair` | 依赖修复 |
| `--token TOKEN` | 指定 AUTH_TOKEN（跳过交互菜单） |
| `--proxy-token PT` | 指定 PROXY_TOKEN（跳过交互菜单） |
| `--yes`, `-y` | 非交互式确认 |
| `--help`, `-h` | 显示帮助 |

---

## 非交互式部署

适合自动化工具（Ansible、Terraform 等）或批量部署。指定 `--token` 和 `--proxy-token` 后自动跳过交互菜单：

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
| 端口被占用 | 菜单中修改端口，或脚本自动选择下一个可用端口 |
| GitHub Release 未找到 | 脚本会自动切换到源码编译，或使用 `--source` 参数 |
| 更新后服务无法启动 | `journalctl -u metapi -n 50` 查看日志，或 `sudo bash metapi-deploy.sh --repair` |
| Node.js 安装失败 | 检查网络或手动安装 Node.js 22+ |
