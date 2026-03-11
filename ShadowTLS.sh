#!/bin/bash
# ====================================================
# 作者: jinqians (v4.12 Default-SNI-Update)
# 描述: SS-Rust + ShadowTLS 自动加速 (移除自动BBR，增加内存显示与强制同步)
# ====================================================

# --- 配置 ---
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

# --- 0. 环境与优化 ---
check_root() { [[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 或 root 运行" && exit 1; }

install_base_deps() {
    local common_deps=("wget" "curl" "openssl" "tar" "lsof" "grep" "sed" "awk" "ps")
    local pkg_mgr=""
    local xz_pkg=""
    
    if command -v apt-get >/dev/null; then pkg_mgr="apt-get"; xz_pkg="xz-utils";
    elif command -v dnf >/dev/null; then pkg_mgr="dnf"; xz_pkg="xz";
    elif command -v yum >/dev/null; then pkg_mgr="yum"; xz_pkg="xz";
    elif command -v apk >/dev/null; then pkg_mgr="apk"; xz_pkg="xz"; fi

    local missing=()
    for dep in "${common_deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
    if ! command -v xz >/dev/null 2>&1; then missing+=("$xz_pkg"); fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${INFO} 安装缺失依赖: ${missing[*]} ..."
        if [[ "$pkg_mgr" == "apt-get" ]]; then $pkg_mgr update -y >/dev/null && $pkg_mgr install -y "${missing[@]}";
        elif [[ "$pkg_mgr" == "apk" ]]; then $pkg_mgr add "${missing[@]}";
        elif [[ -n "$pkg_mgr" ]]; then $pkg_mgr install -y "${missing[@]}";
        else echo -e "${ERROR} 无法自动安装依赖"; exit 1; fi
    fi
}

# --- 1. 自安装与强制更新逻辑 ---
install_global() {
    # 如果带有 --updated 参数，说明已经是最新拉取的版本，跳过更新环节防止死循环
    if [[ "$1" == "--updated" ]]; then
        return
    fi
    
    echo -e "${INFO} 正在从 GitHub 强制同步最新版本..."
    local temp_file="/tmp/shadowtls_menu.sh"
    if command -v curl >/dev/null; then 
        curl -sSL -o "$temp_file" "$REPO_URL"
    else 
        wget -qO "$temp_file" "$REPO_URL"
    fi
    
    if [[ -s "$temp_file" ]]; then
        mkdir -p "$(dirname "$INSTALL_PATH")"
        mv -f "$temp_file" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        # 创建 menu 命令软链接，实现全局任意位置唤醒
        ln -sf "$INSTALL_PATH" "$BIN_LINK"
        
        # 重新执行最新脚本，加上 --updated 防止无限循环
        exec bash "$INSTALL_PATH" --updated "$@" < /dev/tty
    else
        echo -e "${ERROR} 同步最新版本失败，将继续使用当前版本。"
        # 如果下载失败，但当前没有安装，也尝试注册全局命令
        if [[ ! -f "$INSTALL_PATH" ]]; then
            cp "$0" "$INSTALL_PATH" 2>/dev/null
            chmod +x "$INSTALL_PATH" 2>/dev/null
            ln -sf "$INSTALL_PATH" "$BIN_LINK" 2>/dev/null
        fi
    fi
}

# --- 2. 工具函数 ---
get_arch() {
    case "$(uname -m)" in
        x86_64) SS_ARCH="x86_64-unknown-linux-gnu"; ST_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64) SS_ARCH="aarch64-unknown-linux-gnu"; ST_ARCH="aarch64-unknown-linux-musl" ;;
        *) echo -e "${ERROR} 不支持架构: $(uname -m)"; exit 1 ;;
    esac
}

get_public_ip() {
    local ip=$(curl -s4 -m 3 http://api.ip.sb/ip)
    [[ -z "$ip" ]] && ip=$(curl -s4 -m 3 http://ipinfo.io/ip)
    echo "$ip"
}

check_port() { lsof -i:"$1" >/dev/null 2>&1; }

allow_port() {
    local p=$1
    if command -v ufw >/dev/null; then ufw allow "$p" >/dev/null 2>&1; fi
    if command -v iptables >/dev/null; then iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; iptables -I INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1; fi
}

get_ver() { 
    local repo=$1
    local v=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/"tag_name": "//;s/"//')
    echo "$v"
}

download_bin() {
    local url=$1; local out=$2; local name=$3
    rm -f "$out"
    echo -e "${INFO} 下载 $name..."
    if command -v wget >/dev/null; then wget -qO "$out" "$url"; else curl -sSL -o "$out" "$url"; fi
    [[ ! -s "$out" ]] && return 1
    chmod +x "$out"
    return 0
}

calc_mem() {
    local pid=$1
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        local mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{sum+=$1} END {print sum}')
        if [[ -n "$mem_kb" && "$mem_kb" -gt 0 ]]; then
            awk "BEGIN {printf \"%.2f MB\", $mem_kb/1024}"
            return
        fi
    fi
    echo "0.00 MB"
}

# --- 3. 安装流程 ---
install_ss() {
    get_arch
    local v=$(get_ver "shadowsocks/shadowsocks-rust"); [[ -z "$v" ]] && v="v1.18.2"
    download_bin "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${v}/shadowsocks-${v}.${SS_ARCH}.tar.xz" "/tmp/ss.tar.xz" "SS-Rust" || return 1
    tar -xJf /tmp/ss.tar.xz -C /usr/local/bin/ ssserver
    chmod +x "$SS_RUST_BIN"; rm -f /tmp/ss.tar.xz
    
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
    
    cat > /etc/systemd/system/shadowtls.service <<EOF
[Unit]
Description=ShadowTLS
After=network.target ss-rust.service
Requires=ss-rust.service
[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=${STLS_BIN} --v3 --strict server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${SS_PORT} --tls ${DOMAIN}:443 --password ${PASSWORD}
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF
}

install_all() {
    echo -e "\n${Cyan}=== 配置向导 ===${RESET}"
    
    read -rp "1. ShadowTLS 公网端口 (默认 8443): " p; STLS_PORT=${p:-8443}
    if check_port "$STLS_PORT"; then systemctl stop shadowtls ss-rust 2>/dev/null; fi
    
    while true; do
        read -rp "2. SS-Rust 内部端口 (默认随机): " p
        if [[ -z "$p" ]]; then SS_PORT=$(shuf -i 20000-60000 -n 1); echo -e "${INFO} 随机端口: ${Green}$SS_PORT${RESET}"; break; fi
        [[ "$p" == "$STLS_PORT" ]] && echo -e "${ERROR} 冲突" || { SS_PORT=$p; break; }
    done
    
    read -rp "3. 伪装域名 (默认 assets.adobe.com): " d; DOMAIN=${d:-assets.adobe.com}
    
    echo "4. 加密方式 (推荐 SS-2022)"
    echo "   1. 2022-blake3-aes-256-gcm (默认)"; echo "   2. 2022-blake3-aes-128-gcm"; echo "   3. 2022-blake3-chacha20-poly1305"
    read -rp "   选择 [1-3]: " m; m=${m:-1}
    case $m in
        2) METHOD="2022-blake3-aes-128-gcm"; KEY=16 ;;
        3) METHOD="2022-blake3-chacha20-poly1305"; KEY=32 ;;
        *) METHOD="2022-blake3-aes-256-gcm"; KEY=32 ;;
    esac
    PASSWORD=$(openssl rand -base64 $KEY)
    
    install_ss || return; install_stls || return
    
    echo "STLS_PORT=$STLS_PORT" > "$CONFIG_FILE"; echo "SS_PORT=$SS_PORT" >> "$CONFIG_FILE"
    echo "PASSWORD=$PASSWORD" >> "$CONFIG_FILE"; echo "METHOD=$METHOD" >> "$CONFIG_FILE"; echo "DOMAIN=$DOMAIN" >> "$CONFIG_FILE"
    
    allow_port "$STLS_PORT"
    systemctl daemon-reload; systemctl enable ss-rust shadowtls >/dev/null 2>&1
    systemctl restart ss-rust shadowtls
    
    sleep 2
    show_conf
}

show_conf() {
    [[ ! -f "$CONFIG_FILE" ]] && echo -e "${ERROR} 未配置" && return
    source "$CONFIG_FILE"; local ip=$(get_public_ip)
    
    local sj="{\"version\":\"3\",\"password\":\"${PASSWORD}\",\"host\":\"${DOMAIN}\",\"port\":\"${STLS_PORT}\",\"address\":\"${ip}\"}"
    local sb=$(echo -n "$sj" | base64 -w 0 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g')
    local ui=$(echo -n "${METHOD}:${PASSWORD}" | base64 -w 0 | tr -d '\n' | sed 's/+/-/g; s/\//_/g; s/=//g')
    
    local stls_link="ss://${ui}@${ip}:${STLS_PORT}?shadow-tls=${sb}#STLS-${DOMAIN}"
    local ss_only="ss://${ui}@${ip}:${SS_PORT}#SS-Only-${DOMAIN}"
    
    clear
    echo -e "${Green} === 配置信息 === ${RESET}"
    echo -e "IP      : ${ip}"
    echo -e "TLS 域名 : ${DOMAIN}"
    echo -e "共享密码 : ${PASSWORD}"
    echo -e "加密方式 : ${METHOD}"
    
    echo -e "\n${Cyan} >> ShadowTLS 混合链接 (Shadowrocket/Nekobox) << ${RESET}"
    echo -e "${stls_link}"
    
    echo -e "\n${Cyan} >> 原始 SS-2022 链接 (直连测试用) << ${RESET}"
    echo -e "${ss_only}"
    
    echo -e "\n${Yellow}>> Mihomo / Clash Meta 配置块${RESET}"
    cat <<EOF
proxies:
  - name: "STLS-${DOMAIN}"
    type: ss
    server: ${ip}
    port: ${STLS_PORT}
    password: "${PASSWORD}"
    cipher: ${METHOD}
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: "${DOMAIN}"
      password: "${PASSWORD}"
      version: 3
    udp: true
EOF
    echo ""; read -n 1 -s -r -p "按任意键返回..."
}

uninstall() {
    systemctl stop ss-rust shadowtls; systemctl disable ss-rust shadowtls
    rm -f /etc/systemd/system/ss-rust.service /etc/systemd/system/shadowtls.service
    rm -f "$SS_RUST_BIN" "$STLS_BIN" "$BIN_LINK" "$INSTALL_PATH"
    rm -rf "$CONFIG_DIR"; systemctl daemon-reload
    echo -e "${INFO} 已卸载"
}

menu() {
    while true; do
        clear
        echo -e "${Cyan}====================================================${RESET}"
        echo -e "${Cyan}       ShadowTLS-Menu v4.12 (双链接版)              ${RESET}"
        echo -e "${Cyan}====================================================${RESET}"
        
        if [[ -f "$CONFIG_FILE" ]]; then 
            source "$CONFIG_FILE"
            local stls_pid=$(systemctl show -p MainPID shadowtls.service 2>/dev/null | cut -d= -f2)
            local ss_pid=$(systemctl show -p MainPID ss-rust.service 2>/dev/null | cut -d= -f2)
            local stls_status="${Red}● 已停止${RESET}"
            local ss_status="${Red}● 已停止${RESET}"
            local stls_mem="0.00 MB"
            local ss_mem="0.00 MB"

            if systemctl is-active --quiet shadowtls; then 
                stls_status="${Green}● 运行中${RESET}"
                stls_mem=$(calc_mem "$stls_pid")
            fi
            if systemctl is-active --quiet ss-rust; then 
                ss_status="${Green}● 运行中${RESET}"
                ss_mem=$(calc_mem "$ss_pid")
            fi

            echo -e " ShadowTLS : $stls_status (内存: $stls_mem) | SS-Rust : $ss_status (内存: $ss_mem)"
            echo -e " 公网端口  : ${Green}${STLS_PORT}${RESET} | 域名: ${Green}${DOMAIN}${RESET}"
        else 
            echo -e " 状态: ${Red}未安装${RESET}"
        fi
        
        echo -e "${Cyan}====================================================${RESET}"
        echo " 1. 安装 / 重置"
        echo " 2. 查看链接 (含 ShadowTLS 和 原始 SS)"
        echo " 3. 重启服务"
        echo " 4. 停止服务"
        echo " 5. 完全卸载"
        echo " 0. 退出"
        read -rp " 请选择 [0-5]: " n
        case $n in 
            1) install_all;; 
            2) show_conf;; 
            3) systemctl restart ss-rust shadowtls && echo -e "${INFO} 已重启" && sleep 1;; 
            4) systemctl stop ss-rust shadowtls && echo -e "${INFO} 已停止" && sleep 1;; 
            5) uninstall; sleep 1;; 
            0) exit 0;; 
        esac
    done
}

check_root
install_base_deps
install_global "$@"
menu
