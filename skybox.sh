#!/bin/bash

# ==========================================================
# SkyVault Drive + sing-box 高级交互式管理脚本
# 架构：
# - sing-box 从 GitHub Release 拉取安装
# - Nginx 仅监听 80 和 127.0.0.1:8443
# - VLESS-REALITY 监听公网 443
# - Reality handshake 转发到 127.0.0.1:8443，自偷自己的伪装网站
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
ENV_FILE="/etc/sing-box/script_env.sh"

WEB_ROOT="/var/www/skyvault-drive"
NGINX_SITE="/etc/nginx/sites-available/skyvault"
NGINX_LINK="/etc/nginx/sites-enabled/skyvault"

# ==========================================================
# root 检查
# ==========================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请以 root 用户运行此脚本！${NC}"
    exit 1
fi

# ==========================================================
# 通用函数
# ==========================================================
pause() {
    read -p "按回车键返回..."
}

safe_var_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9_]/_/g'
}

get_public_ip() {
    curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS4 https://icanhazip.com 2>/dev/null
}

# 更稳的 IPv4 DNS 查询函数：dig -> getent -> nslookup
resolve_domain_ipv4() {
    local domain="$1"
    local result=""

    if command -v dig >/dev/null 2>&1; then
        result=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u)
    fi

    if [ -z "$result" ] && command -v getent >/dev/null 2>&1; then
        result=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    fi

    if [ -z "$result" ] && command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / {print $2}' | grep -E '^[0-9.]+$' | sort -u)
    fi

    echo "$result"
}

urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    LC_ALL=C
    for (( pos=0; pos<strlen; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9])
                o="$c"
                ;;
            *)
                printf -v o '%%%02X' "'$c"
                ;;
        esac
        encoded+="$o"
    done

    echo "$encoded"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

ensure_json() {
    if [ ! -s "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
        return
    fi

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}检测到 config.json 不是有效 JSON，已备份并重建基础配置。${NC}"
        cp "$CONFIG_FILE" "${CONFIG_FILE}.invalid.$(date +%s)"
        cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    fi
}

backup_config() {
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
}

latest_backup_file() {
    ls -t "${CONFIG_FILE}".bak.* 2>/dev/null | head -n 1
}

check_singbox_config() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}sing-box 未安装。${NC}"
        return 1
    fi

    sing-box check -c "$CONFIG_FILE" >/tmp/singbox_check.log 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}sing-box 配置检查失败：${NC}"
        cat /tmp/singbox_check.log
        return 1
    fi

    return 0
}

# ==========================================================
# 初始化环境
# ==========================================================
init_env() {
    mkdir -p "$CONFIG_DIR"
    [ ! -f "$ENV_FILE" ] && touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # shellcheck source=/dev/null
    source "$ENV_FILE" 2>/dev/null

    local need_install=0

    for cmd in jq curl wget openssl socat nginx fuser; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            need_install=1
        fi
    done

    # dig 不存在时尝试安装，但 DNS 检测仍然有 getent/nslookup 备用方案
    if ! command -v dig >/dev/null 2>&1; then
        need_install=1
    fi

    if [ "$need_install" -eq 1 ]; then
        echo -e "${YELLOW}正在安装基础依赖：jq curl wget openssl socat nginx dnsutils cron psmisc...${NC}"

        if ! apt-get update -y; then
            echo -e "${RED}apt update 失败。${NC}"
            echo -e "${YELLOW}请检查 /etc/apt/sources.list 和 /etc/apt/sources.list.d/ 下是否有损坏的软件源。${NC}"
            return 1
        fi

        apt-get install -y jq curl wget openssl socat nginx unzip cron psmisc ca-certificates dnsutils

        # 某些系统 dnsutils 包未提供 dig 时，再尝试 bind9-dnsutils
        if ! command -v dig >/dev/null 2>&1; then
            apt-get install -y bind9-dnsutils
        fi
    fi

    if ! command -v dig >/dev/null 2>&1; then
        echo -e "${YELLOW}提示：dig 仍不可用，DNS 检测将使用 getent/nslookup 备用方式。${NC}"
    fi

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    systemctl enable nginx >/dev/null 2>&1

    ensure_json

    if [ ! -f /usr/local/bin/sk ]; then
        ln -sf "$(realpath "$0")" /usr/local/bin/sk 2>/dev/null
        chmod +x /usr/local/bin/sk 2>/dev/null
    fi

    return 0
}

# ==========================================================
# 1. 安装 / 更新 sing-box
# ==========================================================
install_singbox() {
    clear
    echo -e "${BLUE}[1] 安装 / 更新 sing-box 核心环境${NC}"

    if ! command -v jq >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y jq curl wget tar
    fi

    echo -e "${YELLOW}正在获取 GitHub 最新 Release 版本...${NC}"
    LATEST_VER=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r .tag_name | sed 's/^v//')

    if [ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ]; then
        echo -e "${RED}获取最新版本失败，请检查服务器是否能访问 GitHub。${NC}"
        pause
        return
    fi

    if command -v sing-box >/dev/null 2>&1; then
        LOCAL_VER=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        echo -e "${GREEN}本地版本：v${LOCAL_VER}${NC}"
        echo -e "${GREEN}最新版本：v${LATEST_VER}${NC}"

        if [ "$LOCAL_VER" = "$LATEST_VER" ]; then
            read -p "当前已是最新版，是否强制重装？(y/n): " REINSTALL
            [ "$REINSTALL" != "y" ] && return
        fi
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  SINGBOX_ARCH="linux-amd64" ;;
        aarch64) SINGBOX_ARCH="linux-arm64" ;;
        armv7l)  SINGBOX_ARCH="linux-armv7" ;;
        *)       SINGBOX_ARCH="linux-amd64" ;;
    esac

    echo -e "${GREEN}系统架构：$ARCH -> $SINGBOX_ARCH${NC}"

    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || return

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-${SINGBOX_ARCH}.tar.gz"

    echo -e "${YELLOW}下载地址：$DOWNLOAD_URL${NC}"
    if ! wget -O sing-box.tar.gz "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败。${NC}"
        rm -rf "$TMP_DIR"
        pause
        return
    fi

    if ! tar -xzf sing-box.tar.gz; then
        echo -e "${RED}解压失败。${NC}"
        rm -rf "$TMP_DIR"
        pause
        return
    fi

    systemctl stop sing-box >/dev/null 2>&1

    if [ ! -f sing-box-*/sing-box ]; then
        echo -e "${RED}未找到 sing-box 可执行文件。${NC}"
        rm -rf "$TMP_DIR"
        pause
        return
    fi

    cp sing-box-*/sing-box /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cd /root || true
    rm -rf "$TMP_DIR"

    ensure_json

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1

    if check_singbox_config; then
        systemctl restart sing-box
        echo -e "${GREEN}sing-box 安装 / 更新完成。当前状态：$(systemctl is-active sing-box)${NC}"
    else
        echo -e "${RED}配置检查失败，未启动 sing-box。${NC}"
    fi

    pause
}

# ==========================================================
# 2. 添加 Shadowsocks 2022 节点
# ==========================================================
add_ss2022() {
    clear
    echo -e "${BLUE}[2] 添加 Shadowsocks 2022 节点${NC}"

    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}请先安装 sing-box。${NC}"
        pause
        return
    fi

    read -p "请输入节点标签，例如 ss-hk: " TAG
    [ -z "$TAG" ] && TAG="SS_2022_$(openssl rand -hex 3)"

    if jq -e --arg tag "$TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}标签已存在，请换一个。${NC}"
        pause
        return
    fi

    read -p "请输入端口，回车随机: " PORT
    [ -z "$PORT" ] && PORT=$((RANDOM % 55535 + 10000))

    if ! valid_port "$PORT"; then
        echo -e "${RED}端口无效。${NC}"
        pause
        return
    fi

    if jq -e --argjson port "$PORT" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}端口已被已有入站占用。${NC}"
        pause
        return
    fi

    echo "请选择加密方式："
    echo "1) 2022-blake3-aes-128-gcm"
    echo "2) 2022-blake3-aes-256-gcm 默认"
    echo "3) 2022-blake3-chacha20-poly1305"
    read -p "请选择 [1-3]: " METHOD_CHOICE

    case "$METHOD_CHOICE" in
        1)
            METHOD="2022-blake3-aes-128-gcm"
            PASSWORD=$(sing-box generate rand --base64 16 2>/dev/null || openssl rand -base64 16)
            ;;
        3)
            METHOD="2022-blake3-chacha20-poly1305"
            PASSWORD=$(sing-box generate rand --base64 32 2>/dev/null || openssl rand -base64 32)
            ;;
        *)
            METHOD="2022-blake3-aes-256-gcm"
            PASSWORD=$(sing-box generate rand --base64 32 2>/dev/null || openssl rand -base64 32)
            ;;
    esac

    backup_config

    TMP=$(mktemp)
    jq \
      --arg tag "$TAG" \
      --arg method "$METHOD" \
      --arg password "$PASSWORD" \
      --argjson port "$PORT" \
      '.inbounds += [{
        "type": "shadowsocks",
        "tag": $tag,
        "listen": "::",
        "listen_port": $port,
        "method": $method,
        "password": $password
      }]' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"

    if ! check_singbox_config; then
        echo -e "${RED}新配置无效，正在回滚。${NC}"
        BAK=$(latest_backup_file)
        [ -n "$BAK" ] && cp "$BAK" "$CONFIG_FILE"
        pause
        return
    fi

    systemctl restart sing-box

    LOCAL_IP=$(get_public_ip)
    BASE64_CREDS=$(echo -n "${METHOD}:${PASSWORD}" | base64 | tr -d '\n' | tr -d '=')
    URL_TAG=$(urlencode "$TAG")
    SHARE_LINK="ss://${BASE64_CREDS}@${LOCAL_IP}:${PORT}#${URL_TAG}"

    echo -e "${GREEN}Shadowsocks 2022 节点已添加。${NC}"
    echo "标签：$TAG"
    echo "端口：$PORT"
    echo "加密：$METHOD"
    echo "密钥：$PASSWORD"
    echo -e "${YELLOW}分享链接：${NC}"
    echo "$SHARE_LINK"

    pause
}

# ==========================================================
# 3. 部署 / 更新 SkyVault Drive 伪装网站 + SSL
# ==========================================================
deploy_website() {
    clear
    echo -e "${BLUE}[3] 部署 / 更新 SkyVault Drive 伪装网站 + SSL${NC}"

    read -p "请输入绑定域名，例如 drive.example.com: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空。${NC}"
        pause
        return
    fi

    LOCAL_IP=$(get_public_ip)
    DOMAIN_IPS=$(resolve_domain_ipv4 "$DOMAIN")

    echo -e "${YELLOW}本机 IPv4：${LOCAL_IP:-获取失败}${NC}"
    echo -e "${YELLOW}域名 A 记录：${DOMAIN_IPS:-未查询到}${NC}"

    if [ -z "$LOCAL_IP" ]; then
        echo -e "${RED}无法获取本机公网 IPv4，请检查服务器网络。${NC}"
        pause
        return
    fi

    if [ -z "$DOMAIN_IPS" ]; then
        echo -e "${RED}未能查询到域名 A 记录。${NC}"
        echo -e "${YELLOW}这可能是 VPS 本机 DNS 查询异常，不一定代表 DNS 面板没有记录。${NC}"
        read -p "是否继续尝试申请证书？(y/n): " FORCE
        [ "$FORCE" != "y" ] && return
    elif ! echo "$DOMAIN_IPS" | grep -qx "$LOCAL_IP"; then
        echo -e "${RED}警告：域名 A 记录未解析到本机 IPv4。${NC}"
        echo -e "${YELLOW}如果使用 Cloudflare，请确保该记录为 DNS only / 灰云。${NC}"
        read -p "是否继续？(y/n): " FORCE
        [ "$FORCE" != "y" ] && return
    else
        echo -e "${GREEN}域名解析校验通过：$DOMAIN -> $LOCAL_IP${NC}"
    fi

    sed -i '/^MY_DOMAIN=/d' "$ENV_FILE"
    echo "MY_DOMAIN=\"$DOMAIN\"" >> "$ENV_FILE"

    mkdir -p "$WEB_ROOT/.well-known/acme-challenge"
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    cat > "$WEB_ROOT/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SkyVault Drive - Secure Private Storage</title>
    <style>
        body {
            margin: 0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            background: #0f172a;
            color: #e2e8f0;
            font-family: Arial, sans-serif;
        }
        .card {
            width: 420px;
            max-width: calc(100vw - 40px);
            padding: 36px;
            border-radius: 24px;
            background: rgba(15, 23, 42, .86);
            border: 1px solid rgba(148, 163, 184, .18);
            box-shadow: 0 30px 80px rgba(0,0,0,.35);
            text-align: center;
        }
        .logo {
            width: 70px;
            height: 70px;
            margin: 0 auto 18px;
            border-radius: 20px;
            background: linear-gradient(135deg, #4f46e5, #7c3aed);
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 34px;
        }
        h1 {
            margin: 0;
            font-size: 28px;
        }
        p {
            color: #94a3b8;
            line-height: 1.7;
        }
        input {
            width: 100%;
            box-sizing: border-box;
            margin-top: 12px;
            padding: 13px;
            border-radius: 12px;
            border: 1px solid #334155;
            background: #020617;
            color: #e2e8f0;
        }
        button {
            width: 100%;
            margin-top: 18px;
            padding: 13px;
            border: 0;
            border-radius: 12px;
            background: linear-gradient(135deg, #4f46e5, #7c3aed);
            color: white;
            font-weight: bold;
            cursor: pointer;
        }
        .foot {
            margin-top: 24px;
            color: #64748b;
            font-size: 12px;
        }
    </style>
</head>
<body>
<div class="card">
    <div class="logo">☁</div>
    <h1>SkyVault Drive</h1>
    <p>Distributed encrypted storage gateway</p>
    <form onsubmit="event.preventDefault(); alert('Gateway authentication failed.');">
        <input placeholder="Node UID" required>
        <input placeholder="Cluster Key" type="password" required>
        <button>Enter Secure Area</button>
    </form>
    <div class="foot">STATUS: ENCRYPTED · SkyVault Infrastructure</div>
</div>
</body>
</html>
EOF

    # 先写 HTTP 配置，用于 webroot 签发和后续续签
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    ln -sf "$NGINX_SITE" "$NGINX_LINK"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null

    if ! nginx -t; then
        echo -e "${RED}Nginx HTTP 配置检测失败。${NC}"
        pause
        return
    fi

    systemctl restart nginx

    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${YELLOW}正在安装 acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email="admin@$DOMAIN"
    fi

    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt

    echo -e "${YELLOW}正在使用 webroot 模式申请 ECC 证书...${NC}"
    "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" -w "$WEB_ROOT" --keylength ec-256

    if [ ! -f "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer" ]; then
        echo -e "${RED}证书签发失败。请检查 DNS、80 端口、防火墙、Cloudflare 是否灰云。${NC}"
        pause
        return
    fi

    mkdir -p "/etc/nginx/ssl/$DOMAIN"

    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --key-file "/etc/nginx/ssl/$DOMAIN/privkey.key" \
        --fullchain-file "/etc/nginx/ssl/$DOMAIN/fullchain.cer" \
        --reloadcmd "systemctl reload nginx"

    # 最终配置：
    # 80：用于 acme.sh 后续 webroot 续签
    # 127.0.0.1:8443：用于 Reality 自偷 handshake
    cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $WEB_ROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/privkey.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $WEB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    if ! nginx -t; then
        echo -e "${RED}Nginx SSL 配置检测失败。${NC}"
        pause
        return
    fi

    systemctl restart nginx

    echo -e "${GREEN}SkyVault Drive 伪装网站部署完成。${NC}"
    echo -e "${YELLOW}说明：Nginx HTTPS 只监听 127.0.0.1:8443。公网 443 将由 sing-box Reality 接管。${NC}"
    echo -e "${YELLOW}完成第 4 步后，Reality 探测流量会看到这个伪装网站。${NC}"

    pause
}

# ==========================================================
# 4. 添加 VLESS-REALITY 自偷节点
# ==========================================================
add_vless_reality() {
    clear
    echo -e "${BLUE}[4] 添加 VLESS-REALITY 自偷节点${NC}"

    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}请先安装 sing-box。${NC}"
        pause
        return
    fi

    # shellcheck source=/dev/null
    source "$ENV_FILE" 2>/dev/null

    if [ -z "$MY_DOMAIN" ]; then
        echo -e "${YELLOW}未检测到已部署域名。${NC}"
        read -p "请输入用于自偷的域名: " MY_DOMAIN
        [ -z "$MY_DOMAIN" ] && return
    fi

    if [ ! -f "/etc/nginx/ssl/$MY_DOMAIN/fullchain.cer" ]; then
        echo -e "${RED}未找到该域名证书，请先执行第 3 步部署伪装网站。${NC}"
        pause
        return
    fi

    read -p "请输入节点标签，例如 vless_reality: " TAG
    [ -z "$TAG" ] && TAG="VLESS_Reality_$(openssl rand -hex 3)"

    if jq -e --arg tag "$TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}标签已存在。${NC}"
        pause
        return
    fi

    if jq -e '.inbounds[]? | select(.listen_port == 443)' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}已有入站占用 443。Reality 自偷模式建议只保留一个公网 443 入站。${NC}"
        pause
        return
    fi

    UUID=$(sing-box generate uuid)
    KEYPAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep -i "PublicKey" | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}Reality 密钥生成失败。${NC}"
        pause
        return
    fi

    backup_config

    TMP=$(mktemp)
    jq \
      --arg tag "$TAG" \
      --arg uuid "$UUID" \
      --arg domain "$MY_DOMAIN" \
      --arg private_key "$PRIVATE_KEY" \
      --arg short_id "$SHORT_ID" \
      '.inbounds += [{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": 443,
        "sniff": true,
        "sniff_override_destination": true,
        "users": [
          {
            "uuid": $uuid,
            "flow": "xtls-rprx-vision"
          }
        ],
        "tls": {
          "enabled": true,
          "server_name": $domain,
          "reality": {
            "enabled": true,
            "handshake": {
              "server": "127.0.0.1",
              "server_port": 8443
            },
            "private_key": $private_key,
            "short_id": [
              $short_id
            ]
          }
        }
      }]' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"

    SAFE_TAG=$(safe_var_name "$TAG")
    sed -i "/^${SAFE_TAG}_PUBLIC_KEY=/d" "$ENV_FILE"
    sed -i "/^${SAFE_TAG}_SHORT_ID=/d" "$ENV_FILE"
    echo "${SAFE_TAG}_PUBLIC_KEY=\"$PUBLIC_KEY\"" >> "$ENV_FILE"
    echo "${SAFE_TAG}_SHORT_ID=\"$SHORT_ID\"" >> "$ENV_FILE"

    if ! check_singbox_config; then
        echo -e "${RED}新配置无效，正在回滚。${NC}"
        BAK=$(latest_backup_file)
        [ -n "$BAK" ] && cp "$BAK" "$CONFIG_FILE"
        sed -i "/^${SAFE_TAG}_PUBLIC_KEY=/d" "$ENV_FILE"
        sed -i "/^${SAFE_TAG}_SHORT_ID=/d" "$ENV_FILE"
        pause
        return
    fi

    systemctl restart sing-box

    if ! systemctl is-active sing-box >/dev/null 2>&1; then
        echo -e "${RED}sing-box 启动失败，请查看日志：journalctl -u sing-box -e${NC}"
        pause
        return
    fi

    URL_TAG=$(urlencode "$TAG")
    SHARE_LINK="vless://${UUID}@${MY_DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MY_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${URL_TAG}"

    echo -e "${GREEN}VLESS-REALITY 自偷节点创建成功。${NC}"
    echo "标签：$TAG"
    echo "域名/SNI：$MY_DOMAIN"
    echo "端口：443"
    echo "UUID：$UUID"
    echo "PublicKey：$PUBLIC_KEY"
    echo "ShortID：$SHORT_ID"
    echo -e "${YELLOW}分享链接：${NC}"
    echo "$SHARE_LINK"

    pause
}

# ==========================================================
# 5. 查看配置和分享链接
# ==========================================================
view_configs() {
    clear
    echo -e "${BLUE}当前节点配置与分享链接${NC}"

    # shellcheck source=/dev/null
    source "$ENV_FILE" 2>/dev/null

    LOCAL_IP=$(get_public_ip)
    LENGTH=$(jq '.inbounds | length' "$CONFIG_FILE")

    if [ "$LENGTH" -eq 0 ]; then
        echo -e "${YELLOW}暂无节点。${NC}"
        pause
        return
    fi

    for ((i=0; i<LENGTH; i++)); do
        TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
        TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
        PORT=$(jq -r ".inbounds[$i].listen_port" "$CONFIG_FILE")

        echo -e "${PURPLE}[$i] $TAG ($TYPE)${NC}"

        if [ "$TYPE" = "shadowsocks" ]; then
            METHOD=$(jq -r ".inbounds[$i].method" "$CONFIG_FILE")
            PASSWORD=$(jq -r ".inbounds[$i].password" "$CONFIG_FILE")
            BASE64_CREDS=$(echo -n "${METHOD}:${PASSWORD}" | base64 | tr -d '\n' | tr -d '=')
            URL_TAG=$(urlencode "$TAG")
            LINK="ss://${BASE64_CREDS}@${LOCAL_IP}:${PORT}#${URL_TAG}"

            echo "端口：$PORT"
            echo "加密：$METHOD"
            echo "密钥：$PASSWORD"
            echo -e "${YELLOW}链接：$LINK${NC}"

        elif [ "$TYPE" = "vless" ]; then
            UUID=$(jq -r ".inbounds[$i].users[0].uuid" "$CONFIG_FILE")
            DOMAIN=$(jq -r ".inbounds[$i].tls.server_name" "$CONFIG_FILE")

            SAFE_TAG=$(safe_var_name "$TAG")
            eval PUB_KEY="\$${SAFE_TAG}_PUBLIC_KEY"
            eval SID="\$${SAFE_TAG}_SHORT_ID"

            if [ -z "$PUB_KEY" ] || [ -z "$SID" ]; then
                echo -e "${RED}警告：未找到 PublicKey 或 ShortID，可能环境文件被清理。${NC}"
            else
                URL_TAG=$(urlencode "$TAG")
                LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB_KEY}&sid=${SID}&type=tcp#${URL_TAG}"
                echo "端口：443"
                echo "UUID：$UUID"
                echo "SNI：$DOMAIN"
                echo "PublicKey：$PUB_KEY"
                echo "ShortID：$SID"
                echo -e "${YELLOW}链接：$LINK${NC}"
            fi
        fi

        echo "--------------------------------------------------"
    done

    pause
}

# ==========================================================
# 6. 修改节点
# ==========================================================
modify_config() {
    clear
    echo -e "${BLUE}[6] 修改节点${NC}"

    LENGTH=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$LENGTH" -eq 0 ]; then
        echo -e "${YELLOW}暂无节点可修改。${NC}"
        pause
        return
    fi

    for ((i=0; i<LENGTH; i++)); do
        TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
        TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
        echo "$i) $TAG ($TYPE)"
    done

    read -p "请选择索引: " INDEX
    if ! [[ "$INDEX" =~ ^[0-9]+$ ]] || [ "$INDEX" -ge "$LENGTH" ]; then
        echo -e "${RED}无效索引。${NC}"
        pause
        return
    fi

    TYPE=$(jq -r ".inbounds[$INDEX].type" "$CONFIG_FILE")

    backup_config

    if [ "$TYPE" = "shadowsocks" ]; then
        read -p "新端口，回车不改: " NEW_PORT

        if [ -n "$NEW_PORT" ]; then
            if ! valid_port "$NEW_PORT"; then
                echo -e "${RED}端口无效。${NC}"
                pause
                return
            fi

            if jq -e --argjson port "$NEW_PORT" --argjson idx "$INDEX" '.inbounds[]? | select(.listen_port == $port) | select(. != .inbounds[$idx])' "$CONFIG_FILE" >/dev/null 2>&1; then
                echo -e "${RED}端口可能已被占用，请换一个。${NC}"
                pause
                return
            fi

            TMP=$(mktemp)
            jq --argjson port "$NEW_PORT" ".inbounds[$INDEX].listen_port = \$port" "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"
        fi

        read -p "是否重置密码？(y/n): " RESET_PASS
        if [ "$RESET_PASS" = "y" ]; then
            METHOD=$(jq -r ".inbounds[$INDEX].method" "$CONFIG_FILE")
            if [ "$METHOD" = "2022-blake3-aes-128-gcm" ]; then
                NEW_PASS=$(sing-box generate rand --base64 16 2>/dev/null || openssl rand -base64 16)
            else
                NEW_PASS=$(sing-box generate rand --base64 32 2>/dev/null || openssl rand -base64 32)
            fi

            TMP=$(mktemp)
            jq --arg pass "$NEW_PASS" ".inbounds[$INDEX].password = \$pass" "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"
        fi

    elif [ "$TYPE" = "vless" ]; then
        read -p "是否重置 UUID？(y/n): " RESET_UUID
        if [ "$RESET_UUID" = "y" ]; then
            NEW_UUID=$(sing-box generate uuid)
            TMP=$(mktemp)
            jq --arg uuid "$NEW_UUID" ".inbounds[$INDEX].users[0].uuid = \$uuid" "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"
        fi
    fi

    if ! check_singbox_config; then
        echo -e "${RED}修改后配置无效，正在回滚。${NC}"
        BAK=$(latest_backup_file)
        [ -n "$BAK" ] && cp "$BAK" "$CONFIG_FILE"
        pause
        return
    fi

    systemctl restart sing-box
    echo -e "${GREEN}修改已生效。${NC}"

    pause
}

# ==========================================================
# 7. 删除节点
# ==========================================================
delete_config() {
    clear
    echo -e "${BLUE}[7] 删除节点${NC}"

    LENGTH=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$LENGTH" -eq 0 ]; then
        echo -e "${YELLOW}暂无节点。${NC}"
        pause
        return
    fi

    for ((i=0; i<LENGTH; i++)); do
        TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
        TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
        echo "$i) $TAG ($TYPE)"
    done

    read -p "请输入要删除的索引: " DEL_INDEX
    if ! [[ "$DEL_INDEX" =~ ^[0-9]+$ ]] || [ "$DEL_INDEX" -ge "$LENGTH" ]; then
        echo -e "${RED}无效索引。${NC}"
        pause
        return
    fi

    TARGET_TAG=$(jq -r ".inbounds[$DEL_INDEX].tag" "$CONFIG_FILE")
    SAFE_TAG=$(safe_var_name "$TARGET_TAG")

    read -p "确认删除 [$TARGET_TAG]？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    backup_config

    TMP=$(mktemp)
    jq --arg tag "$TARGET_TAG" 'del(.inbounds[] | select(.tag == $tag))' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"

    sed -i "/^${SAFE_TAG}_PUBLIC_KEY=/d" "$ENV_FILE"
    sed -i "/^${SAFE_TAG}_SHORT_ID=/d" "$ENV_FILE"

    if ! check_singbox_config; then
        echo -e "${RED}删除后配置异常，正在回滚。${NC}"
        BAK=$(latest_backup_file)
        [ -n "$BAK" ] && cp "$BAK" "$CONFIG_FILE"
        pause
        return
    fi

    systemctl restart sing-box
    echo -e "${GREEN}节点已删除。${NC}"

    pause
}

# ==========================================================
# 8. 卸载
# ==========================================================
purge_uninstall() {
    clear
    echo -e "${RED}=================================================="
    echo -e "       危险：即将卸载 sing-box、脚本配置、伪装网站"
    echo -e "==================================================${NC}"

    read -p "确认卸载？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    read -p "是否同时卸载 Nginx？(y/n): " REMOVE_NGINX

    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1

    rm -f /etc/systemd/system/sing-box.service
    rm -f /usr/local/bin/sing-box
    rm -rf "$CONFIG_DIR"
    rm -rf "$WEB_ROOT"
    rm -f "$NGINX_SITE" "$NGINX_LINK"
    rm -f /usr/local/bin/sk

    systemctl daemon-reload

    if [ "$REMOVE_NGINX" = "y" ]; then
        systemctl stop nginx >/dev/null 2>&1
        apt-get purge -y nginx nginx-common nginx-core >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        rm -rf /etc/nginx /var/log/nginx
    else
        systemctl restart nginx >/dev/null 2>&1
    fi

    echo -e "${GREEN}卸载完成。${NC}"
    exit 0
}

# ==========================================================
# 主菜单
# ==========================================================
while true; do
    if ! init_env; then
        echo -e "${RED}初始化环境失败，请先修复系统依赖或 APT 源问题。${NC}"
        pause
        continue
    fi

    clear
    echo -e "${BLUE}=================================================="
    echo -e "        SkyVault Drive 高级交互式菜单"
    echo -e "==================================================${NC}"
    echo -e " ${GREEN}1)${NC} 安装 / 更新 sing-box 核心"
    echo -e " ${GREEN}2)${NC} 添加 Shadowsocks 2022 节点"
    echo -e " ${GREEN}3)${NC} 部署 / 更新 SkyVault Drive 伪装网站 + SSL"
    echo -e " ${GREEN}4)${NC} 添加 VLESS-REALITY 节点，自偷第 3 步伪装站"
    echo -e " ${YELLOW}5)${NC} 查看节点配置与分享链接"
    echo -e " ${BLUE}6)${NC} 修改现有节点"
    echo -e " ${PURPLE}7)${NC} 删除节点"
    echo -e " ${RED}8)${NC} 卸载环境"
    echo -e " 0) 退出"
    echo -e "${BLUE}==================================================${NC}"

    read -p "请选择操作 [0-8]: " CHOICE

    case "$CHOICE" in
        1) install_singbox ;;
        2) add_ss2022 ;;
        3) deploy_website ;;
        4) add_vless_reality ;;
        5) view_configs ;;
        6) modify_config ;;
        7) delete_config ;;
        8) purge_uninstall ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}输入错误。${NC}"; sleep 1 ;;
    esac
done
