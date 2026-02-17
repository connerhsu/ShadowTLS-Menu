#!/bin/bash
# ====================================================
# 作者: jinqians (v4.5 TTY-Fix)
# 仓库: https://github.com/connerhsu/ShadowTLS-Menu
# 描述: SS-Rust + ShadowTLS 一键管理
# 特性: 修复 curl 管道运行时的交互中断问题、增加默认值显示
# ====================================================

# --- 配置 (请修改为您的真实地址) ---
REPO_URL="https://raw.githubusercontent.com/connerhsu/ShadowTLS-Menu/main/ShadowTLS-Menu.sh"
INSTALL_PATH="/usr/local/bin/menu.sh"
BIN_LINK="/usr/local/bin/menu"

# --- 全局变量 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
CONFIG_DIR="/etc/ss-stls"
CONFIG_FILE="${CONFIG_DIR}/config.env"
SS_RUST_BIN="/usr/local/bin/ssserver"
STLS_BIN="/usr/local/bin/shadow-tls"

# --- 颜色 ---
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && RESET="\033[0m" && Yellow_font_prefix="\033[0;33m" && Cyan_font_prefix="\033[0;36m"
INFO="${Green_font_prefix}[信息]${RESET}"
ERROR="${Red_font_prefix}[错误]${RESET}"
WARN="${Yellow_font_prefix}[警告]${RESET}"

# --- 自安装逻辑 (核心修复：解决管道运行退出问题) ---
install_global() {
    # 如果不是本地安装路径，或者脚本是通过 curl 管道运行的
    if [[ "$0" != "$INSTALL_PATH" ]]; then
        echo -e "${INFO} 检测到在线运行，正在安装到系统..."
        
        # 下载自身
        wget -qO "$INSTALL_PATH" "$REPO_URL"
        if [[ ! -s "$INSTALL_PATH" ]]; then
            echo -e "${ERROR} 脚本下载失败！请检查 GitHub 地址是否正确。"
            exit 1
        fi
        
        chmod +x "$INSTALL_PATH"
        ln -sf "$INSTALL_PATH" "$BIN_LINK"
        
        echo -e "${INFO} 安装完成，正在启动..."
        sleep 1
        
        # 关键修复：从 /dev/tty 读取输入，防止 read 命令读取到 EOF 导致退出
        exec bash "$INSTALL_PATH" "$@" < /dev/tty
    fi
}

# --- 基础工具 ---
check_root() { [[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 或 root 运行" && exit 1; }

install_deps() {
    local deps=("wget" "curl" "openssl" "jq" "tar" "lsof")
    local missing=()
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${INFO} 安装依赖: ${missing[*]}"
        if command -v apt-get >/dev/null; then apt-get update && apt-get install -y "${missing[@]}"; 
        elif command -v dnf >/dev/null; then dnf install -y "${missing[@]}"; 
        elif command -v yum >/dev/null; then yum install -y "${missing[@]}"; fi
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64) SS_ARCH="x86_64-unknown-linux-gnu"; ST_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-gnu"; ST_ARCH="aarch64-unknown-linux-musl" ;;
        *) echo -e "${ERROR} 不支持架构: $(uname -m)" && exit 1 ;;
    esac
}

get_public_ip() {
    local ip=$(curl -s4 -m 5 http://api.ip.sb/ip)
    [[ -z "$ip" ]] && ip=$(curl -s4 -m 5 http://ipinfo.io/ip)
    [[ -z "$ip" ]] && ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n 1)
    echo "$ip"
}

check_port() { lsof -i:"$1" >/dev/null 2>&1; }

allow_port() {
    local p=$1
    if command -v ufw >/dev/null; then ufw allow "$p" >/dev/null 2>&1; fi
    if command -v iptables >/dev/null; then iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; iptables -I INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1; fi
}

get_ver() { 
    local v=$(curl -s "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name)
    [[ -z "$v" || "$v" == "null" ]] && echo "" || echo "$v"
}

download() {
    local url=$1; local out=$2; local name=$3
    rm -f "$out"
    echo -e "${INFO} 下载 $name..."
    wget --show-progress -qO "$out" "$url"
    if [[ ! -s "$out" ]]; then echo -e "${ERROR} $name 下载失败 (空文件)"; return 1; fi
    return 0
}

# --- 核心逻辑 ---
install_ss() {
    get_arch
    local v=$(get_ver "shadowsocks/shadowsocks-rust"); [[ -z "$v" ]] && v="v1.18.2"
    download "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${v}/shadowsocks-${v}.${SS_ARCH}.tar.xz" "/tmp/ss.tar.xz" "SS-Rust" || return 1
    tar -xJf /tmp/ss.tar.xz -C /usr/local/bin/ ssserver; chmod +x "$SS_RUST_BIN"; rm -f /tmp/ss.tar.xz
    
    mkdir -p "$CONFIG_DIR"
    cat > "${CONFIG_DIR}/ss.json" <<EOF
{ "server": "127.0.0.1", "server_port": $SS_PORT, "password": "$PASSWORD", "method": "$METHOD", "timeout": 300, "mode": "tcp_and_udp" }
EOF
    cat > /etc/systemd/system/ss-rust.service <<EOF
[Unit]
Description=SS-Rust
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
    local v=$(get_ver "ihciah/shadow-tls"); [[ -z "$v" ]] && v="v3.3.5"
    download "https://github.com/ihciah/shadow-tls/releases/download/${v}/shadow-tls-${ST_ARCH}" "$STLS_BIN" "ShadowTLS" || return 1
    chmod +x "$STLS_BIN"
    
    if ! "$STLS_BIN" --version >/dev/null 2>&1; then echo -e "${ERROR} ShadowTLS 二进制校验失败 (Exec format error)"; return 1; fi

    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS
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
    echo -e "\n${Cyan_font_prefix}=== 配置向导 ===${RESET}"
    
    # 修复交互：明确提示默认值，处理空输入
    read -rp "1. ShadowTLS 公网端口 (默认 8443): " p
    STLS_PORT=${p:-8443}
    
    if check_port "$STLS_PORT"; then systemctl stop shadowtls ss-rust 2>/dev/null; fi
    
    while true; do
        read -rp "2. SS-Rust 内部端口 (默认随机): " p
        if [[ -z "$p" ]]; then 
            SS_PORT=$(shuf -i 20000-60000 -n 1)
            echo -e "${INFO} 已生成随机端口: ${Green_font_prefix}$SS_PORT${RESET}"
            break
        fi
        if [[ "$p" == "$STLS_PORT" ]]; then 
            echo -e "${ERROR} 内部端口不能与公网端口相同"; 
        else 
            SS_PORT=$p
            break
        fi
    done
    
    read -rp "3. 伪装域名 (默认 player.live-video.net): " d
    DOMAIN=${d:-player.live-video.net}
    
    echo "4. 加密方式 (推荐 SS-2022)"
    echo "   1. 2022-blake3-aes-256-gcm"
    echo "   2. 2022-blake3-aes-128-gcm"
    echo "   3. 2022-blake3-chacha20-poly1305"
    
    # 修复交互：处理回车默认值
    read -rp "   选择 [1-3] (默认 1): " m
    m=${m:-1}  # 如果输入为空，则默认为 1
    
    case $m in
        2) METHOD="2022-blake3-aes-128-gcm"; KEY=16 ;;
        3) METHOD="2022-blake3-chacha20-poly1305"; KEY=32 ;;
        *) METHOD="2022-blake3-aes-256-gcm"; KEY=32 ;;
    esac
    
    echo -e "${INFO} 已选择加密: ${Green_font_prefix}$METHOD${RESET}"
    echo -e "${INFO} 正在生成密钥..."
    PASSWORD=$(openssl rand -base64 $KEY)
    
    # 开始安装
    install_ss_rust || return
    install_stls || return
    
    # 写入配置
    mkdir -p "$CONFIG_DIR"
    echo "STLS_PORT=$STLS_PORT" > "$CONFIG_FILE"
    echo "SS_PORT=$SS_PORT" >> "$CONFIG_FILE"
    echo "PASSWORD=$PASSWORD" >> "$CONFIG_FILE"
    echo "METHOD=$METHOD" >> "$CONFIG_FILE"
    echo "DOMAIN=$DOMAIN" >> "$CONFIG_FILE"
    
    # 启动服务
    allow_port "$STLS_PORT"
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls >/dev/null 2>&1
    systemctl restart ss-rust shadowtls
    
    echo -e "${INFO} 服务启动中..."
    sleep 3
    
    if systemctl is-active --quiet shadowtls; then 
        show_conf
    else 
        echo -e "${ERROR} 启动失败！"
        echo -e "请运行: journalctl -u shadowtls -n 20 查看日志"
    fi
}

show_conf() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${ERROR} 未配置" && return
    source "$CONFIG_FILE"; local ip=$(get_public_ip)
    local sj="{\"version\":\"3\",\"password\":\"${PASSWORD}\",\"host\":\"${DOMAIN}\",\"port\":\"${STLS_PORT}\",\"address\":\"${ip}\"}"
    local sb=$(echo -n "$sj" | base64 -w 0 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g')
    local ui=$(echo -n "${METHOD}:${PASSWORD}" | base64 -w 0 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g')
    local link="ss://${ui}@${ip}:${SS_PORT}?shadow-tls=${sb}#STLS-${DOMAIN}"
    
    clear
    echo -e "${Green_background_prefix} 节点信息 ${RESET}"
    echo -e "IP: ${ip}  端口: ${STLS_PORT}  密码: ${PASSWORD}"
    echo -e "加密: ${METHOD}  域名: ${DOMAIN}"
    echo -e "\n${Yellow_font_prefix}通用链接:${RESET} ${link}"
    echo -e "\n${Yellow_font_prefix}Clash Meta:${RESET}"
    echo -e "  - name: STLS-${DOMAIN}\n    type: ss\n    server: ${ip}\n    port: ${STLS_PORT}\n    password: \"${PASSWORD}\"\n    cipher: ${METHOD}\n    plugin: shadow-tls\n    client-fingerprint: chrome\n    plugin-opts:\n      host: \"${DOMAIN}\"\n      password: \"${PASSWORD}\"\n      version: 3"
    echo ""; read -n 1 -s -r -p "按键返回..."
}

uninstall() {
    systemctl stop ss-rust shadowtls; systemctl disable ss-rust shadowtls
    rm -f /etc/systemd/system/ss-rust.service /etc/systemd/system/shadowtls.service
    rm -f "$SS_RUST_BIN" "$STLS_BIN" /usr/local/bin/menu /usr/local/bin/menu.sh
    rm -rf "$CONFIG_DIR"; systemctl daemon-reload
    echo -e "${INFO} 已卸载"
}

menu() {
    while true; do
        clear
        echo -e "${Cyan_font_prefix}ShadowTLS-Menu v4.5${RESET}"
        if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; echo -e "状态: $(systemctl is-active --quiet shadowtls && echo "${Green_font_prefix}运行${RESET}" || echo "${Red_font_prefix}停止${RESET}") | 端口: $STLS_PORT"; else echo "状态: 未安装"; fi
        echo "------------------------"
        echo "1. 安装 / 重置"
        echo "2. 查看链接"
        echo "3. 重启服务"
        echo "4. 停止服务"
        echo "5. 卸载"
        echo "0. 退出"
        read -rp "选择: " n
        case $n in 1) install_all;; 2) show_conf;; 3) systemctl restart ss-rust shadowtls && sleep 1;; 4) systemctl stop ss-rust shadowtls;; 5) uninstall;; 0) exit 0;; *) ;; esac
    done
}

# --- 入口 ---
check_root
install_global "$@"
install_deps
menu
