#!/bin/bash
# =========================================
# 作者: jinqians (v3.6 Dashboard)
# 描述: SS-Rust + ShadowTLS 管理脚本 (带状态面板)
# =========================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'
WHITE='\033[1;37m'

# --- 默认配置 ---
DEFAULT_STLS_PORT=8443
DEFAULT_DOMAIN="player.live-video.net"
CONFIG_DIR="/etc/ss-stls"

# --- 依赖检查 ---
check_dependencies() {
    local deps=("jq" "curl" "wget" "openssl" "tar" "net-tools")
    if [ -x "$(command -v apt)" ]; then
        CMD_INSTALL="apt install -y"
        CMD_UPDATE="apt update"
    elif [ -x "$(command -v yum)" ]; then
        CMD_INSTALL="yum install -y"
        CMD_UPDATE="yum makecache"
    else
        return
    fi

    local need_install=false
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            need_install=true
            break
        fi
    done

    if [ "$need_install" = true ]; then
        echo -e "${CYAN}> 正在安装必要组件...${RESET}"
        $CMD_UPDATE >/dev/null 2>&1
        $CMD_INSTALL "${deps[@]}" >/dev/null 2>&1
    fi
}

# --- 辅助工具 ---
url_encode() {
    echo -n "$1" | od -A n -t x1 | tr -d ' \n' | sed 's/../%&/g'
}

get_version() {
    local ver=$(curl -s "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name)
    [ -z "$ver" ] && echo "latest" || echo "$ver"
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
    if command -v firewall-cmd &> /dev/null && systemctl is-active firewalld &> /dev/null; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# --- 状态检测面板 ---
show_dashboard() {
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${WHITE}           ShadowTLS 状态面板 v3.6          ${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    if [ ! -f "$CONFIG_DIR/ss-config.json" ] || [ ! -f "/etc/systemd/system/shadowtls.service" ]; then
        echo -e "${YELLOW}   状态: 未安装 或 配置文件丢失${RESET}"
        echo -e "${CYAN}============================================${RESET}"
        return
    fi

    # 获取运行状态
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

    # 获取配置信息
    # SS Info
    local ss_port=$(jq -r .server_port "$CONFIG_DIR/ss-config.json" 2>/dev/null)
    local method=$(jq -r .method "$CONFIG_DIR/ss-config.json" 2>/dev/null)
    
    # STLS Info (解析 systemd service 文件)
    local stls_port=$(grep "listen 0.0.0.0:" /etc/systemd/system/shadowtls.service | sed 's/.*0.0.0.0:\([0-9]*\).*/\1/')
    local domain=$(grep "\--tls" /etc/systemd/system/shadowtls.service | awk '{print $NF}')

    # 显示表格
    echo -e "组件名称   | 运行状态   | 监听端口"
    echo -e "-----------|------------|----------------"
    echo -e "ShadowTLS  | $STLS_STATUS   | ${GREEN}${stls_port:-未知}${RESET} (公网)"
    echo -e "SS-Rust    | $SS_STATUS   | ${YELLOW}${ss_port:-未知}${RESET} (内部)"
    echo -e ""
    echo -e "加密算法: ${CYAN}${method:-未知}${RESET}"
    echo -e "伪装域名: ${CYAN}${domain:-未知}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
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
    echo -e "${CYAN}>>> 配置向导${RESET}"

    # 1. 端口配置
    read -rp "1. 请输入公网连接端口 (默认 $DEFAULT_STLS_PORT): " STLS_PORT
    STLS_PORT=${STLS_PORT:-$DEFAULT_STLS_PORT}

    read -rp "2. 请输入SS内部监听端口 (回车随机): " SS_PORT
    [ -z "$SS_PORT" ] && SS_PORT=$(shuf -i 20000-60000 -n 1)
    echo -e "   -> 内部端口已设定为: ${YELLOW}$SS_PORT${RESET}"

    # 2. 域名与加密
    read -rp "3. 请输入伪装域名 (默认 $DEFAULT_DOMAIN): " DOMAIN
    DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

    echo -e "4. 请选择加密方式:"
    echo "   1) aes-256-gcm (默认)"
    echo "   2) chacha20-ietf-poly1305"
    echo "   3) 2022-blake3-aes-256-gcm"
    read -rp "   选择 [1-3]: " m_opt
    case $m_opt in
        2) SS_METHOD="chacha20-ietf-poly1305" ;;
        3) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        *) SS_METHOD="aes-256-gcm" ;;
    esac

    # 3. 密码
    read -rp "5. 请输入密码 (回车随机): " PASSWORD
    [ -z "$PASSWORD" ] && PASSWORD=$(openssl rand -base64 16)

    # 下载与安装
    echo -e "\n${CYAN}>>> 正在安装...${RESET}"
    
    SS_VER=$(get_version "shadowsocks/shadowsocks-rust")
    wget -qO- "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VER}/shadowsocks-${SS_VER}.${SS_ARCH}.tar.xz" | tar -xJ -C /usr/local/bin/ ssserver

    ST_VER=$(get_version "ihciah/shadow-tls")
    wget -qO /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${ST_VER}/shadow-tls-${ST_ARCH}"
    chmod +x /usr/local/bin/shadow-tls

    # 写入配置
    # SS-Rust Config
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

    # Services
    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=SS-Rust
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c $CONFIG_DIR/ss-config.json
Restart=always
EOF

    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS
After=network.target ss-rust.service
Requires=ss-rust.service

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 --fastopen server --listen 0.0.0.0:$STLS_PORT --server 127.0.0.1:$SS_PORT --tls $DOMAIN
Restart=always
EOF

    # 启动
    open_firewall "$STLS_PORT"
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls >/dev/null 2>&1
    systemctl restart ss-rust shadowtls

    echo -e "${GREEN}>>> 安装完成！${RESET}"
    sleep 1
    show_info_page
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

    echo -e "\n${YELLOW}[节点详情]${RESET}"
    echo -e "IP:       $ip"
    echo -e "端口:     $stls_port"
    echo -e "密码:     $pwd"
    echo -e "加密:     $method"
    echo -e "SNI:      $domain"

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
    echo -e "${GREEN}已卸载所有服务${RESET}"
    sleep 1
}

# --- 初始化 ---
if [ "$(id -u)" != "0" ]; then echo "请使用 root 运行"; exit 1; fi
if [ ! -f "/usr/local/bin/menu" ]; then
    cp "$0" /usr/local/bin/menu.sh
    chmod +x /usr/local/bin/menu.sh
    ln -sf /usr/local/bin/menu.sh /usr/local/bin/menu
fi
check_dependencies

# --- 主循环 ---
while true; do
    clear
    show_dashboard
    
    echo -e "${GREEN}1.${RESET} 安装/重置服务 (自定义端口)"
    echo -e "${GREEN}2.${RESET} 查看连接信息 (链接/Clash)"
    echo -e "${GREEN}3.${RESET} 卸载服务"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    echo ""
    read -rp "请输入选项: " choice
    
    case "$choice" in
        1) install_logic ;;
        2) show_info_page ;;
        3) uninstall ;;
        0) exit 0 ;;
        *) ;;
    esac
done
