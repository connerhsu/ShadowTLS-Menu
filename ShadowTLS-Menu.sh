#!/bin/bash
# =========================================
# 作者: jinqians (v3.8 Stable)
# 描述: 修复下载失败问题，增加端口检测，锁定稳定版本
# =========================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'
WHITE='\033[1;37m'

# --- 锁定稳定版本 (防止API失败) ---
FIXED_SS_VER="v1.18.2"    # 稳定版 SS-Rust
FIXED_ST_VER="v3.3.5"     # 稳定版 ShadowTLS
CONFIG_DIR="/etc/ss-stls"

# --- 依赖检查 ---
check_dependencies() {
    local deps=("jq" "curl" "wget" "openssl" "tar" "net-tools" "lsof")
    if [ -x "$(command -v apt)" ]; then
        CMD_INSTALL="apt install -y"
        CMD_UPDATE="apt update"
    elif [ -x "$(command -v yum)" ]; then
        CMD_INSTALL="yum install -y"
        CMD_UPDATE="yum makecache"
    else
        return
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${CYAN}> 正在安装依赖: $dep ...${RESET}"
            $CMD_INSTALL "$dep" >/dev/null 2>&1
        fi
    done
}

# --- 辅助工具 ---
url_encode() {
    echo -n "$1" | od -A n -t x1 | tr -d ' \n' | sed 's/../%&/g'
}

open_firewall() {
    local port=$1
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    fi
    if command -v ufw &> /dev/null && ufw status | grep -q "Active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
    fi
}

check_port_usage() {
    local port=$1
    if lsof -i:"$port" >/dev/null 2>&1; then
        echo -e "${RED}>>> 警告：端口 $port 已经被占用！${RESET}"
        lsof -i:"$port"
        echo -e "${YELLOW}请在安装时更换一个端口，或者停止占用该端口的程序。${RESET}"
        return 1
    fi
    return 0
}

# --- 状态检测面板 ---
show_dashboard() {
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${WHITE}        ShadowTLS 修复版 v3.8 (Stable)      ${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    if [ ! -f "$CONFIG_DIR/ss-config.json" ]; then
        echo -e "${YELLOW}   状态: 未安装${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        return
    fi

    # 状态检测
    if systemctl is-active --quiet ss-rust; then
        SS_STATUS="${GREEN}● 运行中${RESET}"
    else
        SS_STATUS="${RED}● 已停止${RESET}"
    fi

    if systemctl is-active --quiet shadowtls; then
        STLS_STATUS="${GREEN}● 运行中${RESET}"
    else
        STLS_STATUS="${RED}● 已停止${RESET}"
    fi

    local stls_port=$(grep "listen 0.0.0.0:" /etc/systemd/system/shadowtls.service 2>/dev/null | sed 's/.*0.0.0.0:\([0-9]*\).*/\1/')
    local ss_port=$(jq -r .server_port "$CONFIG_DIR/ss-config.json" 2>/dev/null)
    local method=$(jq -r .method "$CONFIG_DIR/ss-config.json" 2>/dev/null)

    echo -e "组件       | 状态       | 端口"
    echo -e "-----------|------------|----------------"
    echo -e "ShadowTLS  | $STLS_STATUS   | ${GREEN}${stls_port:-N/A}${RESET}"
    echo -e "SS-Rust    | $SS_STATUS   | ${YELLOW}${ss_port:-N/A}${RESET}"
    echo -e ""
    echo -e "加密: ${CYAN}${method:-N/A}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# --- 查看错误日志 ---
check_logs() {
    echo -e "\n${RED}>>> ShadowTLS 错误日志 (最后20行):${RESET}"
    journalctl -u shadowtls -n 20 --no-pager
    echo -e "\n${RED}>>> SS-Rust 错误日志 (最后10行):${RESET}"
    journalctl -u ss-rust -n 10 --no-pager
    echo -e "\n按任意键返回..."
    read -n 1 -s -r
}

# --- 安装逻辑 ---
install_logic() {
    check_dependencies
    mkdir -p "$CONFIG_DIR"
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  SS_ARCH="x86_64-unknown-linux-gnu"; ST_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-gnu"; ST_ARCH="aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持架构: $ARCH${RESET}"; exit 1 ;;
    esac

    clear
    echo -e "${CYAN}>>> 1. 端口设置${RESET}"
    read -rp "请输入公网端口 (例如 8443): " STLS_PORT
    STLS_PORT=${STLS_PORT:-8443}
    
    # 检查端口占用
    check_port_usage "$STLS_PORT"
    if [ $? -ne 0 ]; then
        read -rp "是否强制继续? (y/N): " force_opt
        if [[ "$force_opt" != "y" ]]; then return; fi
        # 尝试停止旧服务释放端口
        systemctl stop shadowtls 2>/dev/null
    fi

    SS_PORT=$(shuf -i 20000-60000 -n 1)

    echo -e "\n${CYAN}>>> 2. 伪装设置${RESET}"
    read -rp "请输入伪装域名 (默认 player.live-video.net): " DOMAIN
    DOMAIN=${DOMAIN:-player.live-video.net}

    echo -e "\n${CYAN}>>> 3. 加密设置${RESET}"
    echo "1) 2022-blake3-aes-256-gcm (默认/推荐)"
    echo "2) aes-256-gcm"
    echo "3) chacha20-ietf-poly1305"
    read -rp "选择: " m_opt
    case $m_opt in
        2) SS_METHOD="aes-256-gcm"; PASS_CMD="openssl rand -base64 16" ;;
        3) SS_METHOD="chacha20-ietf-poly1305"; PASS_CMD="openssl rand -base64 16" ;;
        *) SS_METHOD="2022-blake3-aes-256-gcm"; PASS_CMD="openssl rand -base64 32" ;;
    esac
    
    # 自动生成密码
    PASSWORD=$($PASS_CMD)

    # --- 下载核心 (带校验) ---
    echo -e "\n${CYAN}>>> 4. 正在下载组件...${RESET}"
    
    # 下载 SS-Rust
    wget -qO- "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${FIXED_SS_VER}/shadowsocks-${FIXED_SS_VER}.${SS_ARCH}.tar.xz" | tar -xJ -C /usr/local/bin/ ssserver
    if [ ! -f "/usr/local/bin/ssserver" ]; then
        echo -e "${RED}SS-Rust 下载失败！${RESET}"; return
    fi

    # 下载 ShadowTLS
    echo -e "   正在下载 ShadowTLS (${FIXED_ST_VER})..."
    wget -qO /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${FIXED_ST_VER}/shadow-tls-${ST_ARCH}"
    chmod +x /usr/local/bin/shadow-tls
    
    # 校验 ShadowTLS 是否可运行
    if ! /usr/local/bin/shadow-tls --version >/dev/null 2>&1; then
        echo -e "${RED}ShadowTLS 二进制文件无效，尝试备用源...${RESET}"
        # 这里可以加备用下载逻辑，或者提示检查网络
        echo -e "${RED}下载失败，请检查服务器网络连接 GitHub 是否正常。${RESET}"
        return
    fi

    # --- 写入配置 ---
    cat > "$CONFIG_DIR/ss-config.json" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $SS_PORT,
    "password": "$PASSWORD",
    "method": "$SS_METHOD",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF

    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=SS-Rust
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c $CONFIG_DIR/ss-config.json
Restart=always
EOF

    # 移除 --fastopen 以提高兼容性
    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS
After=network.target ss-rust.service
Requires=ss-rust.service

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen 0.0.0.0:$STLS_PORT --server 127.0.0.1:$SS_PORT --tls $DOMAIN
Restart=always
EOF

    # --- 启动 ---
    open_firewall "$STLS_PORT"
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls >/dev/null 2>&1
    systemctl restart ss-rust shadowtls

    echo -e "${GREEN}>>> 安装完成，正在检查状态...${RESET}"
    sleep 2
    
    if systemctl is-active --quiet shadowtls; then
        show_info_page
    else
        echo -e "${RED}>>> ShadowTLS 启动失败！${RESET}"
        echo -e "可能原因: 1.端口占用 2.域名无法连接"
        echo -e "正在尝试自动显示日志..."
        sleep 1
        journalctl -u shadowtls -n 10 --no-pager
        read -n 1 -s -r -p "按任意键返回..."
    fi
}

show_info_page() {
    if [ ! -f "$CONFIG_DIR/ss-config.json" ]; then echo -e "${RED}未安装${RESET}"; return; fi
    local ss_port=$(jq -r .server_port "$CONFIG_DIR/ss-config.json")
    local method=$(jq -r .method "$CONFIG_DIR/ss-config.json")
    local pwd=$(jq -r .password "$CONFIG_DIR/ss-config.json")
    local stls_port=$(grep "listen 0.0.0.0:" /etc/systemd/system/shadowtls.service | sed 's/.*0.0.0.0:\([0-9]*\).*/\1/')
    local domain=$(grep "\--tls" /etc/systemd/system/shadowtls.service | awk '{print $NF}')
    local ip=$(curl -s https://api.ipify.org)

    # 链接生成
    local p_arg="shadow-tls;host=$domain"
    local p_enc=$(url_encode "$p_arg")
    local u_info=$(echo -n "$method:$pwd" | base64 -w 0)
    local link="ss://${u_info}@${ip}:${stls_port}/?plugin=${p_enc}#STLS-$domain"

    echo -e "\n${YELLOW}[节点配置]${RESET}"
    echo -e "IP:     $ip"
    echo -e "端口:   $stls_port"
    echo -e "密码:   $pwd"
    echo -e "加密:   $method"
    echo -e "SNI:    $domain"

    echo -e "\n${YELLOW}[通用链接]${RESET}"
    echo "$link"
    
    echo -e "\n${YELLOW}[Mihomo / Clash Meta]${RESET}"
    cat <<EOF
proxies:
  - name: "STLS-$domain"
    type: ss
    server: $ip
    port: $stls_port
    password: "$pwd"
    cipher: $method
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: "$domain"
      version: 3
EOF
    echo -e "\n按任意键返回..."
    read -n 1 -s -r
}

uninstall() {
    systemctl stop ss-rust shadowtls
    systemctl disable ss-rust shadowtls
    rm -f /etc/systemd/system/ss-rust.service /etc/systemd/system/shadowtls.service
    rm -f /usr/local/bin/ssserver /usr/local/bin/shadow-tls
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}已卸载${RESET}"
}

# --- 初始化 ---
[ "$(id -u)" != "0" ] && { echo "请 Root 运行"; exit 1; }
[ ! -f "/usr/local/bin/menu" ] && { cp "$0" /usr/local/bin/menu.sh; chmod +x /usr/local/bin/menu.sh; ln -sf /usr/local/bin/menu.sh /usr/local/bin/menu; }

# --- 主菜单 ---
while true; do
    clear
    show_dashboard
    echo -e "${GREEN}1.${RESET} 安装/重置 (v3.8 Stable)"
    echo -e "${GREEN}2.${RESET} 查看连接信息"
    echo -e "${GREEN}3.${RESET} 卸载服务"
    echo -e "${YELLOW}4.${RESET} 查看错误日志"
    echo -e "${GREEN}0.${RESET} 退出"
    echo ""
    read -rp "选择: " choice
    case "$choice" in
        1) install_logic ;;
        2) show_info_page ;;
        3) uninstall ;;
        4) check_logs ;;
        0) exit 0 ;;
    esac
done
