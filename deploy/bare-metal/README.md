# 裸机轻量部署 (Bare-Metal Lite)

适用于 **2核1G 及以下** 低配置服务器的部署方案，相比 Docker 部署省去容器运行时开销，预计节省 ~50-100MB 内存。

## 内存占用对比

| 部署方式 | 预估内存占用 | 说明 |
|---------|------------|------|
| Docker Compose | ~200-350MB | 包含 Docker daemon + 容器开销 + kubectl/helm |
| **裸机 Lite（本方案）** | **~115-220MB** | 仅 Node.js + SQLite，无容器开销 |
| Docker Alpine Lite | ~150-280MB | 精简镜像，无 kubectl/helm |

## 方式一：一键安装脚本（推荐）

```bash
# 下载并执行安装脚本
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/install.sh | bash -s --

# 或非交互模式（使用默认令牌，请后续修改）
curl -fsSL https://raw.githubusercontent.com/zczy-k/metapi/main/deploy/bare-metal/install.sh | bash -s -- -y
```

脚本会自动完成：
1. 检测系统配置并建议优化参数
2. 安装 Node.js 和系统依赖
3. 构建项目（前端 + 后端）
4. 创建 `.env` 配置文件
5. 安装 PM2 进程管理器
6. 启动服务

## 方式二：手动部署

### 1. 安装 Node.js 22+

```bash
# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# CentOS/RHEL
curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
sudo yum install -y nodejs

# 或使用 nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install 22
```

### 2. 安装系统编译依赖

```bash
# Ubuntu/Debian
sudo apt-get install -y python3 make g++

# CentOS/RHEL
sudo yum install -y python3 make gcc-c++
```

### 3. 克隆并构建

```bash
git clone https://github.com/zczy-k/metapi.git /opt/metapi
cd /opt/metapi

# 安装依赖
npm ci --ignore-scripts --no-audit --no-fund
npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund

# 构建
npm run build:web
npm run build:server

# 清理开发依赖（节省约 200MB 磁盘空间）
npm prune --omit=dev --no-audit --no-fund
```

### 4. 配置环境变量

```bash
cp deploy/bare-metal/.env.example .env
# 编辑 .env，修改 AUTH_TOKEN 和 PROXY_TOKEN
vim .env
```

**关键配置（2核1G 建议值）：**

```bash
# 必须修改
AUTH_TOKEN=your-admin-token        # 管理后台登录令牌
PROXY_TOKEN=your-proxy-sk-token    # 下游 API 调用令牌

# 内存优化
NODE_OPTIONS=--max-old-space-size=256  # 限制 Node.js 堆内存 256MB

# 其他
PORT=4000
DATA_DIR=/opt/metapi/data
TZ=Asia/Shanghai
```

### 5. 启动服务

**方案 A：使用 PM2（推荐）**

```bash
npm install -g pm2

# 数据库迁移
node dist/server/db/migrate.js

# 启动服务
pm2 start dist/server/index.js \
  --name metapi \
  --node-args="--max-old-space-size=256"

# 设置开机自启
pm2 startup
pm2 save
```

**方案 B：使用 systemd**

```bash
# 创建专用用户
sudo useradd -r -s /bin/false metapi
sudo chown -R metapi:metapi /opt/metapi

# 安装服务文件
sudo cp deploy/bare-metal/metapi.service /etc/systemd/system/
sudo vim /etc/systemd/system/metapi.service  # 修改路径和令牌

# 启动
sudo systemctl daemon-reload
sudo systemctl enable metapi
sudo systemctl start metapi
```

### 6. 配置 Swap（1G 内存建议）

```bash
# 创建 1GB swap
sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# 持久化
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 更新

```bash
cd /opt/metapi
git pull

# 重新构建
npm ci --ignore-scripts --no-audit --no-fund
npm rebuild esbuild sharp better-sqlite3 --no-audit --no-fund
npm run build:web
npm run build:server
npm prune --omit=dev --no-audit --no-fund

# 重启
pm2 restart metapi
# 或 systemd: sudo systemctl restart metapi
```

## 常用运维命令

```bash
# PM2 方式
pm2 status                    # 查看状态
pm2 logs metapi               # 查看日志
pm2 restart metapi             # 重启
pm2 stop metapi               # 停止
pm2 monit                      # 监控资源占用

# systemd 方式
systemctl status metapi        # 查看状态
journalctl -u metapi -f        # 查看日志
systemctl restart metapi       # 重启
```

## Nginx 反向代理（可选）

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

        # SSE 流式支持
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 300s;

        # gzip 压缩（节省带宽）
        gzip on;
        gzip_types text/plain text/css application/json application/javascript text/xml;
    }
}
```

## 故障排除

| 问题 | 解决方案 |
|-----|---------|
| `OOMKilled` / 内存不足 | 增加 swap，降低 `--max-old-space-size` 值 |
| `better-sqlite3` 编译失败 | 安装 `python3 make g++`，重新 `npm rebuild better-sqlite3` |
| 端口被占用 | 修改 `.env` 中的 `PORT` 值 |
| 数据库迁移失败 | 确保 `DATA_DIR` 目录存在且有写权限 |
