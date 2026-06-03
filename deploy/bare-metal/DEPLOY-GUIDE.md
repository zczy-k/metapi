# Metapi 裸机部署完整指南

> 本文档独立于项目主 README，避免上游更新时被覆盖。
> 适用于 **Ubuntu 22.04 / Debian 12**（任何带 `apt-get` 与 `systemd` 的发行版），
> 推荐 **2核1G 及以下** 低配置服务器。

---

## 目录

- [一键部署](#一键部署)
- [交互菜单说明](#交互菜单说明)
- [命令行参数](#命令行参数)
- [非交互式部署](#非交互式部署)
- [架构说明](#架构说明)
- [部署方式对比](#部署方式对比)
- [CI/CD 预编译发布](#cicd-预编译发布)
- [更新与升级](#更新与升级)
- [自动更新配置](#自动更新配置)
- [与其他应用共存](#与其他应用共存)
- [常用运维命令](#常用运维命令)
- [故障排除](#故障排除)

---

## 一键部署

### 最简方式（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh | sudo bash -s --
```

执行后立即进入**主菜单**，按提示完成安装。

### 先下载再部署

```bash
wget https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh
sudo bash metapi-deploy.sh
```

---

## 交互菜单说明

### 主菜单

```
╔════════════════════════════════════╗
║        Metapi 管理面板              ║
╚════════════════════════════════════╝
  ubuntu / amd64 | 内存 1024MB | 磁盘 5000MB 可用
  服务状态: 未安装

  1) 安装/重装部署
  2) 查看状态
  3) 修复依赖
  4) 启动服务（未安装）
  5) 停止服务（未安装）
  6) 卸载（未安装）
  7) 完整卸载（未安装）

  0) 退出

  请输入数字 [0-7]:
```

> 安装后选项 4–10 全部激活：重启/停止、卸载/完整卸载、升级、查看日志、SSL 域名配置；
> 顶部服务状态也会实时刷新（运行中 / 已停止 / 异常）。

### 主菜单选项

| 选项 | 适用条件 | 说明 |
|------|---------|------|
| `1) 安装/重装部署` | 任意 | 启动**安装部署向导**（见下），已安装时会自动带入现有 `.env` 与 marker 中的配置 |
| `2) 查看状态` | 任意 | 显示应用版本、安装时间、运行状态、端口、域名、SSL、PID、内存、运行时长、最近 3 行日志 |
| `3) 修复依赖` | 任意 | 诊断 Node.js / dist / better-sqlite3 / service / .env 并自动补救 |
| `4) 启动服务` / `重启服务` | 已安装 | 视当前状态显示「启动」或「重启」 |
| `5) 停止服务` | 已安装且运行中 | 停止 systemd 服务 |
| `6) 卸载（保留数据）` | 已安装 | 停止服务、清理代码/配置/用户/Swap/Nginx/SSL，**保留 `/opt/metapi/data` 与 `.env`** |
| `7) 完整卸载（删除数据）` | 已安装 | 上述之外，连同 `/opt/metapi/data` 一起删除 |
| `8) 升级到最新版本` | 已安装 | 从 GitHub Release 拉取新版预编译包，自动备份与回滚 |
| `9) 查看运行日志` | 已安装 | `journalctl -u metapi -n 30` |
| `10) 配置 SSL 证书 / 域名` | 已安装 | 单独进入 SSL/域名子向导（不重装） |
| `0) 退出` | 任意 | Ctrl+C 也会立即退出（exit 130） |

### 安装部署向导

主菜单选择 `1` 后进入线性向导，按顺序填入信息（**中途可按 Ctrl+C 取消**）：

1. **管理令牌** —— 管理后台登录密码，输入时不回显（`AUTH_TOKEN`）
2. **代理令牌** —— 下游 API 调用密钥，输入时不回显（`PROXY_TOKEN`）
3. **Metapi 内部端口** —— 内部监听端口，默认 4000；端口被占用时自动顺延
4. **是否配置域名和 SSL 证书？[y/N]** —— 选 `y` 进入域名配置子步骤，选 `n` 直接跳过（仅 IP 访问）
   - **4a.** 输入域名（如 `api.example.com`）
   - **4b.** 外部访问端口（默认 443），会校验端口冲突
   - **4c.** 证书邮箱（留空则不申请证书，仅 HTTP 反代）

> 重新安装时，向导会从已存在的 `.env` / `marker` 中自动带入之前的值；按回车即可沿用。

### 交互流程

```
执行命令 → 主菜单 → 选 [1] 进入安装向导 → 填入令牌/端口/域名 → 摘要确认 → 全自动部署 → 完成
```

**用户需要做的：**
1. 在主菜单选 `1`（安装/重装）
2. 设置两个令牌（`AUTH_TOKEN` + `PROXY_TOKEN`）
3. 按需调整内部端口
4. 明确回答 **是否配置域名和证书 [y/N]**
5. 若选 `y`，继续填入域名 / 外部端口 / 证书邮箱
6. 确认摘要，开始安装

其余全部自动完成：架构检测 → 残留清理 → 端口解析 → Node.js 运行时 → 下载预编译包 → 创建隔离用户 → 写 `.env` → 配置 Swap（如需） → 安装 systemd → 启动服务 → 配置 Nginx + 申请 SSL（若提供域名）→ 写安装标记 → 输出访问地址与防火墙提示。

---

## 命令行参数

```bash
sudo bash metapi-deploy.sh [选项]
```

| 选项 | 说明 |
|------|------|
| （无） | 交互式菜单部署 |
| `--uninstall` | 卸载（保留 `/opt/metapi/data` 与 `.env`） |
| `--uninstall-all` | 完整卸载（不保留数据） |
| `--repair` | 诊断并修复依赖 |
| `--token TOKEN` | 指定 `AUTH_TOKEN`（跳过交互菜单） |
| `--proxy-token PT` | 指定 `PROXY_TOKEN`（跳过交互菜单） |
| `--domain DOMAIN` | 指定域名（自动配置 Nginx 反向代理） |
| `--listen-port PT` | 外部访问端口 1-65535（默认 443 或 4000） |
| `--cert-email EMAIL` | 证书邮箱；提供后自动申请 Let's Encrypt 证书 |
| `--yes`, `-y` | 配合上面参数使用，跳过二次确认 |
| `--help`, `-h` | 显示帮助 |

### 行为契约

- `--token` / `--proxy-token` 触发 `SKIP_MENU=1`，跳过主菜单和向导。
- `--domain` / `--listen-port` / `--cert-email` 同样触发 `SKIP_MENU=1`，并把这三项预填进安装流程。
- `--listen-port` 必须是 1-65535 的数字，否则**立即报错退出**。
- `--cert-email` 必须是合法邮箱格式，否则**立即报错退出**。
- 非交互模式下 `--token` 和 `--proxy-token` **缺一不可**，缺则报错退出。

---

## 非交互式部署

适合 Ansible / Terraform / 批量部署 / 一键远程安装。

### 仅 IP 访问

```bash
sudo bash metapi-deploy.sh --token my-admin-token --proxy-token my-proxy-token
```

### 带域名 + SSL（自动申请 Let's Encrypt 证书）

```bash
sudo bash metapi-deploy.sh \
  --token my-admin-token \
  --proxy-token my-proxy-token \
  --domain api.example.com \
  --cert-email me@example.com
```

执行结果：服务监听 4000，Nginx 在 443 终止 TLS，HTTP 自动 301 到 HTTPS，
Let's Encrypt 证书由 certbot 申请并自动续期。

### 自定义 HTTPS 端口（非 443）

```bash
sudo bash metapi-deploy.sh \
  --token my-admin-token --proxy-token my-proxy-token \
  --domain api.example.com --listen-port 8443 \
  --cert-email me@example.com
```

### 远程一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/metapi-deploy.sh | \
  sudo bash -s -- \
    --token my-admin-token --proxy-token my-proxy-token \
    --domain api.example.com --cert-email me@example.com
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
│    1. 预检（root / apt / systemd / 磁盘）                 │
│    2. 残留清理（带管理标记的资源才删除）                    │
│    3. 端口解析（占用时自动顺延）                            │
│    4. 安装 Node.js 22 运行时（专用，不污染系统 Node）       │
│    5. 下载对应架构的预编译包                                │
│    6. 创建隔离用户 metapi                                 │
│    7. 写 .env / 配置 Swap（如需）                          │
│    8. 安装 systemd service（含安全沙箱）                    │
│    9. 启动服务                                            │
│   10. 配置 Nginx + 申请 SSL（如提供域名/邮箱）              │
│                                                         │
│  资源需求: 仅需 Node.js 运行时，不需要 python3/make/g++    │
│  磁盘占用: ~300MB（vs 源码编译 ~500MB）                   │
└─────────────────────────────────────────────────────────┘
```

**预编译下载模式（唯一模式）**：编译在 GitHub CI 上完成，服务器只下载并运行。
若预编译包缺失，脚本会**报错退出**而不是回退到源码编译——这是为了在低配 VPS 上
避免被静默拉起一套 gcc/python 全家桶。

---

## 部署方式对比

| 部署方式 | 预估内存 | 磁盘占用 | 编译位置 | 适用场景 |
|---------|---------|---------|---------|---------|
| **预编译下载（本脚本，默认/唯一）** | **~115-220MB** | **~300MB** | **GitHub CI** | **2核1G 低配服务器** |
| Docker Compose（官方） | ~200-350MB | ~800MB | Docker 内 | 有 Docker 环境 |
| Docker Alpine Lite | ~150-280MB | ~300MB | Docker 内 | 需要 Docker 但想省资源 |

---

## CI/CD 预编译发布

项目已配置 GitHub Actions 自动构建（`.github/workflows/build-release.yml`）。

### 触发方式

| 方式 | 说明 |
|------|------|
| 推送 tag | `git tag v1.3.0 && git push origin v1.3.0` 自动构建并发布 |
| 手动触发 | GitHub → Actions → Build & Release → Run workflow |

### 构建产物

| 文件 | 架构 | 适用服务器 |
|------|------|-----------|
| `metapi-{version}-linux-amd64.tar.gz` | x86_64 | 普通 VPS / 云服务器 |
| `metapi-{version}-linux-arm64.tar.gz` | ARM64 | 树莓派5 / ARM 云服务器 |

### 在自己的 Fork 上启用

1. Fork `zczy-k/metapi` 到你的 GitHub 账号
2. 在 Fork 仓库的 Settings → Actions → General 中启用 Actions
3. 推送 tag 或手动触发 workflow
4. 修改 `/opt/metapi/.env` 中的 `UPDATE_CHECK_URL`：

```bash
UPDATE_CHECK_URL=https://api.github.com/repos/YOUR_USERNAME/metapi/releases/latest
```

---

## 更新与升级

### 方式 A：菜单内升级（推荐）

主菜单选 `8) 升级到最新版本`：

1. 对比当前版本与最新 Release
2. 下载新版本预编译包
3. 备份当前版本到 `mktemp -d`（升级失败自动回滚）
4. 替换 `/opt/metapi/dist` 等
5. 备份并重写 systemd unit（保留旧 unit 为 `.bak-pre-upgrade-<时间戳>`）
6. 重启服务并验证 `/` 端口响应
7. 自动重新应用 Nginx + SSL 配置

### 方式 B：自动更新脚本

```bash
# 检查更新
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh --check

# 执行更新
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh

# 非交互（适合 cron）
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh --yes
```

### 方式 C：手动更新

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
curl -fsSLO "https://github.com/zczy-k/metapi/releases/latest/download/metapi-latest-linux-${ARCH}.tar.gz"

sudo systemctl stop metapi
sudo cp /opt/metapi/.env /tmp/metapi-env-backup
sudo cp -a /opt/metapi/data /tmp/metapi-data-backup

tar -xzf metapi-*.tar.gz
sudo rm -rf /opt/metapi/* /opt/metapi/.[!.]* 2>/dev/null
sudo cp -a metapi-*/. /opt/metapi/
cp /tmp/metapi-env-backup /opt/metapi/.env
sudo cp -a /tmp/metapi-data-backup/. /opt/metapi/data/
sudo chown -R metapi:metapi /opt/metapi
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

- 默认每天 03:00 检查更新
- 错过时间后启动时补跑（`Persistent=true`）
- 随机延迟 0-30 分钟，避免所有服务器同时更新

### 方案 B：cron

```bash
echo '0 3 * * * root /opt/metapi/deploy/bare-metal/metapi-updater.sh --yes >> /var/log/metapi/update.log 2>&1' | \
  sudo tee /etc/cron.d/metapi-update
```

### 更新通知（可选）

在 `.env` 中：

```bash
WEBHOOK_URL=https://hooks.slack.com/services/xxx
```

支持 Slack / Discord / 企业微信 / 钉钉。

---

## 与其他应用共存

脚本设计上**不会触碰**任何不属于 Metapi 命名空间的资源，对同机其他应用零干扰。

### 命名空间隔离清单

| 资源 | Metapi 路径 / 名称 | 共享？ |
|------|-------------------|-------|
| 安装目录 | `/opt/metapi` | 否 |
| 数据目录 | `/opt/metapi/data` | 否 |
| 配置文件 | `/opt/metapi/.env`（`chmod 600`） | 否 |
| 系统用户 | `metapi`（无密码、`/bin/bash` 锁定 shell、`passwd -l`） | 否 |
| systemd 服务 | `metapi.service` | 否 |
| 部署日志 | `/var/log/metapi/deploy.log`（`chmod 600`） | 否 |
| Node.js 运行时 | `/opt/metapi/runtime/node/`（独立，不改系统 Node） | 否 |
| Swap 文件 | `/swapfile_metapi` | 否 |
| sysctl 配置 | `/etc/sysctl.d/99-metapi.conf` | 否 |
| Nginx 配置 | `sites-available/metapi.conf` | 否 |
| Nginx 启用链接 | `sites-enabled/metapi.conf` | 否 |
| ACME 验证根 | `/var/www/metapi-challenge/` | 否 |
| Let's Encrypt 证书 | `/etc/letsencrypt/live/<domain>/`（仅卸载时清理） | 否 |

### 管理标记（managed marker）

所有由本脚本创建的资源都会带 `managed_by=metapi-deploy.sh` 标记，
卸载时**只清理带标记的资源**：

- `service_file_managed` / `app_dir_managed` / `nginx_conf_managed`
- `sysctl_conf_managed` / `swap_owned_by_script` / `app_user_owned_by_script`

如果 `metapi.conf`、`/swapfile_metapi`、sysctl 文件已存在但**不带**该标记，脚本**拒绝删除**并打印警告——避免误删同名但属于其他应用的文件。

### Nginx 端口/配置隔离

- 本脚本的 Nginx 配置文件固定为 `metapi.conf`，与其他站点配置互不冲突
- `proxy_pass` 固定指向 `127.0.0.1:<metapi port>`，不监听外部
- 启用 SSL 时使用 `certbot --nginx --no-redirect`：certbot 只签证书和加 443 server 块，
  HTTP→HTTPS 重定向由本脚本用我们自己的模板统一生成（**重写而不是 sed 替换**），
  所以即便你**反复用不同 HTTPS 端口重配**，最终配置始终一致

### 不污染系统 Node.js

`/opt/metapi/runtime/node/bin/node` 是脚本下载的专用 Node.js 22，
systemd unit 中的 `ExecStart` 显式指向这个路径。`PATH` 中的系统 `node` 不会被替换，
所以本机其他用 Node 的应用不受影响。

### swap/sysctl 隔离

- swap 文件 `/swapfile_metapi` 是独立的，fstab 条目带 `# metapi-deploy.sh` 注释
- sysctl 配置写在 `/etc/sysctl.d/99-metapi.conf`（仅 `vm.swappiness=10`），
  卸载时整文件删除

### 证书隔离

`remove_ssl_cert` 只删除 marker 中标记为 `cert_managed_by_script=yes` 的证书——
同机其他站点用 certbot 签的证书**不会**被本脚本误删。

---

## 常用运维命令

```bash
# systemd
systemctl status metapi
journalctl -u metapi -f
systemctl restart metapi
systemctl stop metapi
systemctl start metapi

# 更新
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh --check
sudo bash /opt/metapi/deploy/bare-metal/metapi-updater.sh

# 卸载 / 重装
sudo bash /opt/metapi/deploy/bare-metal/metapi-deploy.sh --uninstall        # 保留数据
sudo bash /opt/metapi/deploy/bare-metal/metapi-deploy.sh --uninstall-all    # 不保留
sudo bash /opt/metapi/deploy/bare-metal/metapi-deploy.sh --repair           # 修复

# 数据库备份
cp -a /opt/metapi/data /backup/metapi-data-$(date +%Y%m%d)

# 查看部署日志
cat /var/log/metapi/deploy.log
```

---

## 故障排除

| 问题 | 解决方案 |
|------|---------|
| **当前系统未检测到 systemd** | 本脚本仅支持带 systemd 的发行版；容器环境请改用 Docker 方式 |
| **当前系统不支持 apt-get** | 仅支持 Debian/Ubuntu 系；其他发行版请用 Docker |
| 预编译包无对应架构 | 仅支持 amd64 / arm64；armv7l 暂不支持，请用 Docker |
| `better-sqlite3` 加载失败 | 运行 `sudo bash metapi-deploy.sh --repair` |
| 内存不足 | 脚本会在 < 2GB 内存时自动配 1GB Swap；也可手动加 |
| 端口被占用 | 菜单中改端口，或脚本自动顺延到下一个可用端口 |
| GitHub Release 未找到 | 脚本会报错并提示可能原因（网络/限速），不会静默回退 |
| 更新后服务无法启动 | `journalctl -u metapi -n 50` 看日志；或 `metapi-deploy.sh --repair` |
| Node.js 安装失败 | 检查到 `nodejs.org` 的网络连通性，或手动装 Node.js 22+ |
| 证书申请失败 | 检查 80 端口是否被防火墙拦截、域名是否正确解析 |
| 重装时提示「未检测到安装记录」 | 安装目录存在但缺少 marker——可能是其他程序占用了 `/opt/metapi`，备份后手动删除即可 |
| `--listen-port` 报错 | 必须是 1-65535 的数字 |
| `--cert-email` 报错 | 必须是合法邮箱格式 |
| SSH 断连后脚本卡住 | 提示输入有 120s/300s 超时，Ctrl+C 立即退出（exit 130） |
| 想跑非交互但只传 `--yes` | `--yes` 必须搭配 `--token` 和 `--proxy-token` 使用 |
| 升级后 systemd 自定义被覆盖 | 旧 unit 自动备份为 `/etc/systemd/system/metapi.service.bak-pre-upgrade-<时间戳>`，可对照恢复 |
