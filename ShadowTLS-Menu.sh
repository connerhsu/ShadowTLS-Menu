#!/bin/bash
# ====================================================
# 作者: jinqians (v4.6 Final-Fix)
# 仓库: https://github.com/connerhsu/ShadowTLS-Menu
# 描述: SS-Rust + ShadowTLS 一键管理
# 修复: 依赖缺失导致自安装失败、管道运行交互中断
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
Green="\033[32m" && Red="\033[31m" && Yellow="\033[0;33m" && Cyan="\033[0;36m" && RESET="\033[0m"
INFO="${Green}[信息]${RESET}"
ERROR="${Red}[错误]${RESET}"
WARN="${Yellow}[警告]${RESET}"

# --- 0. 基础环境检查 (最优先运行) ---
check_root() { [[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 或 root 运行" && exit 1; }

# 修复：先安装基础工具，防止后面下载自身失败
install_base_deps() {
    local deps=("wget" "curl" "openssl" "jq" "tar" "lsof")
    local missing=()
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${INFO} 正在安装基础依赖: ${missing[*]} ..."
        if command -v apt-get >/dev/null; then
            apt-get update -y >/dev/null && apt-get install -y "${missing[@]}"
        elif command -v dnf >/dev/null; then
            dnf install -y "${missing[@]}"
        elif command -v yum >/dev/null; then
            yum install -y "${missing[@]}"
        else
            echo -e "${ERROR} 无法自动安装依赖，请手动安装: ${missing[*]}" && exit 1
        fi
    fi
}

# --- 1. 自安装/自更新逻辑 (解决管道运行问题) ---
install_global() {
    # 判断条件：如果当前脚本不是安装路径下的文件
    if [[ "$0" != "$INSTALL_PATH" ]]; then
        echo -e "${INFO} 检测到在线/管道运行，正在安装到系统..."
        
        # 尝试使用 wget 或 curl 下载自身
        if command -v wget >/dev/null; then
            wget -qO "$INSTALL_PATH" "$REPO_URL"
        else
            curl -sSL -o "$INSTALL_PATH" "$REPO_URL"
        fi
        
        # 校验下载是否成功
        if [[ ! -s "$INSTALL_PATH" ]]; then
            echo -e "${ERROR} 脚本下载失败！无法连接 GitHub。"
            echo -e "请尝试检查网络或手动下载。"
            exit 1
        fi
        
        chmod +x "$INSTALL_PATH"
        ln -sf "$INSTALL_PATH" "$BIN_LINK"
        
        echo -e "${INFO} 安装完成，正在切换至本地模式..."
        sleep 1
        
        # 关键修复：强制从 tty 读取输入，防止 read 命令失效
        exec bash "$INSTALL_PATH" "$@" < /dev/tty
    fi
}

# --- 2. 工具函数 ---
get_arch() {
    case "$(uname -m)" in
        x86_64) SS_ARCH="x86_64-unknown-linux-gnu"; ST_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-gnu"; ST_ARCH="aarch64-unknown-linux-musl" ;;
        *) echo -e "${ERROR} 不支持架构: $(uname -m)" && exit 1 ;;
    esac
}

get_public_ip() {
    local ip=$(curl -s4 -m 3 http://api.ip.sb/ip)
    [[ -z "$ip" ]] && ip=$(curl -s4 -m 3 http://ipinfo.io/ip)
    [[ -z "$ip" ]] && ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n 1)
    echo "$ip"
}

check_port() { lsof -i:"$1" >/dev/null 2>&1; }

allow_port() {
    local p=$1
    if command -v ufw >/dev/null; then ufw allow "$p" >/dev/null 2>&1; fi
    if command -v iptables >/dev/null; then 
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1
        iptables -I INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1
    fi
}

get_ver() { 
    local v=$(curl -s "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name)
    [[ -z "$v" || "$v" == "null" ]] && echo "" || echo "$v"
}

download_bin() {
    local url=$1; local out=$2; local name=$3
    rm -f "$out"
    echo -e "${INFO} 下载 $name..."
    if command -v wget >/dev/null; then wget -qO "$out" "$url"; else curl -sSL -o "$out" "$url"; fi
    if [[ ! -s "$out" ]]; then echo -e "${ERROR} $name 下载失败 (文件为空)"; return 1; fi
    chmod +x "$out"
    return 0
}

# --- 3. 安装流程 ---
install_ss() {
    get_arch
    local v=$(get_ver "shadowsocks/shadowsocks-rust"); [[ -z "$v" ]] && v="v1.18.2"
    download_bin "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${v}/shadowsocks-${v}.${SS_ARCH}.tar.xz" "/tmp/ss.tar.xz" "SS-Rust" || return 1
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
    download_bin "https://github.com/ihciah/shadow-tls/releases/download/${v}/shadow-tls-${ST_ARCH}" "$STLS_BIN" "ShadowTLS" || return 1
    
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
    echo -e "\n${Cyan}=== 配置向导 ===${RESET}"
    
    # 交互 1: 公网端口
    read -rp "1. ShadowTLS 公网端口 (默认 8443): " p
    STLS_PORT=${p:-8443}
    if check_port "$STLS_PORT"; then systemctl stop shadowtls ss-rust 2>/dev/null; fi
    
    # 交互 2: 内部端口
    while true; do
        read -rp "2. SS-Rust 内部端口 (默认随机): " p
        if [[ -z "$p" ]]; then 
            SS_PORT=$(shuf -i 20000-60000 -n 1)
            echo -e "${INFO} 已生成随机端口: ${Green}$SS_PORT${RESET}"
            break
        fi
        if [[ "$p" == "$STLS_PORT" ]]; then 
            echo -e "${ERROR} 内部端口不能与公网端口相同"; 
        else 
            SS_PORT=$p
            break
        fi
    done
    
    # 交互 3: 域名
    read -rp "3. 伪装域名 (默认 player.live-video.net): " d
    DOMAIN=${d:-player.live-video.net}
    
    # 交互 4: 加密 (修复默认值逻辑)
    echo "4. 加密方式 (推荐 SS-2022)"
    echo "   1. 2022-blake3-aes-256-gcm"
    echo "   2. 2022-blake3-aes-128-gcm"
    echo "   3. 2022-blake3-chacha20-poly1305"
    read -rp "   选择 [1-3] (默认 1): " m
    m=${m:-1}
    
    case $m in
        2) METHOD="2022-blake3-aes-128-gcm"; KEY=16 ;;
        3) METHOD="2022-blake3-chacha20-poly1305"; KEY=32 ;;
        *) METHOD="2022-blake3-aes-256-gcm"; KEY=32 ;;
    esac
    PASSWORD=$(openssl rand -base64 $KEY)
    
    echo -e "${INFO} 正在安装服务..."
    install_ss || return
    install_stls || return
    
    # 写入配置
    mkdir -p "$CONFIG_DIR"
    echo "STLS_PORT=$STLS_PORT" > "$CONFIG_FILE"
    echo "SS_PORT=$SS_PORT" >> "$CONFIG_FILE"
    echo "PASSWORD=$PASSWORD" >> "$CONFIG_FILE"
    echo "METHOD=$METHOD" >> "$CONFIG_FILE"
    echo "DOMAIN=$DOMAIN" >> "$CONFIG_FILE"
    
    allow_port "$STLS_PORT"
    systemctl daemon-reload
    systemctl enable ss-rust shadowtls >/dev/null 2>&1
    systemctl restart ss-rust shadowtls
    
    echo -e "${INFO} 安装完成，等待启动..."
    sleep 3
    if systemctl is-active --quiet shadowtls; then show_conf; else echo -e "${ERROR} 启动失败，请检查日志"; fi
}

show_conf() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${ERROR} 未配置" && return
    source "$CONFIG_FILE"; local ip=$(get_public_ip)
    
    # URL Safe Base64 处理
    local sj="{\"version\":\"3\",\"password\":\"${PASSWORD}\",\"host\":\"${DOMAIN}\",\"port\":\"${STLS_PORT}\",\"address\":\"${ip}\"}"
    local sb=$(echo -n "$sj" | base64 -w 0 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g')
    local ui=$(echo -n "${METHOD}:${PASSWORD}" | base64 -w 0 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g')
    local link="ss://${ui}@${ip}:${SS_PORT}?shadow-tls=${sb}#STLS-${DOMAIN}"
    
    clear
    echo -e "${Green} === 节点配置 === ${RESET}"
    echo -e "IP: ${ip}  端口: ${STLS_PORT}"
    echo -e "密码: ${PASSWORD}"
    echo -e "加密: ${METHOD}"
    echo -e "域名: ${DOMAIN}"
    echo -e "\n${Yellow}通用链接:${RESET} ${link}"
    echo -e "\n${Yellow}Clash Meta:${RESET}"
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
        echo -e "${Cyan}ShadowTLS-Menu v4.6${RESET}"
        if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; echo -e "状态: $(systemctl is-active --quiet shadowtls && echo "${Green}运行${RESET}" || echo "${Red}停止${RESET}") | 端口: $STLS_PORT"; else echo "状态: 未安装"; fi
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

# --- 执行入口 ---
check_root
install_base_deps  # 必须最先执行，确保有 wget/curl
install_global "$@" # 必须第二执行，确保切出管道
menu
