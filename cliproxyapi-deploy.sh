#!/bin/bash
################################################################################
# CLIProxyAPI 部署脚本
# 目标: 在已有 CRS 的 VPS 上部署 CLIProxyAPI 以支持 Kimi + Antigravity
# 服务器: ubuntu@66.80.0.77
# 部署日期: $(date +%Y-%m-%d)
################################################################################

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        log_error "无法检测操作系统"
        exit 1
    fi
    log_info "检测到操作系统: $OS $VER"
}

################################################################################
# 步骤 1: 安装 Go 1.23+
################################################################################
install_go() {
    log_info "========== 步骤 1: 安装 Go =========="

    # 检查是否已安装 Go
    if command -v go &> /dev/null; then
        GO_VERSION=$(go version | awk '{print $3}')
        log_info "Go 已安装: $GO_VERSION"

        # 检查版本是否满足要求 (>= 1.23)
        REQUIRED_VERSION="go1.23"
        CURRENT_VERSION=$(go version | awk '{print $3}')

        if [[ "$CURRENT_VERSION" < "$REQUIRED_VERSION" ]]; then
            log_warn "Go 版本过低，需要升级到 1.23+"
        else
            log_info "Go 版本满足要求，跳过安装"
            return 0
        fi
    fi

    # 下载并安装 Go 1.23.5
    GO_VERSION="1.23.5"
    GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
    GO_URL="https://go.dev/dl/${GO_TAR}"

    log_info "下载 Go ${GO_VERSION}..."
    cd /tmp
    wget -q --show-progress "$GO_URL" || {
        log_error "下载 Go 失败"
        exit 1
    }

    # 删除旧的 Go 安装
    log_info "删除旧的 Go 安装..."
    sudo rm -rf /usr/local/go

    # 解压并安装
    log_info "安装 Go 到 /usr/local/go..."
    sudo tar -C /usr/local -xzf "$GO_TAR"

    # 配置环境变量
    log_info "配置 Go 环境变量..."

    # 添加到 ~/.bashrc
    if ! grep -q "/usr/local/go/bin" ~/.bashrc; then
        cat >> ~/.bashrc << 'EOF'

# Go 环境变量
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
EOF
        log_info "已添加 Go 环境变量到 ~/.bashrc"
    fi

    # 立即生效
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=$HOME/go
    export PATH=$PATH:$GOPATH/bin

    # 验证安装
    if command -v go &> /dev/null; then
        log_info "✅ Go 安装成功: $(go version)"
    else
        log_error "Go 安装失败"
        exit 1
    fi

    # 配置 Go 代理（国内加速）
    log_info "配置 Go 模块代理..."
    go env -w GO111MODULE=on
    go env -w GOPROXY=https://goproxy.cn,direct

    # 清理
    rm -f /tmp/"$GO_TAR"
}

################################################################################
# 步骤 2: 克隆并构建 CLIProxyAPI
################################################################################
build_cliproxyapi() {
    log_info "========== 步骤 2: 构建 CLIProxyAPI =========="

    # 创建部署目录
    DEPLOY_DIR="$HOME/cliproxyapi"

    if [ -d "$DEPLOY_DIR" ]; then
        log_warn "目录已存在: $DEPLOY_DIR"
        read -p "是否删除并重新克隆？(y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$DEPLOY_DIR"
        else
            log_info "保留现有目录，跳过克隆"
            cd "$DEPLOY_DIR"
            git pull origin main || log_warn "Git pull 失败，继续使用现有代码"
        fi
    fi

    if [ ! -d "$DEPLOY_DIR" ]; then
        log_info "克隆 CLIProxyAPI 仓库..."
        git clone https://github.com/router-for-me/CLIProxyAPI.git "$DEPLOY_DIR" || {
            log_error "克隆仓库失败"
            exit 1
        }
    fi

    cd "$DEPLOY_DIR"

    # 构建
    log_info "构建 CLIProxyAPI..."
    go build -o cliproxyapi ./cmd/server || {
        log_error "构建失败"
        exit 1
    }

    if [ -f "$DEPLOY_DIR/cliproxyapi" ]; then
        log_info "✅ 构建成功: $DEPLOY_DIR/cliproxyapi"
        chmod +x "$DEPLOY_DIR/cliproxyapi"
    else
        log_error "构建失败：找不到可执行文件"
        exit 1
    fi
}

################################################################################
# 步骤 3: 创建配置文件
################################################################################
create_config() {
    log_info "========== 步骤 3: 创建配置文件 =========="

    cd "$DEPLOY_DIR"

    # 如果配置文件已存在，备份
    if [ -f "config.yaml" ]; then
        log_warn "config.yaml 已存在，备份为 config.yaml.bak"
        cp config.yaml config.yaml.bak
    fi

    # 创建配置文件
    log_info "创建 config.yaml..."
    cat > config.yaml << 'EOF'
# CLIProxyAPI 配置文件
# 生成时间: $(date +%Y-%m-%d)

# HTTP 服务器配置
server:
  port: 8317                    # 监听端口（与 CRS 的 3001 不冲突）
  host: 0.0.0.0                 # 监听地址

# 认证目录
auth_directory: ./auth_tokens   # OAuth token 存储目录

# 凭证选择策略
credential_selection:
  strategy: round-robin         # round-robin 或 fill-first

# 日志配置
log:
  level: info                   # debug, info, warn, error
  format: text                  # text 或 json

# SDK 配置（代理等）
sdk:
  proxy: ""                     # 如需代理填写: http://127.0.0.1:7890

# 模型别名（可选）
model_aliases:
  gpt-4: "claude-sonnet-4-20250514"
  gpt-3.5-turbo: "claude-haiku-4-20250610"
EOF

    log_info "✅ 配置文件创建完成: $DEPLOY_DIR/config.yaml"

    # 创建认证目录
    mkdir -p "$DEPLOY_DIR/auth_tokens"
    log_info "✅ 认证目录创建完成: $DEPLOY_DIR/auth_tokens"
}

################################################################################
# 步骤 4: 配置 systemd 服务
################################################################################
create_systemd_service() {
    log_info "========== 步骤 4: 配置 systemd 服务 =========="

    SERVICE_FILE="/etc/systemd/system/cliproxyapi.service"

    log_info "创建 systemd 服务文件..."
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=CLIProxyAPI - OAuth-based AI API Proxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$DEPLOY_DIR
ExecStart=$DEPLOY_DIR/cliproxyapi
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cliproxyapi

# 环境变量
Environment="PATH=/usr/local/go/bin:/usr/bin:/bin"
Environment="GOPATH=$HOME/go"

# 安全加固
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    log_info "✅ systemd 服务文件创建完成: $SERVICE_FILE"

    # 重新加载 systemd
    log_info "重新加载 systemd daemon..."
    sudo systemctl daemon-reload

    # 启用服务（开机自启）
    log_info "启用 cliproxyapi 服务..."
    sudo systemctl enable cliproxyapi

    log_info "✅ systemd 服务配置完成"
}

################################################################################
# 步骤 5: 配置 Nginx 反向代理（可选）
################################################################################
configure_nginx() {
    log_info "========== 步骤 5: 配置 Nginx =========="

    read -p "是否配置 Nginx 反向代理？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "跳过 Nginx 配置"
        return 0
    fi

    # 检查 Nginx 是否安装
    if ! command -v nginx &> /dev/null; then
        log_info "安装 Nginx..."
        sudo apt update
        sudo apt install -y nginx
    fi

    # 创建 Nginx 配置
    NGINX_CONF="/etc/nginx/sites-available/ai-proxy"

    log_info "创建 Nginx 配置文件..."
    sudo tee "$NGINX_CONF" > /dev/null << 'EOF'
# AI Proxy 统一网关配置
# CRS (Claude) + CLIProxyAPI (Kimi, Antigravity)

upstream crs_backend {
    server 127.0.0.1:3001;      # CRS 实际端口
    keepalive 32;
}

upstream cliproxyapi_backend {
    server 127.0.0.1:8317;      # CLIProxyAPI 端口
    keepalive 32;
}

# CRS 服务 - Claude API
server {
    listen 80;
    server_name crs.yourdomain.com;  # 替换为你的域名或使用 IP

    location / {
        proxy_pass http://crs_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE 支持
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}

# CLIProxyAPI 服务 - Kimi, Antigravity 等
server {
    listen 80;
    server_name api.yourdomain.com;  # 替换为你的域名或使用 IP

    location / {
        proxy_pass http://cliproxyapi_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE 支持
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF

    log_info "✅ Nginx 配置创建完成: $NGINX_CONF"

    # 启用站点
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    # 测试配置
    log_info "测试 Nginx 配置..."
    sudo nginx -t || {
        log_error "Nginx 配置测试失败"
        return 1
    }

    # 重启 Nginx
    log_info "重启 Nginx..."
    sudo systemctl restart nginx

    log_info "✅ Nginx 配置完成"
}

################################################################################
# 步骤 6: OAuth 登录指引
################################################################################
oauth_login_guide() {
    log_info "========== 步骤 6: OAuth 登录指引 =========="

    cat << 'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    🔐 OAuth 登录操作指引
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CLIProxyAPI 现已部署完成，但需要手动完成 OAuth 登录以添加账号。

📌 准备工作：
   cd ~/cliproxyapi

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌙 Kimi Coding Plan 登录
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1️⃣ 执行登录命令:
   ./cliproxyapi -kimi-login

2️⃣ 按提示操作:
   - 会显示一个设备授权链接（例如: https://auth.kimi.com/device）
   - 以及一个验证码（例如: ABCD-1234）

3️⃣ 在浏览器中:
   - 打开授权链接
   - 输入验证码
   - 使用你的 Kimi 账号登录并授权

4️⃣ 等待完成:
   - 授权后，终端会显示 "Kimi authentication successful!"
   - Token 会保存在 ./auth_tokens/kimi/ 目录

5️⃣ 添加多个账号（可选）:
   - 重复上述步骤，可添加多个 Kimi 账号
   - CLIProxyAPI 会自动负载均衡

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 Antigravity (Google Gemini CLI) 登录
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1️⃣ 执行登录命令:
   ./cliproxyapi -gemini-login

2️⃣ 按提示操作:
   - 会显示 Google OAuth 授权链接
   - 以及验证码

3️⃣ 在浏览器中:
   - 打开授权链接
   - 使用你的 Google 账号登录
   - 授权访问 Gemini API

4️⃣ 等待完成:
   - 授权后，Token 会保存在 ./auth_tokens/gemini/ 目录

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 登录完成后的操作
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1️⃣ 启动服务:
   sudo systemctl start cliproxyapi

2️⃣ 检查状态:
   sudo systemctl status cliproxyapi

3️⃣ 查看日志:
   sudo journalctl -u cliproxyapi -f

4️⃣ 测试 API:
   curl http://localhost:8317/v1/models

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📝 常用命令
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 服务管理
sudo systemctl start cliproxyapi     # 启动服务
sudo systemctl stop cliproxyapi      # 停止服务
sudo systemctl restart cliproxyapi   # 重启服务
sudo systemctl status cliproxyapi    # 查看状态

# 日志查看
sudo journalctl -u cliproxyapi -f              # 实时日志
sudo journalctl -u cliproxyapi --since today   # 今天的日志
sudo journalctl -u cliproxyapi -n 100          # 最近 100 行

# 账号管理
./cliproxyapi -kimi-login          # 添加 Kimi 账号
./cliproxyapi -gemini-login        # 添加 Gemini 账号
./cliproxyapi -claude-login        # 添加 Claude 账号（可选）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌐 API 端点
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

直接访问:
  - CRS (Claude):      http://66.80.0.77:3001/v1/chat/completions
  - CLIProxyAPI:       http://66.80.0.77:8317/v1/chat/completions

Nginx 代理后（如果配置了）:
  - CRS:               http://crs.yourdomain.com/v1/chat/completions
  - CLIProxyAPI:       http://api.yourdomain.com/v1/chat/completions

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
}

################################################################################
# 主函数
################################################################################
main() {
    log_info "=========================================="
    log_info "     CLIProxyAPI 自动部署脚本"
    log_info "=========================================="
    echo

    detect_os
    echo

    # 执行部署步骤
    install_go
    echo

    build_cliproxyapi
    echo

    create_config
    echo

    create_systemd_service
    echo

    configure_nginx
    echo

    oauth_login_guide

    log_info "=========================================="
    log_info "✅ 部署脚本执行完成！"
    log_info "=========================================="
    echo
    log_info "下一步: 请按照上面的指引完成 OAuth 登录"
    echo
}

# 运行主函数
main "$@"
