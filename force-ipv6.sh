#!/usr/bin/env bash
# ==========================
# IPv6-only 管理脚本 v1.2.0 (优化版)
# 原作者: Lin
# 优化改进: 
#   - 权限检查、持久备份、可配置参数、更安全的 iptables 规则、错误处理
#   - 数字菜单选择
#   - 一键部署 sing-box VLESS + Reality 服务器节点（支持更新）
# ==========================

# 默认配置（可通过命令行参数覆盖）
NODE_SERVICE="xray"
NET_IF="eth0"
VERSION="1.2.0"
BACKUP_DIR="/var/backups/ipv6-manager"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --service=*) NODE_SERVICE="${1#*=}" ;;
        --interface=*) NET_IF="${1#*=}" ;;
        -h|--help)
            echo "用法: $0 [--service=<服务名>] [--interface=<接口名>]"
            echo "示例: $0 --service=xray --interface=eth0"
            echo "默认: --service=xray --interface=eth0"
            exit 0
            ;;
        *) echo "[✖] 未知参数: $1" >&2; exit 1 ;;
    esac
    shift
done

# 权限检查
if [[ $EUID -ne 0 ]]; then
    echo "[✖] 请以 root 权限运行此脚本" >&2
    exit 1
fi

# 创建备份目录
mkdir -p "$BACKUP_DIR" || { echo "[✖] 创建备份目录失败: $BACKUP_DIR" >&2; exit 1; }

ROUTE_BACKUP="$BACKUP_DIR/ipv4_route_backup.txt"
IPTABLES_BACKUP="$BACKUP_DIR/iptables_backup.txt"

confirm_action() {
    echo -e "\n\e[1;31mWarning: 确认执行此操作吗？(y/N)\e[0m"
    read -rp "> " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) echo "[✖] 已取消操作"; read -rp "按回车继续..." ; return 1 ;;
    esac
}

print_menu() {
    clear
    echo -e "\e[1;34m========== IPv6-only 管理脚本 v$VERSION ==========\e[0m"
    echo -e "当前服务: $NODE_SERVICE   接口: $NET_IF"
    echo
    echo "1) 启用 IPv6-only"
    echo "2) 恢复 IPv4"
    echo "3) 查看状态"
    echo "4) 部署/更新 sing-box 节点"
    echo "5) 退出"
    echo -e "\e[1;34m==================================================\e[0m"
}

enable_ipv6_only() {
    confirm_action || return

    if ! ip -4 route show default >/dev/null 2>&1; then
        echo "[!] 当前已无 IPv4 默认路由，可能已处于 IPv6-only 状态"
        read -rp "仍要继续？(y/N)" yn
        [[ "$yn" =~ ^[Yy]$ ]] || { echo "[✖] 已取消"; read -rp "按回车返回..." ; return; }
    fi

    if [[ -f "$ROUTE_BACKUP" || -f "$IPTABLES_BACKUP" ]]; then
        echo "[!] 检测到已有备份文件，启用将覆盖它们"
        read -rp "继续？(y/N)" yn
        [[ "$yn" =~ ^[Yy]$ ]] || { echo "[✖] 已取消"; read -rp "按回车返回..." ; return; }
    fi

    echo -e "\n[*] 正在启用 IPv6-only..."

    ip -4 route save table main > "$ROUTE_BACKUP" || { echo "[✖] 备份 IPv4 路由失败"; read -rp "按回车返回..." ; return 1; }
    ip route flush table main proto static || { echo "[✖] 清除路由失败"; read -rp "按回车返回..." ; return 1; }
    ip -4 addr flush dev "$NET_IF" || { echo "[✖] 清除 IPv4 地址失败"; read -rp "按回车返回..." ; return 1; }

    iptables-save > "$IPTABLES_BACKUP" || { echo "[✖] 备份 iptables 失败"; read -rp "按回车返回..." ; return 1; }
    iptables -F OUTPUT
    iptables -P OUTPUT DROP
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -p ipv4 -j DROP || true

    systemctl restart "$NODE_SERVICE" || { echo "[✖] 重启服务 $NODE_SERVICE 失败"; read -rp "按回车返回..." ; return 1; }

    echo -e "[✓] 已成功启用 IPv6-only"
    read -rp "按回车返回菜单..." 
}

restore_ipv4() {
    confirm_action || return

    echo -e "\n[*] 正在恢复 IPv4..."

    local restore_failed=0

    if [[ -f "$ROUTE_BACKUP" ]]; then
        ip route flush table main || { echo "[✖] 清除当前路由失败"; restore_failed=1; }
        while read -r line; do
            ip route add $line || { echo "[✖] 恢复路由行失败: $line"; restore_failed=1; }
        done < "$ROUTE_BACKUP"
        rm -f "$ROUTE_BACKUP"
    else
        echo "[!] 未找到路由备份文件"
    fi

    if [[ -f "$IPTABLES_BACKUP" ]]; then
        iptables-restore < "$IPTABLES_BACKUP" || { echo "[✖] 恢复 iptables 规则失败"; restore_failed=1; }
        rm -f "$IPTABLES_BACKUP"
    else
        echo "[!] 未找到 iptables 备份文件"
    fi

    systemctl restart "$NODE_SERVICE" || { echo "[✖] 重启服务 $NODE_SERVICE 失败"; restore_failed=1; }

    if [[ $restore_failed -eq 0 ]]; then
        echo -e "[✓] 已成功恢复 IPv4"
    else
        echo -e "[✖] 恢复过程出现错误，请手动检查系统状态"
    fi

    read -rp "按回车返回菜单..." 
}

show_status() {
    echo -e "\n================ 当前状态 ================"
    echo "[*] IPv4 路由:"
    ip -4 route show
    echo
    echo "[*] iptables OUTPUT 链:"
    iptables -L OUTPUT -v -n
    echo
    echo "[*] 节点服务状态 ($NODE_SERVICE):"
    systemctl status "$NODE_SERVICE" --no-pager 2>/dev/null || echo "[!] 服务未运行或不存在"
    echo "========================================="
    read -rp "按回车返回菜单..." 
}

deploy_singbox() {
    confirm_action || return

    echo -e "\n[*] 正在部署/更新 sing-box VLESS + Reality 服务器节点..."

    local update_core=0
    if command -v sing-box >/dev/null 2>&1; then
        echo "[!] 检测到 sing-box 已安装"
        read -rp "是否更新核心并重新生成配置？(y/N): " yn
        [[ "$yn" =~ ^[Yy]$ ]] && update_core=1 || echo "[*] 仅重新生成配置（保留当前核心）"
    else
        update_core=1
    fi

    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        riscv64) arch="riscv64" ;;
        *) echo "[✖] 不支持的架构: $(uname -m)"; read -rp "按回车返回..." ; return 1 ;;
    esac

    if [[ $update_core -eq 1 ]]; then
        echo "[*] 获取最新版本..."
        local latest_tag=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/v\1/')
        if [[ -z "$latest_tag" ]]; then
            echo "[✖] 获取版本失败（网络问题？）"
            read -rp "按回车返回..." ; return 1
        fi

        local version=${latest_tag#v}
        local file="sing-box-${version}-linux-${arch}.tar.gz"
        local url="https://github.com/SagerNet/sing-box/releases/download/${latest_tag}/${file}"

        echo "[*] 正在下载 $url ..."
        wget -q --show-progress -O "$file" "$url" || { echo "[✖] 下载失败"; read -rp "按回车返回..." ; return 1; }

        tar -xzf "$file"
        mv "sing-box-${version}-linux-${arch}/sing-box" /usr/local/bin/sing-box || { echo "[✖] 安装失败"; rm -f "$file"; return 1; }
        chmod +x /usr/local/bin/sing-box
        rm -rf "sing-box-${version}-linux-${arch}" "$file"

        echo "[✓] sing-box 核心已更新至 $latest_tag"
    fi

    echo -e "\n[*] 生成配置参数..."
    local uuid=$(/usr/local/bin/sing-box generate uuid)
    local short_id=$(/usr/local/bin/sing-box generate rand --hex 8)
    local keypair=$(/usr/local/bin/sing-box generate reality-keypair)
    local private_key=$(echo "$keypair" | grep '"private_key"' | cut -d '"' -f4)
    local public_key=$(echo "$keypair" | grep '"public_key"' | cut -d '"' -f4)

    read -rp "监听端口 [443]: " port
    port=${port:-443}
    read -rp "Reality 伪装域名 [www.microsoft.com]: " dest_domain
    dest_domain=${dest_domain:-www.microsoft.com}

    echo -e "\n生成参数预览："
    echo "UUID: $uuid"
    echo "Short ID: $short_id"
    echo "Public Key: $public_key"
    echo "端口: $port"
    echo "伪装域名: $dest_domain"

    confirm_action || { echo "[✖] 已取消"; read -rp "按回车返回..." ; return; }

    mkdir -p /etc/sing-box

    cat > /etc/sing-box/config.json <<EOF
{
    "log": {
        "level": "info"
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-in",
            "listen": "::",
            "listen_port": $port,
            "sniff": true,
            "sniff_override_destination": true,
            "users": [
                {
                    "uuid": "$uuid",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "$dest_domain",
                "reality": {
                    "enabled": true,
                    "private_key": "$private_key",
                    "short_ids": [
                        "$short_id"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ]
}
EOF

    echo "[✓] 配置已写入 /etc/sing-box/config.json"

    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box || { echo "[✖] 启动 sing-box 服务失败"; read -rp "按回车返回..." ; return 1; }

    NODE_SERVICE="sing-box"
    echo "[✓] sing-box 服务已启用，当前节点服务已切换为 sing-box"

    echo -e "\n[✓] 部署完成！客户端连接信息（VLESS + Reality）："
    echo "地址: [您的服务器 IPv6 地址]:$port"
    echo "端口: $port"
    echo "UUID: $uuid"
    echo "Flow: xtls-rprx-vision"
    echo "Security: reality"
    echo "Fingerprint: chrome（默认）"
    echo "SNI/ServerName: $dest_domain"
    echo "Public Key: $public_key"
    echo "Short ID: $short_id"
    echo -e "\n请在客户端中配置上述参数即可连接。"

    read -rp "按回车返回菜单..." 
}

# 主循环
while true; do
    print_menu
    read -rp "请选择操作 (1-5): " choice
    case "$choice" in
        1) enable_ipv6_only ;;
        2) restore_ipv4 ;;
        3) show_status ;;
        4) deploy_singbox ;;
        5) echo "退出脚本"; exit 0 ;;
        *) echo "[✖] 无效选择，请输入 1-5"; sleep 1 ;;
    esac
done
