#!/bin/bash

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
ENV_FILE="/etc/sing-box/script_env.sh"

# 确保以 root 用户运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请以 root 用户运行此脚本！${NC}"
    exit 1
fi

# URL 编码辅助函数
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "$c"
        esac
        encoded="${encoded}${o}"
    done
    echo "${encoded}"
}

# 初始化系统环境与必备工具
init_env() {
    mkdir -p /etc/sing-box
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE"
    fi
    source "$ENV_FILE"

    # 全自动配置本地 sk 快捷键
    if ! grep -q "alias sk=" ~/.bashrc; then
        echo "alias sk='/root/skybox.sh'" >> ~/.bashrc
    fi

    # 检查并安装基础依赖
    if ! command -v jq &> /dev/null || ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}正在安装系统核心组件 (Nginx, jq, cron, socat, openssl)...${NC}"
        apt-get update -y
        apt-get install -y jq curl wget openssl socat nginx unzip cron
        systemctl enable nginx
        systemctl start nginx
    fi

    # 初始化最基础的 sing-box 骨架
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$CONFIG_FILE"
    fi
}

# 1. 纯净流：智能版本校验 + 架构识别部署
install_singbox() {
    echo -e "${BLUE}[1] 开始检查 sing-box 核心环境...${NC}"
    
    # 获取 GitHub 最新稳定版版本号
    echo -e "${YELLOW}正在检索 GitHub 最新 Release 版本...${NC}"
    LATEST_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    if [ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ]; then
        LATEST_VER="1.11.2" # 生产保底版本
    fi
    
    # 本地版本校验逻辑
    if command -v sing-box &> /dev/null; then
        LOCAL_VER=$(sing-box version 2>&1 | head -n 1 | awk '{print $3}')
        echo -e "${GREEN}当前本地已安装版本: v${LOCAL_VER}${NC}"
        echo -e "${GREEN}GitHub 最新发布版本: v${LATEST_VER}${NC}"
        
        if [ "$LOCAL_VER" = "$LATEST_VER" ]; then
            echo -e "${PURPLE}➔ 您的 sing-box 核心已经是最新版本，无需更新。${NC}"
            read -p "是否强制重新安装？(y/n): " REINSTALL
            if [ "$REINSTALL" != "y" ]; then
                read -p "操作已取消，按回车键返回..."
                return
            fi
        fi
    fi
    
    # ⚡ 智能架构自动识别
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  SINGBOX_ARCH="linux-amd64" ;;
        aarch64) SINGBOX_ARCH="linux-arm64" ;;
        armv7l)  SINGBOX_ARCH="linux-armv7" ;;
        *)       SINGBOX_ARCH="linux-amd64" ;;
    esac
    echo -e "${GREEN}匹配系统架构: ${ARCH} -> ${SINGBOX_ARCH}${NC}"
    echo -e "${BLUE}目标拉取版本: v${LATEST_VER}${NC}"
    
    # 停止旧服务防止文件占用
    systemctl stop sing-box &>/dev/null
    
    # 下载并部署
    rm -f sing-box.tar.gz
    wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-${SINGBOX_ARCH}.tar.gz"
    
    if [ -f sing-box.tar.gz ] && [ -s sing-box.tar.gz ]; then
        tar -zxvf sing-box.tar.gz
        mv sing-box-*/sing-box /usr/local/bin/
        rm -rf sing-box*
        chmod +x /usr/local/bin/sing-box
        
        # 建立标准 Systemd 守护进程服务
        cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    else
        echo -e "${RED}错误：从 GitHub 下载二进制包失败，请检查 VPS 网络！${NC}"
        read -p "按回车键返回..."
        return
    fi
    
    # 刷新服务并启动核心
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    
    echo -e "${GREEN}sing-box 部署/更新完成！当前实际运行状态：$(systemctl is-active sing-box)${NC}"
    read -p "按回车键返回..."
}

# 2. 添加 Shadowsocks 2022 节点
add_ss2022() {
    echo -e "${BLUE}[2] 添加 Shadowsocks 2022 节点${NC}"
    read -p "请输入节点别名标签 (例如 ss-hk): " TAG
    if [ -z "$TAG" ]; then TAG="SS-2022_$(openssl rand -hex 3)"; fi
    
    if jq -e --arg tag "$TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}错误：该标签名称已被占用，请输入其他名称！${NC}"
        return
    fi

    read -p "请输入端口 (默认随机): " PORT
    if [ -z "$PORT" ]; then PORT=$((RANDOM % 55535 + 10000)); fi

    echo -e "请选择 Shadowsocks 2022 加密方案:"
    echo -e " 1) 2022-blake3-aes-128-gcm (轻量高效)"
    echo -e " 2) 2022-blake3-aes-256-gcm (极致安全 - 默认)"
    echo -e " 3) 2022-blake3-chacha20-poly1305 (移动端优选)"
    read -p "请选择 [1-3]: " METHOD_CHOICE

    case $METHOD_CHOICE in
        1) 
            METHOD="2022-blake3-aes-128-gcm"
            PASSWORD=$(openssl rand -base64 16)
            ;;
        3)
            METHOD="2022-blake3-chacha20-poly1305"
            PASSWORD=$(openssl rand -base64 32)
            ;;
        *)
            METHOD="2022-blake3-aes-256-gcm"
            PASSWORD=$(openssl rand -base64 32)
            ;;
    esac

    jq --argjson new '{"type":"shadowsocks","tag":"'$TAG'","listen":"::","listen_port":'$PORT',"method":"'$METHOD'","password":"'$PASSWORD'"}' \
       '.inbounds += [$new]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    systemctl restart sing-box
    echo -e "${GREEN}Shadowsocks 2022 节点添加成功！可在菜单 [5] 中查看链接。${NC}"
    read -p "按回车键返回..."
}

# 3. 部署 SkyVault Drive 伪装网站 + 申请安全自动续订证书
deploy_website() {
    echo -e "${BLUE}[3] 部署/更新 SkyVault Drive 伪装网站与 SSL 自动化环境${NC}"
    read -p "请输入你要绑定的域名 (例如: drive.yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空！${NC}"; return; fi

    echo -e "${YELLOW}进行全球网络边界解析校验...${NC}"
    LOCAL_IP=$(curl -s4 icanhazip.com || curl -s4 api.ipify.org)
    DOMAIN_IP=$(getent ahosts "$DOMAIN" | head -n 1 | awk '{print $1}')
    if [ "$LOCAL_IP" != "$DOMAIN_IP" ]; then
        echo -e "${RED}警告：解析出的 IP ($DOMAIN_IP) 与本服务器公网 IP ($LOCAL_IP) 不一致。${NC}"
        read -p "是否强行继续？(y/n): " FORCE
        if [ "$FORCE" != "y" ]; then return; fi
    fi

    sed -i '/MY_DOMAIN=/d' "$ENV_FILE"
    echo "MY_DOMAIN=\"$DOMAIN\"" >> "$ENV_FILE"

    mkdir -p /var/www/skyvault-drive/.well-known/acme-challenge

    cat << EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root /var/www/skyvault-drive;
    location /.well-known/acme-challenge/ {
        allow all;
    }
}
EOF
    systemctl restart nginx

    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="admin@$DOMAIN"
        source ~/.bashrc
    fi
    
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot /var/www/skyvault-drive --tailscale no --non-interactive

    if [ ! -f "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer" ]; then
        echo -e "${RED}证书签发失败！请确认 80 端口无占用且防火墙已放行。${NC}"
        read -p "按回车键返回..."
        return
    fi

    # 渲染前端伪装页
    cat << 'EOF' > /var/www/skyvault-drive/index.html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SkyVault Drive - 安全私有云存储</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-[#0f172a] text-slate-200 font-sans flex items-center justify-center min-h-screen selection:bg-indigo-500 selection:text-white">
    <div class="absolute inset-0 bg-[radial-gradient(circle_at_top_right,rgba(99,102,241,0.08),transparent_45%)] pointer-events-none"></div>
    <div class="absolute inset-0 bg-[linear-gradient(to_bottom,rgba(15,23,42,0.4),#0f172a)] pointer-events-none"></div>
    
    <div class="max-w-md w-full bg-slate-900/40 p-8 rounded-2xl shadow-2xl border border-slate-800/80 backdrop-blur-xl relative z-10">
        <div class="text-center mb-8">
            <div class="w-16 h-16 bg-gradient-to-tr from-indigo-600 to-violet-500 rounded-2xl flex items-center justify-center mx-auto mb-4 shadow-xl shadow-indigo-900/30 border border-indigo-400/20">
                <svg class="w-8 h-8 text-white animate-pulse" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.8" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"></path></svg>
            </div>
            <h2 class="text-2xl font-bold tracking-tight bg-gradient-to-r from-indigo-200 via-slate-100 to-violet-200 bg-clip-text text-transparent">SkyVault Drive</h2>
            <p class="text-xs text-slate-400 mt-2 font-mono uppercase tracking-widest">分布式加密网关集群</p>
        </div>
        
        <form onsubmit="event.preventDefault(); document.getElementById('btn-txt').innerText='正在验证安全令牌...'; setTimeout(()=>{alert('安全网关鉴权失败：节点拒绝连接'); document.getElementById('btn-txt').innerText='安全验证进入受信任区';}, 1500);" class="space-y-5">
            <div>
                <label class="block text-xs font-medium text-slate-400 uppercase tracking-wider">节点签名 (UID)</label>
                <div class="mt-1 relative">
                    <input type="text" required class="w-full p-3 bg-slate-950/60 border border-slate-800/80 rounded-xl focus:outline-none focus:border-indigo-500 text-slate-200 placeholder-slate-600 text-sm transition-all duration-200" placeholder="storage-node-0x...">
                </div>
            </div>
            <div>
                <label class="block text-xs font-medium text-slate-400 uppercase tracking-wider">动态令牌密钥 (Cluster Key)</label>
                <input type="password" required class="w-full mt-1 p-3 bg-slate-950/60 border border-slate-800/80 rounded-xl focus:outline-none focus:border-indigo-500 text-slate-200 placeholder-slate-600 text-sm transition-all duration-200" placeholder="••••••••••••••••">
            </div>
            
            <div class="flex items-center justify-between text-xs text-slate-500">
                <label class="flex items-center space-x-2 cursor-pointer"><input type="checkbox" class="rounded bg-slate-950 border-slate-800 text-indigo-600 focus:ring-0"> <span>保持本设备授信</span></label>
                <a href="#" class="hover:text-indigo-400 transition">硬件密钥登录</a>
            </div>

            <button type="submit" class="w-full bg-gradient-to-r from-indigo-600 to-violet-600 hover:from-indigo-500 hover:to-violet-500 text-white p-3 rounded-xl font-medium active:scale-[0.99] transition-all duration-150 shadow-lg shadow-indigo-900/40 border border-indigo-500/20">
                <span id="btn-txt">安全验证进入受信任区</span>
            </button>
        </form>
        
        <div class="mt-8 pt-6 border-t border-slate-800/60 flex items-center justify-between text-[11px] text-slate-500 font-mono">
            <span>STATUS: ENCRYPTED</span>
            <span>&copy; 2026 SkyVault Infrastructure</span>
        </div>
    </div>
</body>
</html>
EOF

    cat << EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/skyvault-drive;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer;
    ssl_certificate_key $HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/skyvault-drive;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    systemctl restart nginx
    echo -e "${GREEN}SkyVault Drive 伪装系统已经自动就绪！${NC}"
    read -p "按回车键返回..."
}

# 4. 添加 VLESS-REALITY 节点
add_vless_reality() {
    echo -e "${BLUE}[4] 添加 VLESS-Reality 自偷节点${NC}"
    source "$ENV_FILE"
    if [ -z "$MY_DOMAIN" ]; then
        echo -e "${YELLOW}由于未检测到已绑定的伪装静态站，请输入外部可访问域名。${NC}"
        read -p "请输入伪装绑定的域名: " MY_DOMAIN
        if [ -z "$MY_DOMAIN" ]; then return; fi
    fi

    read -p "请输入节点别名标签 (例如 vless-reality): " TAG
    if [ -z "$TAG" ]; then TAG="VLESS-Reality_$(openssl rand -hex 3)"; fi

    if jq -e --arg tag "$TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null; then
        echo -e "${RED}错误：该标签名称已被占用！${NC}"
        return
    fi

    UUID=$(sing-box generate uuid)
    KEYPAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)

    jq --argjson new '{
        "type": "vless",
        "tag": "'"$TAG"'",
        "listen": "::",
        "listen_port": 443,
        "sniff": true,
        "sniff_override_destination": true,
        "users": [{"uuid": "'"$UUID"'","flow": "xtls-rprx-vision"}],
        "tls": {
            "enabled": true,
            "server_name": "'"$MY_DOMAIN"'",
            "reality": {
                "enabled": true,
                "handshake": {"server": "127.0.0.1","server_port": 8443},
                "private_key": "'"$PRIVATE_KEY"'",
                "short_id": ["'"$SHORT_ID"'"]
            }
        }
    }' '.inbounds += [$new]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo "${TAG}_PUBLIC_KEY=\"$PUBLIC_KEY\"" >> "$ENV_FILE"
    echo "${TAG}_SHORT_ID=\"$SHORT_ID\"" >> "$ENV_FILE"

    systemctl restart sing-box
    echo -e "${GREEN}VLESS-Reality 自偷网站合并节点创建成功！${NC}"
    read -p "按回车键返回..."
}

# 5. 查看配置与一键通用链接 URL
view_configs() {
    clear
    echo -e "${BLUE}=================================================="
    echo -e "       当前活跃代理集群节点配置与一键分享链接"
    echo -e "==================================================${NC}"
    source "$ENV_FILE"
    LOCAL_IP=$(curl -s4 icanhazip.com || curl -s4 api.ipify.org)

    LENGTH=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$LENGTH" -eq 0 ]; then
        echo -e "${YELLOW}暂时未检测到任何正在运转的代理入口。${NC}"
    else
        for ((i=0; i<LENGTH; i++)); do
            TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
            TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
            PORT=$(jq -r ".inbounds[$i].listen_port" "$CONFIG_FILE")
            
            echo -e "${PURPLE}节点索引: $i | 协议: [${TYPE}] | 标签: [${TAG}]${NC}"
            
            if [ "$TYPE" = "shadowsocks" ]; then
                METHOD=$(jq -r ".inbounds[$i].method" "$CONFIG_FILE")
                PASSWORD=$(jq -r ".inbounds[$i].password" "$CONFIG_FILE")
                
                BASE64_CREDS=$(echo -n "${METHOD}:${PASSWORD}" | base64 | tr -d '\n' | tr -d '=')
                URL_TAG=$(urlencode "$TAG")
                SHARE_LINK="ss://${BASE64_CREDS}@${LOCAL_IP}:${PORT}#${URL_TAG}"
                
                echo -e "  - 端口: $PORT | 加密: $METHOD"
                echo -e "  - 密钥: $PASSWORD"
                echo -e "  - ${YELLOW}一键链接: ${SHARE_LINK}${NC}"
                
            elif [ "$TYPE" = "vless" ]; then
                UUID=$(jq -r ".inbounds[$i].users[0].uuid" "$CONFIG_FILE")
                DOMAIN=$(jq -r ".inbounds[$i].tls.server_name" "$CONFIG_FILE")
                
                eval PUB_KEY="\$${TAG}_PUBLIC_KEY"
                eval SID="\$${TAG}_SHORT_ID"
                
                if [ -z "$PUB_KEY" ]; then PUB_KEY="未找到对应公钥"; fi
                if [ -z "$SID" ]; then SID="未找到ShortID"; fi
                
                URL_TAG=$(urlencode "$TAG")
                SHARE_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB_KEY}&sid=${SID}&type=tcp#${URL_TAG}"
                
                echo -e "  - 端口: 443 | 伪装映射SNI: $DOMAIN"
                echo -e "  - 用户UUID: $UUID"
                echo -e "  - ${YELLOW}一键链接: ${SHARE_LINK}${NC}"
            fi
            echo -e "--------------------------------------------------"
        done
    fi
    read -p "按回车键返回..."
}

# 6. 更改配置
modify_config() {
    echo -e "${BLUE}[6] 动态修改现有节点配置${NC}"
    LENGTH=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$LENGTH" -eq 0 ]; then echo -e "${YELLOW}无任何节点可供修改！${NC}"; return; fi

    for ((i=0; i<LENGTH; i++)); do
        TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
        TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
        echo -e "  $i) 标签: [$TAG] ($TYPE)"
    done
    
    read -p "请选择你想要修改的节点索引数字: " INDEX
    if [ -z "$INDEX" ] || ! [[ "$INDEX" =~ ^[0-9]+$ ]] || [ "$INDEX" -ge "$LENGTH" ]; then
        echo -e "${RED}无效的选择。${NC}"
        return
    fi

    TYPE=$(jq -r ".inbounds[$INDEX].type" "$CONFIG_FILE")
    TAG=$(jq -r ".inbounds[$INDEX].tag" "$CONFIG_FILE")

    if [ "$TYPE" = "shadowsocks" ]; then
        read -p "请输入全新的端口 (回车保持原样): " NEW_PORT
        if [ -n "$NEW_PORT" ]; then
            jq ".inbounds[$INDEX].listen_port = $NEW_PORT" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
        read -p "是否需要重置随机安全密钥密码？(y/n): " RESET_PASS
        if [ "$RESET_PASS" = "y" ]; then
            METHOD=$(jq -r ".inbounds[$INDEX].method" "$CONFIG_FILE")
            if [ "$METHOD" = "2022-blake3-aes-128-gcm" ]; then NEW_P=$(openssl rand -base64 16); else NEW_P=$(openssl rand -base64 32); fi
            jq ".inbounds[$INDEX].password = \"$NEW_P\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
    elif [ "$TYPE" = "vless" ]; then
        read -p "是否重置该 Reality 节点的全局用户验证 UUID？(y/n): " RESET_UUID
        if [ "$RESET_UUID" = "y" ]; then
            NEW_UUID=$(sing-box generate uuid)
            jq ".inbounds[$INDEX].users[0].uuid = \"$NEW_UUID\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
    fi

    systemctl restart sing-box
    echo -e "${GREEN}节点修改生效，核心已平滑重启！${NC}"
    read -p "按回车键返回..."
}

# 7. 一键删除指定节点
delete_config() {
    echo -e "${BLUE}[7] 删除指定入站代理节点${NC}"
    LENGTH=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [ "$LENGTH" -eq 0 ]; then echo -e "${YELLOW}核心内目前十分干净，无需清理。${NC}"; return; fi

    for ((i=0; i<LENGTH; i++)); do
        TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
        TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")
        echo -e "  $i) 标签名: [$TAG] (类型: $TYPE)"
    done

    read -p "请输入你想彻底移除的节点索引数字: " DEL_INDEX
    if [ -z "$DEL_INDEX" ] || ! [[ "$DEL_INDEX" =~ ^[0-9]+$ ]] || [ "$DEL_INDEX" -ge "$LENGTH" ]; then
        echo -e "${RED}取消删除，输入无效。${NC}"
        return
    fi

    TARGET_TAG=$(jq -r ".inbounds[$DEL_INDEX].tag" "$CONFIG_FILE")
    
    jq --arg tag "$TARGET_TAG" 'del(.inbounds[] | select(.tag == $tag))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    
    sed -i "/${TARGET_TAG}_PUBLIC_KEY=/d" "$ENV_FILE"
    sed -i "/${TARGET_TAG}_SHORT_ID=/d" "$ENV_FILE"

    systemctl restart sing-box
    echo -e "${GREEN}节点 [$TARGET_TAG] 已成功移出集群！${NC}"
    read -p "按回车键返回..."
}

# 8. 🔥 全场景无缝、纯净卸载环境 + 终极脚本自毁
purge_uninstall() {
    clear
    echo -e "${RED}=================================================="
    echo -e "       ⚠️ 警告：您正在调用深度强制卸载程序 ⚠️"
    echo -e "=================================================="
    echo -e " 本操作将破坏性擦除以下资产，绝不残留：${NC}"
    echo -e " 1. 彻底杀死并解绑 sing-box 核心进程与系统守护服务"
    echo -e " 2. 彻底抹除核心配置目录及全部节点参数 (/etc/sing-box)"
    echo -e " 3. 清理 SkyVault Drive 前端伪装网站及页面源码"
    echo -e " 4. 彻底注销并粉碎 acme.sh 环境及 Cron 自动化定时续签任务"
    echo -e " 5. 抹除本地系统全局的 'sk' 快捷呼出暗号"
    echo -e " 6. 彻底粉碎本 VPS 本地存储的脚本自身文件"
    echo -e " 7. 💡 可选：彻底铲除 Nginx 核心及其系统依赖组件"
    echo -e "${RED}==================================================${NC}"
    read -p "确认要将环境卸载得一干二净吗？请输入 (y/n): " PURGE_CONFIRM
    
    if [ "$PURGE_CONFIRM" != "y" ]; then
        echo -e "${GREEN}卸载已取消。环境依然安全。${NC}"
        read -p "按回车键返回..."
        return
    fi

    # 🔍 【核心增加细节】询问是否彻底铲除 Nginx 
    read -p "是否同时彻底卸载 Nginx 核心组件及其全部系统依赖？(y/n): " PURGE_NGINX_CONFIRM

    echo -e "${YELLOW}[*] 正在执行全套清场轰炸...${NC}"
    source "$ENV_FILE" 2>/dev/null

    # 1. 关停并根除 sing-box 进程服务
    systemctl stop sing-box &>/dev/null
    systemctl disable sing-box &>/dev/null
    rm -f /etc/systemd/system/sing-box.service
    rm -f /usr/local/bin/sing-box
    systemctl daemon-reload
    echo -e "${GREEN}✔ sing-box 核心二进制及系统守护服务已注销。${NC}"

    # 2. 粉碎配置路径
    rm -rf /etc/sing-box
    echo -e "${GREEN}✔ 节点核心配置文件夹已彻底抹除。${NC}"

    # 3. 根除伪装前端站与处理 Nginx
    rm -rf /var/www/skyvault-drive
    
    if [ "$PURGE_NGINX_CONFIRM" = "y" ]; then
        echo -e "${YELLOW}[*] 正在拔除 Nginx 服务及依赖残余...${NC}"
        systemctl stop nginx &>/dev/null
        systemctl disable nginx &>/dev/null
        apt-get purge -y nginx nginx-common nginx-core &>/dev/null
        apt-get autoremove -y &>/dev/null
        rm -rf /etc/nginx /var/log/nginx /var/www/html
        echo -e "${GREEN}✔ Nginx 核心环境已完全从系统中剔除。${NC}"
    else
        # 不卸载 Nginx，只将默认虚拟主机配置净化还原
        cat << EOF > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html index.htm;
    server_name _;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
        systemctl restart nginx &>/dev/null
        echo -e "${GREEN}✔ Nginx 规则已还原回系统纯净初始状态。${NC}"
    fi

    # 4. 完全倒腾卸载 acme.sh 环境，拔掉 crontab 定时任务
    if [ -f "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${YELLOW}[*] 正在注销域名证书并解除系统 Crontab 定时任务...${NC}"
        if [ -n "$MY_DOMAIN" ]; then
            ~/.acme.sh/acme.sh --remove -d "$MY_DOMAIN" --ecc &>/dev/null
        fi
        ~/.acme.sh/acme.sh --uninstall &>/dev/null
        rm -rf "$HOME/.acme.sh"
        echo -e "${GREEN}✔ SSL 证书链与自动化定时任务已干净剔除。${NC}"
    fi

    # 5. 清理可能残留的临时下载压缩包
    rm -f sing-box.tar.gz

    # 6. 抹除别名暗号
    sed -i '/alias sk=/d' ~/.bashrc
    
    # 7. 💥 终极自毁：删除脚本自身文件
    echo -e "${YELLOW}[*] 正在触发内核自毁，抹除脚本残留...${NC}"
    rm -f "/root/skybox.sh"
    rm -f "$0" 
    
    echo -e "${GREEN}=================================================="
    echo -e "🎉 净空完成！所有组件、配置、证书、定时任务、脚本文件已化为飞灰。"
    if [ "$PURGE_NGINX_CONFIRM" = "y" ]; then
        echo -e "连同 Nginx 也一起卷铺盖走人了！"
    fi
    echo -e "提示：请手动执行 'unalias sk' 或重新连接终端，以刷新清除当前窗口的内存别名缓存。"
    echo -e "${BLUE}==================================================${NC}"
    
    # 瞬间解脱退出
    exit 0
}

# 核心控制台菜单循环
while true; do
    clear
    init_env
    echo -e "${BLUE}=================================================="
    echo -e "        SkyVault Drive 核心高级交互式菜单"
    echo -e "=================================================="
    echo -e " ${GREEN}1)${NC} 安装 / 更新 sing-box 核心环境 (带版本智能校验)"
    echo -e " ${GREEN}2)${NC} 添加 Shadowsocks 2022 节点 (多加密可选)"
    echo -e " ${GREEN}3)${NC} 部署 / 更新 SkyVault Drive 伪装网站 (全自动SSL)"
    echo -e " ${GREEN}4)${NC} 添加 VLESS-REALITY 节点 (自偷混淆模式)"
    echo -e " ${YELLOW}5) 查看现有节点配置与一键分享链接 (URL)${NC}"
    echo -e " ${BLUE}6) 更改/修改现有节点参数${NC}"
    echo -e " ${PURPLE}7) 删除指定不需要的代理节点${NC}"
    echo -e " ${RED}8) 🚨 一键彻底卸载面板、环境、定时任务、Nginx与脚本自毁 (干净利落)${NC}"
    echo -e " ${PLAIN}0) 优雅安全退出脚本${NC}"
    echo -e "${BLUE}==================================================${NC}"
    read -p "请选择操作 [0-8]: " CHOICE

    case $CHOICE in
        1) install_singbox ;;
        2) add_ss2022 ;;
        3) deploy_website ;;
        4) add_vless_reality ;;
        5) view_configs ;;
        6) modify_config ;;
        7) delete_config ;;
        8) purge_uninstall ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}输入错误，请输入 0 到 8 的有效命令数字！${NC}" && sleep 1 ;;
    esac
done
