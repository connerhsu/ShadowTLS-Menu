#!/bin/bash
# =========================================
# 作者: jinqians (修复增强版)
# 日期: 2026年2月
# 描述: SS-Rust + ShadowTLS 流水线管理
# 功能: 支持自定义加密/端口，输出 Mihomo 配置
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 默认配置
DEFAULT_PORT=8443
DEFAULT_DOMAIN="player.live-video.net"
DEFAULT_METHOD="aes-256-gcm"
CONFIG_DIR="/etc/ss-stls"

# 检查并安装依赖 (精简版)
check_dependencies() {
    local deps=("bc" "jq" "curl" "wget" "openssl" "tar")
    local need_update=false
    
    echo -e "${CYAN}正在检查依赖...${RESET}"
    
    if [ -x "$(command -v apt)" ]; then
        CMD_INSTALL="apt install -y"
        CMD_UPDATE="apt update"
    elif [ -x "$(command -v yum)" ]; then
        CMD_INSTALL="yum install -y"
        CMD_UPDATE="yum makecache"
    else
        echo -e "${RED}未支持的包管理器${RESET}"
        exit 1
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            need_update=true
            break
        fi
    done
    
    if [ "$need_update" = true ]; then
        $CMD_UPDATE
        for dep in "${deps[@]}"; do
            if ! command -v "$dep" &> /dev/null; then
                $CMD_INSTALL "$dep"
            fi
        done
    fi
}

# URL 编码函数 (替代 xxd，解决报错问题)
url_encode() {
    echo -n "$1" | od -A n -t x1 | tr -d ' \n' | sed 's/../%&/g'
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 安装全局命令 (默认为 menu)
install_global_command() {
    if [ ! -L "/usr/local/bin/menu" ]; then
        cp "$0" "/usr/local/bin/menu.sh"
        chmod +x "/usr/local/bin/menu.sh"
        ln -sf "/usr/local/bin/menu.sh" "/usr/local/bin/menu"
        echo -e "${GREEN}全局命令 'menu' 设置成功${RESET}"
    fi
}

# 获取最新 GitHub Release 版本
get_latest_version() {
    local repo=$1
    local ver=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)
    echo "$ver"
}

# 安装/重装 流水线
install_pipeline() {
    echo -e "${CYAN}=== 开始安装 SS-Rust + ShadowTLS ===${RESET}"

    mkdir -p "$CONFIG_DIR"
    
    # 架构检测
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  SS_ARCH="x86_64-unknown-linux-gnu"; ST_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-gnu"; ST_ARCH="aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; exit 1 ;;
    esac

    # === 自定义配置部分 ===
    
    # 1. 端口
    echo -e "${YELLOW}默认端口: ${DEFAULT_PORT}${RESET}"
    read -rp "请输入端口 (回车使用默认): " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    # 2. 伪装域名
    echo -e "${YELLOW}默认伪装域名: ${DEFAULT_DOMAIN}${RESET}"
    read -rp "请输入伪装域名 (回车使用默认): " DOMAIN
    DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

    # 3. 加密方式
    echo -e "${YELLOW}请选择加密方式:${RESET}"
    echo "1) aes-256-gcm (默认/推荐)"
    echo "2) chacha20-ietf-poly1305 (移动端友好)"
    echo "3) 2022-blake3-aes-256-gcm (新协议)"
    read -rp "请选择 [1-3]: " method_choice
    case $method_choice in
        2) SS_METHOD="chacha20-ietf-poly1305" ;;
        3) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        *) SS_METHOD="aes-256-gcm" ;;
    esac
    echo -e "已选择加密: ${GREEN}${SS_METHOD}${RESET}"

    # 4. 密码
    read -rp "请输入密码 (回车随机生成): " PASSWORD
    if [ -z "$PASSWORD" ]; then
        if [[ "$SS_METHOD" == *"2022"* ]]; then
            # 2022 协议需要固定长度密钥，这里简单处理，实际建议使用openssl生成对应长度
            # 为了兼容性，2022协议建议让客户端生成，这里我们生成一个足够长的base64
            PASSWORD=$(openssl rand -base64 32)
        else
            PASSWORD=$(openssl rand -base64 16)
        fi
        echo -e "已生成随机密码"
    fi

    # 内部端口 (随机)
    LOCAL_PORT=$(shuf -i 10000-60000 -n 1)

    # === 下载核心 ===
    echo -e "${CYAN}正在下载组件...${RESET}"
    SS_VER=$(get_latest_version "shadowsocks/shadowsocks-rust")
    [ -z "$SS_VER" ] && { echo -e "${RED}获取 SS 版本失败${RESET}"; exit 1; }
    wget -qO- "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VER}/shadowsocks-${SS_VER}.${SS_ARCH}.tar.xz" | tar -xJ -C /usr/local/bin/ ssserver

    ST_VER=$(get_latest_version "ihciah/shadow-tls")
    [ -z "$ST_VER" ] && { echo -e "${RED}获取 ShadowTLS 版本失败${RESET}"; exit 1; }
    wget -qO /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${ST_VER}/shadow-tls-${ST_ARCH}"
    chmod +x /usr/local/bin/shadow-tls

    # === 配置文件 ===
    cat > "$CONFIG_DIR/ss-config.json" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $LOCAL_PORT,
    "password": "$PASSWORD",
    "method": "$SS_METHOD",
    "timeout": 300
}
EOF

    # === Systemd 服务 ===
    # SS-Rust
    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c $CONFIG_DIR/ss-config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # ShadowTLS
    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 --fastopen server --listen ::0:$PORT --server 127.0.0.1:$LOCAL_PORT --tls $DOMAIN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # === 启动 ===
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls
    systemctl restart ss-rust shadowtls

    show_config_info "$PORT" "$PASSWORD" "$DOMAIN" "$SS_METHOD"
}

# 显示配置信息 (含 Mihomo 格式)
show_config_info() {
    local port=$1
    local pwd=$2
    local dom=$3
    local method=$4
    
    # 从文件回读
    if [ -z "$pwd" ] && [ -f "$CONFIG_DIR/ss-config.json" ]; then
        pwd=$(jq -r .password "$CONFIG_DIR/ss-config.json")
        method=$(jq -r .method "$CONFIG_DIR/ss-config.json")
    fi
    
    PUBLIC_IP=$(curl -s https://api.ipify.org)

    echo -e "\n${CYAN}================ 配置详情 ================${RESET}"
    echo -e "IP:        ${GREEN}${PUBLIC_IP}${RESET}"
    echo -e "端口:      ${GREEN}${port:-$DEFAULT_PORT}${RESET}"
    echo -e "密码:      ${GREEN}${pwd}${RESET}"
    echo -e "加密:      ${GREEN}${method:-$DEFAULT_METHOD}${RESET}"
    echo -e "伪装域名:  ${GREEN}${dom:-$DEFAULT_DOMAIN}${RESET}"
    echo -e "${CYAN}==========================================${RESET}"
    
    # 1. 通用链接
    local plugin_arg="shadow-tls;host=${dom:-$DEFAULT_DOMAIN}"
    local plugin_enc=$(url_encode "$plugin_arg")
    local user_info=$(echo -n "${method:-$DEFAULT_METHOD}:${pwd}" | base64 -w 0)
    local link="ss://${user_info}@${PUBLIC_IP}:${port:-$DEFAULT_PORT}/?plugin=${plugin_enc}#ShadowTLS-${dom:-$DEFAULT_DOMAIN}"
    
    echo -e "\n${YELLOW}[通用分享链接]${RESET}"
    echo -e "${link}"
    
    # 2. Mihomo 配置
    echo -e "\n${YELLOW}[Mihomo / Clash Meta 格式]${RESET}"
    cat <<EOF
proxies:
  - name: "STLS-${dom:-$DEFAULT_DOMAIN}"
    type: ss
    server: ${PUBLIC_IP}
    port: ${port:-$DEFAULT_PORT}
    password: "${pwd}"
    cipher: ${method:-$DEFAULT_METHOD}
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: "${dom:-$DEFAULT_DOMAIN}"
      version: 3
EOF
    echo -e "${CYAN}==========================================${RESET}"
}

# 查看配置
view_current_config() {
    if [ -f "$CONFIG_DIR/ss-config.json" ]; then
        local port=$(systemctl cat shadowtls | grep "listen" | sed 's/.*::0:\([0-9]*\).*/\1/')
        local dom=$(systemctl cat shadowtls | grep "\--tls" | awk '{print $NF}')
        show_config_info "$port" "" "$dom" ""
    else
        echo -e "${RED}未检测到安装配置${RESET}"
    fi
}

# 卸载
uninstall_all() {
    echo -e "${CYAN}正在卸载...${RESET}"
    systemctl stop ss-rust shadowtls 2>/dev/null
    systemctl disable ss-rust shadowtls 2>/dev/null
    rm -f /etc/systemd/system/ss-rust.service /etc/systemd/system/shadowtls.service
    rm -f /usr/local/bin/ssserver /usr/local/bin/shadow-tls
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成${RESET}"
}

# 菜单
show_menu() {
    clear
    echo -e "${CYAN}SS-Rust + ShadowTLS 管理脚本 v2${RESET}"
    echo -e "${GREEN}1.${RESET} 一键安装SS-Rust + ShadowTLS / 重置 (自定义加密/端口)"
    echo -e "${GREEN}2.${RESET} 查看当前配置"
    echo -e "${GREEN}3.${RESET} 卸载"
    echo -e "${GREEN}0.${RESET} 退出"
    
    read -rp "请选择: " num
    case "$num" in
        1) install_pipeline ;;
        2) view_current_config ;;
        3) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

check_root
check_dependencies
install_global_command

while true; do
    show_menu
    echo -e "\n按任意键返回..."
    read -n 1 -s -r
done
