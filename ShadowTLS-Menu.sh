#!/bin/bash
# ====================================================
# 作者: Connor (v4.1 Custom-2022)
# 描述: SS-Rust (自定义端口/SS2022) + ShadowTLS 管理脚本
# 特性: 专为 SS-2022 优化、支持自定义内部端口
# ====================================================

# --- 全局变量与路径 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
CONFIG_DIR="/etc/ss-stls"
CONFIG_FILE="${CONFIG_DIR}/config.env"
SS_RUST_BIN="/usr/local/bin/ssserver"
STLS_BIN="/usr/local/bin/shadow-tls"
GH_PROXY="https://mirror.ghproxy.com/"

# --- 颜色定义 ---
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && RESET="\033[0m" && Yellow_font_prefix="\033[0;33m" && Cyan_font_prefix="\033[0;36m"
INFO="${Green_font_prefix}[信息]${RESET}"
ERROR="${Red_font_prefix}[错误]${RESET}"
WARN="${Yellow_font_prefix}[警告]${RESET}"

# --- 1. 基础检查与工具函数 ---

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 或 root 运行此脚本" && exit 1
}

check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
    elif grep -q -E -i "debian|ubuntu" /etc/issue; then
        RELEASE="debian"
    elif grep -q -E -i "centos|red hat|redhat" /etc/issue; then
        RELEASE="centos"
    elif grep -q -E -i "debian|ubuntu" /proc/version; then
        RELEASE="debian"
    else
        RELEASE="unknown"
    fi
}

install_deps() {
    echo -e "${INFO} 正在检查依赖..."
    local deps=("wget" "curl" "openssl" "jq" "tar" "lsof")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then missing+=("$dep"); fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${INFO} 安装缺失依赖: ${missing[*]}"
        check_sys
        if [[ "$RELEASE" == "debian" ]]; then
            apt-get update && apt-get install -y "${missing[@]}"
        elif [[ "$RELEASE" == "centos" ]]; then
            if command -v dnf >/dev/null; then dnf install -y "${missing[@]}"; else yum install -y "${missing[@]}"; fi
        else
            echo -e "${ERROR} 无法自动安装依赖，请手动安装: ${missing[*]}" && exit 1
        fi
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64) 
            SS_ARCH="x86_64-unknown-linux-gnu"
            ST_ARCH="x86_64-unknown-linux-musl" 
            ;;
        aarch64) 
            SS_ARCH="aarch64-unknown-linux-gnu"
            ST_ARCH="aarch64-unknown-linux-musl" 
            ;;
        *) echo -e "${ERROR} 不支持的架构: $(uname -m)" && exit 1 ;;
    esac
}

get_public_ip() {
    local ipv4=""
    local apis=("http://ipinfo.io/ip" "http://api.ip.sb/ip" "http://members.3322.org/dyndns/getip")
    for api in "${apis[@]}"; do
        ipv4=$(curl -s4 -m 5 "$api" | tr -d '\n')
        [[ -n "$ipv4" ]] && break
    done
    if [[ -z "$ipv4" ]]; then
        ipv4=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n 1)
    fi
    echo "$ipv4"
}

check_port() {
    if lsof -i:"$1" >/dev/null 2>&1; then return 0; else return 1; fi
}

allow_port() {
    local port=$1
    if command -v ufw >/dev/null; then ufw allow "$port" >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null; then 
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1
    fi
}

# --- 2. 核心功能函数 ---

get_latest_ver() {
    local repo=$1
    local ver=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)
    [[ -z "$ver" || "$ver" == "null" ]] && echo "" || echo "$ver"
}

download_file() {
    local url=$1
    local out=$2
    local name=$3
    echo -e "${INFO} 正在下载 $name..."
    wget --show-progress -qO "$out" "${GH_PROXY}${url}"
    if [[ $? -ne 0 || ! -s "$out" ]]; then
        echo -e "${WARN} 代理下载失败，尝试直连..."
        wget --show-progress -qO "$out" "${url}"
    fi
    if [[ ! -s "$out" ]]; then
        echo -e "${ERROR} $name 下载失败！" && return 1
    fi
    return 0
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
STLS_PORT=$STLS_PORT
SS_PORT=$SS_PORT
PASSWORD=$PASSWORD
METHOD=$METHOD
DOMAIN=$DOMAIN
EOF
}

read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; return 0; else return 1; fi
}

# --- 3. 安装逻辑 ---

install_ss_rust() {
    get_arch
    local ver=$(get_latest_ver "shadowsocks/shadowsocks-rust")
    [[ -z "$ver" ]] && ver="v1.18.2"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ver}/shadowsocks-${ver}.${SS_ARCH}.tar.xz"
    download_file "$url" "/tmp/ss.tar.xz" "SS-Rust" || return 1
    tar -xJf /tmp/ss.tar.xz -C /usr/local/bin/ ssserver
    chmod +x "$SS_RUST_BIN"
    rm -f /tmp/ss.tar.xz
    
    mkdir -p "$CONFIG_DIR"
    cat > "${CONFIG_DIR}/ss.json" <<EOF
{
    "server": "127.0.0.1",
    "server_port": $SS_PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF

    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Service
After=network.target

[Service]
Type=simple
ExecStart=${SS_RUST_BIN} -c ${CONFIG_DIR}/ss.json
Restart=always
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

install_stls() {
    get_arch
    local ver=$(get_latest_ver "ihciah/shadow-tls")
    [[ -z "$ver" ]] && ver="v3.3.5"
    local url="https://github.com/ihciah/shadow-tls/releases/download/${ver}/shadow-tls-${ST_ARCH}"
    download_file "$url" "$STLS_BIN" "ShadowTLS" || return 1
    chmod +x "$STLS_BIN"
    
    if ! "$STLS_BIN" --version >/dev/null 2>&1; then
        echo -e "${ERROR} ShadowTLS 二进制文件校验失败 (Exec format error)"
        return 1
    fi

    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS Service
After=network.target ss-rust.service
Requires=ss-rust.service

[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStartPre=/bin/sh -c "ulimit -n 51200"
ExecStart=${STLS_BIN} --v3 --strict server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${SS_PORT} --tls ${DOMAIN}:443 --password ${PASSWORD}
Restart=always
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

install_all() {
    check_root
    install_deps
    
    echo -e "\n${Cyan_font_prefix}=== 配置向导 (SS-2022 定制版) ===${RESET}"
    
    # 1. 设置 ShadowTLS 端口
    read -rp "1. 请输入 ShadowTLS 公网端口 (默认 8443): " input_stls_port
    STLS_PORT=${input_stls_port:-8443}
    if check_port "$STLS_PORT"; then
        echo -e "${WARN} 端口 $STLS_PORT 已占用，尝试停止旧服务..."
        systemctl stop shadowtls ss-rust 2>/dev/null
    fi
    
    # 2. 设置 SS-Rust 端口 (新增自定义)
    while true; do
        read -rp "2. 请输入 SS-Rust 内部监听端口 (默认随机): " input_ss_port
        if [[ -z "$input_ss_port" ]]; then
            SS_PORT=$(shuf -i 20000-60000 -n 1)
            echo -e "${INFO} 已随机生成内部端口: $SS_PORT"
            break
        else
            if [[ "$input_ss_port" == "$STLS_PORT" ]]; then
                echo -e "${ERROR} 内部端口不能与公网端口相同！"
            elif check_port "$input_ss_port"; then
                echo -e "${ERROR} 端口 $input_ss_port 已被占用，请更换。"
            else
                SS_PORT=$input_ss_port
                break
            fi
        fi
    done
    
    # 3. 伪装域名
    read -rp "3. 请输入伪装域名 (默认 player.live-video.net): " input_dom
    DOMAIN=${input_dom:-player.live-video.net}
    
    # 4. 加密方式 (SS-2022 专用)
    echo -e "4. 请选择 SS-2022 加密方式:"
    echo -e "  1. 2022-blake3-aes-256-gcm (推荐)"
    echo -e "  2. 2022-blake3-aes-128-gcm"
    echo -e "  3. 2022-blake3-chacha20-poly1305"
    read -rp "   请选择 [1-3]: " m_idx
    case $m_idx in
        2) 
            METHOD="2022-blake3-aes-128-gcm"
            # 128-gcm 需要 16 字节密钥
            KEY_LEN=16 
            ;;
        3) 
            METHOD="2022-blake3-chacha20-poly1305"
            # chacha20 需要 32 字节密钥
            KEY_LEN=32 
            ;;
        *) 
            METHOD="2022-blake3-aes-256-gcm"
            # 256-gcm 需要 32 字节密钥
            KEY_LEN=32 
            ;;
    esac
    
    # 5. 密码生成 (强制合规)
    echo -e "${INFO} 正在生成符合协议要求的 ${KEY_LEN} 字节密钥..."
    PASSWORD=$(openssl rand -base64 $KEY_LEN)

    # 执行安装
    install_ss_rust || return
    install_stls || return
    
    # 保存与启动
    write_config
    allow_port "$STLS_PORT"
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls >/dev/null 2>&1
    systemctl restart ss-rust shadowtls
    
    echo -e "${INFO} 安装完成，检查状态..."
    sleep 2
    if systemctl is-active --quiet shadowtls; then
        show_config
    else
        echo -e "${ERROR} 启动失败！"
        echo -e "请检查日志: journalctl -u shadowtls -n 20"
        echo -e "可能原因: 端口占用、域名解析失败、或系统不支持"
    fi
}

# --- 4. 信息展示 ---

urlsafe_base64() {
    echo -n "$1" | base64 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g'
}

show_config() {
    if ! read_config; then echo -e "${ERROR} 未找到配置"; return; fi
    local ip=$(get_public_ip)
    
    local stls_json="{\"version\":\"3\",\"password\":\"${PASSWORD}\",\"host\":\"${DOMAIN}\",\"port\":\"${STLS_PORT}\",\"address\":\"${ip}\"}"
    local stls_b64=$(urlsafe_base64 "$stls_json")
    local userinfo=$(urlsafe_base64 "${METHOD}:${PASSWORD}")
    local link="ss://${userinfo}@${ip}:${SS_PORT}?shadow-tls=${stls_b64}#STLS-${DOMAIN}"

    clear
    echo -e "${Green_background_prefix} === SS-2022 + ShadowTLS 配置信息 === ${RESET}"
    echo -e "IP地址:   ${Cyan_font_prefix}${ip}${RESET}"
    echo -e "公网端口: ${Cyan_font_prefix}${STLS_PORT}${RESET} (ShadowTLS 监听)"
    echo -e "内部端口: ${Cyan_font_prefix}${SS_PORT}${RESET} (SS-Rust 监听)"
    echo -e "密码:     ${Cyan_font_prefix}${PASSWORD}${RESET}"
    echo -e "加密:     ${Cyan_font_prefix}${METHOD}${RESET}"
    echo -e "伪装域名: ${Cyan_font_prefix}${DOMAIN}${RESET}"
    
    echo -e "\n${Yellow_font_prefix}--- 通用分享链接 ---${RESET}"
    echo -e "${link}"
    
    echo -e "\n${Yellow_font_prefix}--- Mihomo / Clash Meta 配置 ---${RESET}"
    echo -e "proxies:"
    echo -e "  - name: STLS-${DOMAIN}"
    echo -e "    type: ss"
    echo -e "    server: ${ip}"
    echo -e "    port: ${STLS_PORT}"
    echo -e "    password: \"${PASSWORD}\""
    echo -e "    cipher: ${METHOD}"
    echo -e "    plugin: shadow-tls"
    echo -e "    client-fingerprint: chrome"
    echo -e "    plugin-opts:"
    echo -e "      host: \"${DOMAIN}\""
    echo -e "      password: \"${PASSWORD}\""
    echo -e "      version: 3"
    
    echo -e ""
    read -n 1 -s -r -p "按任意键返回..."
}

uninstall() {
    echo -e "${WARN} 正在卸载..."
    systemctl stop ss-rust shadowtls
    systemctl disable ss-rust shadowtls
    rm -f /etc/systemd/system/ss-rust.service /etc/systemd/system/shadowtls.service
    rm -f "$SS_RUST_BIN" "$STLS_BIN"
    rm -rf "$CONFIG_DIR"
    systemctl daemon-reload
    echo -e "${INFO} 卸载完成"
}

# --- 5. 菜单 ---

main_menu() {
    while true; do
        clear
        echo -e "${Cyan_font_prefix}SS-2022 + ShadowTLS 管理脚本 v4.1${RESET}"
        echo -e "=================================="
        if [[ -f "$CONFIG_FILE" ]]; then
            source "$CONFIG_FILE"
            if systemctl is-active --quiet shadowtls; then
                echo -e " 状态: ${Green_font_prefix}运行中${RESET} | 端口: $STLS_PORT | SS端口: $SS_PORT"
            else
                echo -e " 状态: ${Red_font_prefix}已停止${RESET} | 已安装"
            fi
        else
            echo -e " 状态: ${Red_font_prefix}未安装${RESET}"
        fi
        echo -e "=================================="
        echo -e "${Green_font_prefix}1.${RESET} 安装 / 重置 (自定义端口)"
        echo -e "${Green_font_prefix}2.${RESET} 查看连接信息"
        echo -e "${Green_font_prefix}3.${RESET} 重启服务"
        echo -e "${Green_font_prefix}4.${RESET} 停止服务"
        echo -e "${Green_font_prefix}5.${RESET} 卸载"
        echo -e "${Green_font_prefix}0.${RESET} 退出"
        
        read -rp "请选择: " num
        case "$num" in
            1) install_all ;;
            2) show_config ;;
            3) systemctl restart ss-rust shadowtls && echo -e "${INFO} 已重启" && sleep 1 ;;
            4) systemctl stop ss-rust shadowtls && echo -e "${INFO} 已停止" && sleep 1 ;;
            5) uninstall ;;
            0) exit 0 ;;
            *) echo -e "${ERROR} 无效选项" ;;
        esac
    done
}

check_root
main_menu
