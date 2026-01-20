@ -0,0 +1,110 @@
#!/usr/bin/env bash
# ==========================
# IPv6-only 管理脚本 v1.0.0
# GitHub 一键脚本版本
# Author: Lin
# ==========================

NODE_SERVICE="xray"
NET_IF="eth0"
VERSION="1.0.0"

# 菜单选项
options=("启用 IPv6-only" "恢复 IPv4" "查看状态" "退出")
selected=0

print_menu() {
    clear
    echo -e "\e[1;34m========== IPv6-only 管理脚本 v$VERSION ==========\e[0m"
    for i in "${!options[@]}"; do
        if [ $i -eq $selected ]; then
            echo -e "  \e[1;33m➤ ${options[$i]}\e[0m"
        else
            echo "    ${options[$i]}"
        fi
    done
    echo -e "\e[1;34m==================================================\e[0m"
}

confirm_action() {
    echo -e "\n\e[1;31m⚠️  确认操作吗？(y/N)\e[0m"
    read -rp "> " yn
    case "$yn" in
        [Yy]*) return 0 ;;
        *) echo "[✖] 已取消操作"; read -rp "按回车返回菜单..." tmp; return 1 ;;
    esac
}

enable_ipv6_only() {
    confirm_action || return
    echo -e "\n[*] 启用 IPv6-only..."
    ip -4 route save table main > /tmp/ipv4_route_backup.txt
    ip route flush table main proto static
    ip -4 addr flush dev "$NET_IF"

    iptables-save > /tmp/iptables_backup.txt
    iptables -P OUTPUT DROP
    iptables -A OUTPUT -o lo -j ACCEPT

    systemctl restart "$NODE_SERVICE"
    echo -e "[✔] 已启用 IPv6-only"
    read -rp "按回车返回菜单..." tmp
}

restore_ipv4() {
    confirm_action || return
    echo -e "\n[*] 恢复 IPv4..."
    if [ -f /tmp/ipv4_route_backup.txt ]; then
        ip route flush table main
        while read -r line; do
            ip route add $line
        done < /tmp/ipv4_route_backup.txt
        rm /tmp/ipv4_route_backup.txt
    fi

    if [ -f /tmp/iptables_backup.txt ]; then
        iptables-restore < /tmp/iptables_backup.txt
        rm /tmp/iptables_backup.txt
    fi

    systemctl restart "$NODE_SERVICE"
    echo -e "[✔] 已恢复 IPv4"
    read -rp "按回车返回菜单..." tmp
}

show_status() {
    echo -e "\n================ 当前状态 ================"
    echo "[*] IPv4 路由:"
    ip -4 route show
    echo "[*] iptables 输出策略:"
    iptables -L OUTPUT -v -n
    echo "[*] 节点服务状态:"
    systemctl status "$NODE_SERVICE" --no-pager
    echo "========================================="
    read -rp "按回车返回菜单..." tmp
}

read_key() {
    read -s -n1 key
    if [[ $key == $'\x1b' ]]; then
        read -s -n2 key
    fi
}

# 主循环
while true; do
    print_menu
    read_key
    case $key in
        '[A') ((selected--)); [ $selected -lt 0 ] && selected=$((${#options[@]}-1)) ;;
        '[B') ((selected++)); [ $selected -ge ${#options[@]} ] && selected=0 ;;
        '')
            case $selected in
                0) enable_ipv6_only ;;
                1) restore_ipv4 ;;
                2) show_status ;;
                3) exit 0 ;;
            esac
            ;;
    esac
done
