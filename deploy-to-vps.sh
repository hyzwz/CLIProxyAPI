#!/bin/bash
################################################################################
# CLIProxyAPI + Frontend VPS 部署脚本
# 服务器: ubuntu@66.80.0.77
# 包含: Claude quota 功能的完整部署
################################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

VPS_USER="ubuntu"
VPS_HOST="66.80.0.77"
VPS_SSH="$VPS_USER@$VPS_HOST"
BACKEND_REPO="https://github.com/hyzwz/CLIProxyAPI.git"
FRONTEND_REPO="https://github.com/hyzwz/Cli-Proxy-API-Management-Center.git"
DEPLOY_DIR="/home/ubuntu/cliproxyapi"

################################################################################
# 步骤 1: 在 VPS 上部署后端
################################################################################
deploy_backend() {
    log_step "========== 部署后端到 VPS =========="

    log_info "连接到 VPS: $VPS_SSH"

    ssh $VPS_SSH << 'ENDSSH'
set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[VPS]${NC} 开始部署后端..."

# 检查并安装 Go（如果需要）
if ! command -v go &> /dev/null; then
    echo -e "${YELLOW}[VPS]${NC} Go 未安装，正在安装..."
    cd /tmp
    wget -q https://go.dev/dl/go1.23.5.linux-amd64.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf go1.23.5.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
    export PATH=$PATH:/usr/local/go/bin
    rm go1.23.5.linux-amd64.tar.gz
fi

echo -e "${GREEN}[VPS]${NC} Go 版本: $(go version)"

# 克隆或更新后端仓库
DEPLOY_DIR="/home/ubuntu/cliproxyapi"

if [ -d "$DEPLOY_DIR" ]; then
    echo -e "${GREEN}[VPS]${NC} 更新现有仓库..."
    cd "$DEPLOY_DIR"
    git fetch origin
    git reset --hard origin/main
    git pull origin main
else
    echo -e "${GREEN}[VPS]${NC} 克隆后端仓库..."
    git clone https://github.com/hyzwz/CLIProxyAPI.git "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
fi

# 备份旧的二进制文件（如果存在）
if [ -f "cliproxy-server" ]; then
    echo -e "${GREEN}[VPS]${NC} 备份旧版本..."
    cp cliproxy-server cliproxy-server.bak
fi

# 构建新版本
echo -e "${GREEN}[VPS]${NC} 编译后端..."
go build -o cliproxy-server ./cmd/server

# 设置可执行权限
chmod +x cliproxy-server

# 复制为 systemd 服务使用的名称（先备份旧的，避免 text file busy）
echo -e "${GREEN}[VPS]${NC} 更新服务二进制文件..."
if [ -f cliproxyapi ]; then
    mv cliproxyapi cliproxyapi.old
fi
cp cliproxy-server cliproxyapi
chmod +x cliproxyapi

echo -e "${GREEN}[VPS]${NC} ✅ 后端部署完成"
echo -e "${GREEN}[VPS]${NC} 二进制文件: $DEPLOY_DIR/cliproxyapi"

ENDSSH

    log_info "✅ 后端部署完成"
}

################################################################################
# 步骤 2: 构建并部署前端
################################################################################
deploy_frontend() {
    log_step "========== 构建并部署前端 =========="

    # 本地构建前端
    FRONTEND_DIR="/Users/murunkun/MeishuSourceCode/Cli-Proxy-API-Management-Center"

    log_info "本地构建前端..."
    cd "$FRONTEND_DIR"

    # 清理旧构建
    rm -rf dist

    # 构建
    npm run build

    if [ ! -f "dist/index.html" ]; then
        log_error "前端构建失败"
        exit 1
    fi

    log_info "✅ 前端构建成功"

    # 上传到 VPS
    log_info "上传前端到 VPS..."

    # 在 VPS 上创建 static 目录
    ssh $VPS_SSH "mkdir -p $DEPLOY_DIR/static"

    # 上传文件
    scp dist/index.html $VPS_SSH:$DEPLOY_DIR/static/management.html

    log_info "✅ 前端部署完成"
}

################################################################################
# 步骤 3: 配置 systemd 服务（如果不存在）
################################################################################
setup_systemd() {
    log_step "========== 配置 systemd 服务 =========="

    ssh $VPS_SSH << 'ENDSSH'
set -e

GREEN='\033[0;32m'
NC='\033[0m'

SERVICE_FILE="/etc/systemd/system/cliproxyapi.service"

echo -e "${GREEN}[VPS]${NC} 更新 systemd 服务配置..."

sudo tee "$SERVICE_FILE" > /dev/null << 'EOF'
[Unit]
Description=CLIProxyAPI - OAuth-based AI API Proxy
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/cliproxyapi
ExecStart=/home/ubuntu/cliproxyapi/cliproxyapi
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cliproxyapi

Environment="PATH=/usr/local/go/bin:/usr/bin:/bin"
Environment="MANAGEMENT_STATIC_PATH=/home/ubuntu/cliproxyapi/static"

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cliproxyapi

echo -e "${GREEN}[VPS]${NC} ✅ systemd 服务配置完成"

ENDSSH

    log_info "✅ systemd 配置完成"
}

################################################################################
# 步骤 4: 重启服务
################################################################################
restart_service() {
    log_step "========== 重启服务 =========="

    ssh $VPS_SSH << 'ENDSSH'
set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}[VPS]${NC} 重启 cliproxyapi 服务..."
sudo systemctl restart cliproxyapi

# 等待服务启动
sleep 2

# 检查状态
if sudo systemctl is-active --quiet cliproxyapi; then
    echo -e "${GREEN}[VPS]${NC} ✅ 服务启动成功"
    sudo systemctl status cliproxyapi --no-pager -l
else
    echo -e "\033[0;31m[VPS]\033[0m ❌ 服务启动失败"
    sudo journalctl -u cliproxyapi -n 50 --no-pager
    exit 1
fi

ENDSSH

    log_info "✅ 服务重启完成"
}

################################################################################
# 步骤 5: 验证部署
################################################################################
verify_deployment() {
    log_step "========== 验证部署 =========="

    log_info "等待服务完全启动..."
    sleep 3

    log_info "测试 API 端点..."

    # 测试健康检查
    if curl -s http://$VPS_HOST:8317/v1/models > /dev/null 2>&1; then
        log_info "✅ API 端点响应正常"
    else
        log_warn "⚠️  API 端点无响应，请检查防火墙设置"
    fi

    # 测试管理界面
    if curl -s http://$VPS_HOST:8317/management.html > /dev/null 2>&1; then
        log_info "✅ 管理界面可访问"
    else
        log_warn "⚠️  管理界面无响应"
    fi

    log_info "部署验证完成"
}

################################################################################
# 主函数
################################################################################
main() {
    echo ""
    echo "=========================================="
    echo "  CLIProxyAPI VPS 部署脚本"
    echo "  目标: $VPS_SSH"
    echo "=========================================="
    echo ""

    # 检查 SSH 连接
    log_info "检查 SSH 连接..."
    if ! ssh -o ConnectTimeout=5 $VPS_SSH "echo '连接成功'" > /dev/null 2>&1; then
        log_error "无法连接到 VPS: $VPS_SSH"
        log_error "请检查:"
        log_error "  1. SSH 密钥是否配置正确"
        log_error "  2. VPS 是否可访问"
        exit 1
    fi
    log_info "✅ SSH 连接正常"
    echo ""

    # 执行部署步骤
    deploy_backend
    echo ""

    deploy_frontend
    echo ""

    setup_systemd
    echo ""

    restart_service
    echo ""

    verify_deployment
    echo ""

    # 显示访问信息
    echo "=========================================="
    echo "✅ 部署完成！"
    echo "=========================================="
    echo ""
    echo "📍 访问地址:"
    echo "   API:        http://$VPS_HOST:8317/v1/chat/completions"
    echo "   Models:     http://$VPS_HOST:8317/v1/models"
    echo "   管理界面:    http://$VPS_HOST:8317/management.html"
    echo ""
    echo "🔍 查看日志:"
    echo "   ssh $VPS_SSH 'sudo journalctl -u cliproxyapi -f'"
    echo ""
    echo "📋 管理服务:"
    echo "   重启: ssh $VPS_SSH 'sudo systemctl restart cliproxyapi'"
    echo "   状态: ssh $VPS_SSH 'sudo systemctl status cliproxyapi'"
    echo "   停止: ssh $VPS_SSH 'sudo systemctl stop cliproxyapi'"
    echo ""
    echo "🎯 下一步:"
    echo "   1. 访问管理界面进行登录"
    echo "   2. 在配额管理页面查看 Claude quota 功能"
    echo "   3. 通过 OAuth 登录添加 Claude 认证"
    echo ""
}

# 运行主函数
main "$@"
