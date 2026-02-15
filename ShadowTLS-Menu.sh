#!/bin/bash
# =========================================
# 作者: jinqians更改
# 日期: 2026年2月
# 描述: SS-Rust + ShadowTLS 统一流水线管理脚本
# 默认端口: 8443 | 默认SNI: player.live-video.net
# 管理命令: stls
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="3.2-stls"

# 默认配置
DEFAULT_PORT=8443
DEFAULT_DOMAIN="player.live-video.net"
SS_METHOD="aes-256-gcm"
CONFIG_DIR="/etc/ss-stls"

# 检查并安装依赖
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
                echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                $CMD_INSTALL "$dep"
            fi
        done
    fi
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 安装全局命令 (修改为 stls)
install_global_command() {
    # 检查是否已存在名为 stls 的链接或文件，如果不存在或指向错误则重新创建
    if [ ! -L "/usr/local/bin/stls" ]; then
        echo -e "${CYAN}正在设置全局命令 'stls'...${RESET}"
        
        # 将当前脚本复制为系统脚本文件
        cp "$0" "/usr/local/bin/stls.sh"
        chmod +x "/usr/local/bin/stls.sh"
        
        # 创建软链接 stls -> stls.sh
        ln -sf "/usr/local/bin/stls.sh" "/usr/local/bin/stls"
        
        echo -e "${GREEN}设置成功！现在您可以在任何位置输入 'stls' 命令来启动管理脚本${RESET}"
    fi
}

# 获取最新 GitHub Release 版本
get_latest_version() {
    local repo=$1
    curl -s "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name
}

# 安装/重装 流水线 (SS-Rust + ShadowTLS)
install_pipeline() {
    echo -e "${CYAN}=== 开始安装 SS-Rust + ShadowTLS 流水线 ===${RESET}"

    # 1. 环境准备
    mkdir -p "$CONFIG_DIR"
    
    # 2. 获取架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  SS_ARCH="x86_64-unknown-linux-gnu"; ST_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-gnu"; ST_ARCH="aarch64-unknown-linux-musl" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; exit 1 ;;
    esac

    # 3. 设置参数
    echo -e "${YELLOW}默认端口: ${DEFAULT_PORT}${RESET}"
    read -rp "请输入端口 (回车使用默认): " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    echo -e "${YELLOW}默认伪装域名: ${DEFAULT_DOMAIN}${RESET}"
    read -rp "请输入伪装域名 (回车使用默认): " DOMAIN
    DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

    # 生成随机密码和本地端口
    PASSWORD=$(openssl rand -base64 16)
    LOCAL_PORT=$(shuf -i 10000-60000 -n 1) # SS 监听本地，不暴露

    echo -e "${CYAN}正在下载 SS-Rust...${RESET}"
    SS_VER=$(get_latest_version "shadowsocks/shadowsocks-rust")
    # 如果获取失败使用 fallback 版本或者报错，这里假设网络正常
    if [ -z "$SS_VER" ] || [ "$SS_VER" == "null" ]; then
        echo -e "${RED}获取 SS-Rust 版本失败，请检查网络${RESET}"
        exit 1
    fi
    wget -qO- "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_VER}/shadowsocks-${SS_VER}.${SS_ARCH}.tar.xz" | tar -xJ -C /usr/local/bin/ ssserver

    echo -e "${CYAN}正在下载 ShadowTLS...${RESET}"
    ST_VER=$(get_latest_version "ihciah/shadow-tls")
    if [ -z "$ST_VER" ] || [ "$ST_VER" == "null" ]; then
        echo -e "${RED}获取 ShadowTLS 版本失败，请检查网络${RESET}"
        exit 1
    fi
    wget -qO /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/download/${ST_VER}/shadow-tls-${ST_ARCH}"
    chmod +x /usr/local/bin/shadow-tls

    # 4. 配置 SS-Rust (监听本地)
    cat > "$CONFIG_DIR/ss-config.json" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $LOCAL_PORT,
    "password": "$PASSWORD",
    "method": "$SS_METHOD",
    "timeout": 300
}
EOF

    # 5. 配置 Systemd 服务
    
    # SS-Rust Service
    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c $CONFIG_DIR/ss-config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # ShadowTLS Service
    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS Service
After=network.target

[Service]
Type=simple
# ShadowTLS 监听公网 PORT，转发流量给本地 SS，伪装流量发给 DOMAIN
ExecStart=/usr/local/bin/shadow-tls --v3 --fastopen server --listen ::0:$PORT --server 127.0.0.1:$LOCAL_PORT --tls $DOMAIN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # 6. 启动服务
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls
    systemctl restart ss-rust shadowtls

    # 7. 显示信息
    show_config_info "$PORT" "$PASSWORD" "$DOMAIN"
}

# 显示配置信息
show_config_info() {
    local port=$1
    local pwd=$2
    local dom=$3
    
    # 如果参数为空，尝试从文件读取
    if [ -z "$pwd" ]; then
        if [ -f "$CONFIG_DIR/ss-config.json" ]; then
            pwd=$(jq -r .password "$CONFIG_DIR/ss-config.json")
        else
            echo -e "${RED}未找到配置文件${RESET}"
            return
        fi
    fi
    
    # 获取公网IP
    PUBLIC_IP=$(curl -s https://api.ipify.org)

    echo -e "\n${CYAN}============================================${RESET}"
    echo -e "${GREEN}       安装/配置成功！节点信息如下${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "IP地址: ${YELLOW}${PUBLIC_IP}${RESET}"
    echo -e "端口: ${YELLOW}${port:-$DEFAULT_PORT}${RESET}"
    echo -e "密码: ${YELLOW}${pwd}${RESET}"
    echo -e "加密: ${YELLOW}${SS_METHOD}${RESET}"
    echo -e "伪装域名 (SNI): ${YELLOW}${dom:-$DEFAULT_DOMAIN}${RESET}"
    echo -e "ShadowTLS 版本: ${YELLOW}v3${RESET}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    
    local plugin_opts="host=${dom:-$DEFAULT_DOMAIN}"
    local plugin_opts_enc=$(echo -n "shadow-tls;$plugin_opts" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')
    local user_info=$(echo -n "${SS_METHOD}:${pwd}" | base64 -w 0)
    local link="ss://${user_info}@${PUBLIC_IP}:${port:-$DEFAULT_PORT}/?plugin=${plugin_opts_enc}#ShadowTLS-${dom:-$DEFAULT_DOMAIN}"
    
    echo -e "通用分享链接 (客户端需安装 ShadowTLS 插件):"
    echo -e "${GREEN}${link}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# 查看当前配置
view_current_config() {
    if [ -f "$CONFIG_DIR/ss-config.json" ]; then
        local pwd=$(jq -r .password "$CONFIG_DIR/ss-config.json")
        # 尝试从运行的服务中抓取参数
        local port=$(systemctl cat shadowtls | grep "listen" | sed 's/.*::0:\([0-9]*\).*/\1/')
        local dom=$(systemctl cat shadowtls | grep "\--tls" | awk '{print $NF}')
        
        # 如果systemctl获取失败（未运行），尝试读取默认值
        port=${port:-$DEFAULT_PORT}
        dom=${dom:-$DEFAULT_DOMAIN}

        show_config_info "$port" "$pwd" "$dom"
    else
        echo -e "${RED}未检测到安装配置文件${RESET}"
    fi
}

# 卸载全部
uninstall_all() {
    echo -e "${CYAN}正在卸载 SS-Rust 和 ShadowTLS...${RESET}"
    
    systemctl stop ss-rust shadowtls 2>/dev/null
    systemctl disable ss-rust shadowtls 2>/dev/null
    
    rm -f /etc/systemd/system/ss-rust.service
    rm -f /etc/systemd/system/shadowtls.service
    rm -f /usr/local/bin/ssserver /usr/local/bin/sslocal /usr/local/bin/ssurl /usr/local/bin/ssmanager
    rm -f /usr/local/bin/shadow-tls
    rm -rf "$CONFIG_DIR"
    
    # 同时也移除 stls 命令
    rm -f /usr/local/bin/stls
    rm -f /usr/local/bin/stls.sh
    
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成！全局命令 'stls' 已移除。${RESET}"
}

# 检查服务状态
check_status() {
    local ss_status=$(systemctl is-active ss-rust 2>/dev/null)
    local st_status=$(systemctl is-active shadowtls 2>/dev/null)
    
    echo -e "${CYAN}=== 服务状态 ===${RESET}"
    if [ "$ss_status" == "active" ]; then
        echo -e "SS-Rust:    ${GREEN}运行中${RESET}"
    else
        echo -e "SS-Rust:    ${RED}未运行${RESET}"
    fi
    
    if [ "$st_status" == "active" ]; then
        echo -e "ShadowTLS:  ${GREEN}运行中${RESET}"
    else
        echo -e "ShadowTLS:  ${RED}未运行${RESET}"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}    SS-Rust + ShadowTLS 极简管理脚本${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian (Optimized)${RESET}"
    echo -e "${GREEN}默认端口: ${DEFAULT_PORT} | 默认SNI: ${DEFAULT_DOMAIN}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    check_status
    echo ""
    
    echo -e "${YELLOW}1.${RESET} 安装/重置 SS-Rust + ShadowTLS (流水线)"
    echo -e "${YELLOW}2.${RESET} 查看当前配置 & 分享链接"
    echo -e "${YELLOW}3.${RESET} 卸载所有服务"
    echo -e "${YELLOW}4.${RESET} 退出"
    
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}提示：退出后输入 'stls' 即可再次打开${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [1-4]: " num
    
    case "$num" in
        1) install_pipeline ;;
        2) view_current_config ;;
        3) uninstall_all ;;
        4) exit 0 ;;
        *) echo -e "${RED}请输入正确的选项${RESET}" ;;
    esac
}

# 初始化
check_root
check_dependencies
install_global_command

# 循环
while true; do
    show_menu
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
