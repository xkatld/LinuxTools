#!/bin/bash

# 设置基础备份目录
BASE_BACKUP_DIR="/root/network_backup"
DATE=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)

# 设置本次备份的主目录
BACKUP_DIR="$BASE_BACKUP_DIR/${DATE}_${HOSTNAME}"

# 初始化日志
init_logging() {
    mkdir -p "$BACKUP_DIR"
    exec 3>&1 4>&2
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1> >(tee -a "$BACKUP_DIR/backup.log") 2>&1
}

# 创建日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 写入描述信息到README文件
write_readme() {
    local section=$1
    local description=$2
    local target_dir=$3
    
    mkdir -p "$target_dir"
    echo "# $section 备份信息" > "$target_dir/README.md"
    echo "备份时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$target_dir/README.md"
    echo "主机名: $HOSTNAME" >> "$target_dir/README.md"
    echo "系统类型: $OS_TYPE" >> "$target_dir/README.md"
    echo "网络管理器: $NETWORK_MANAGER" >> "$target_dir/README.md"
    echo -e "\n## 目录内容说明" >> "$target_dir/README.md"
    echo "$description" >> "$target_dir/README.md"
}

# 创建备份目录结构
create_backup_structure() {
    # 创建主目录结构
    mkdir -p "$BACKUP_DIR"/{network,system,firewall}
    
    # 创建子目录
    mkdir -p "$BACKUP_DIR/network/"{interfaces,dns,routes}
    mkdir -p "$BACKUP_DIR/system/"{sysctl,network-scripts}
    mkdir -p "$BACKUP_DIR/firewall/"{ipv4,ipv6}
    
    # 创建总体说明文件
    cat > "$BACKUP_DIR/README.md" << EOF
# 网络配置备份概览
备份时间: $(date '+%Y-%m-%d %H:%M:%S')
主机名: $HOSTNAME
系统类型: $OS_TYPE
网络管理器: $NETWORK_MANAGER

## 目录结构说明
- network/: 网络接口、DNS和路由配置
- system/: 系统级网络配置和参数
- firewall/: 防火墙规则和NAT设置

## 备份内容摘要
本备份包含完整的网络配置信息，详细内容请查看各子目录下的README.md文件。
EOF

    log "创建备份目录结构完成"
}

# 检测系统类型
detect_os() {
    if [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

# 检测网络管理器，改进错误处理
detect_network_manager() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active NetworkManager >/dev/null 2>&1; then
            echo "NetworkManager"
        elif systemctl is-active network >/dev/null 2>&1; then
            echo "network"
        else
            echo "unknown"
        fi
    else
        if service network status >/dev/null 2>&1; then
            echo "network"
        else
            echo "unknown"
        fi
    fi
}

# 备份NetworkManager配置
backup_networkmanager() {
    if [ "$NETWORK_MANAGER" != "NetworkManager" ]; then
        return
    fi
    
    local network_dir="$BACKUP_DIR/network"
    mkdir -p "$network_dir/interfaces/networkmanager"
    
    # 复制NetworkManager配置
    if [ -d "/etc/NetworkManager" ]; then
        cp -r /etc/NetworkManager/* "$network_dir/interfaces/networkmanager/" 2>/dev/null || true
    fi
    
    # 只在NetworkManager运行时尝试获取连接信息
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        nmcli connection show > "$network_dir/interfaces/active_connections.txt" 2>/dev/null || true
    fi
    
    write_readme "网络接口配置" "
- networkmanager/: NetworkManager配置文件
- active_connections.txt: 当前活动的网络连接列表" "$network_dir/interfaces"
    
    log "NetworkManager配置备份完成"
}

# 备份基础网络配置
backup_basic_network() {
    local network_dir="$BACKUP_DIR/network"
    
    # DNS配置
    mkdir -p "$network_dir/dns"
    cp /etc/resolv.conf "$network_dir/dns/" 2>/dev/null || true
    cp /etc/hosts "$network_dir/dns/" 2>/dev/null || true
    
    # 路由配置
    mkdir -p "$network_dir/routes"
    ip route show > "$network_dir/routes/ip_route.txt" 2>/dev/null || true
    ip -6 route show > "$network_dir/routes/ip6_route.txt" 2>/dev/null || true
    
    # 接口配置
    mkdir -p "$network_dir/interfaces"
    ip addr show > "$network_dir/interfaces/ip_addr.txt" 2>/dev/null || true
    
    # CentOS特定配置
    if [ "$OS_TYPE" = "centos" ]; then
        mkdir -p "$network_dir/interfaces/network-scripts"
        cp -r /etc/sysconfig/network-scripts/ifcfg-* "$network_dir/interfaces/network-scripts/" 2>/dev/null || true
    fi
    
    write_readme "DNS配置" "
- resolv.conf: DNS解析器配置
- hosts: 主机名解析配置" "$network_dir/dns"
    
    write_readme "路由配置" "
- ip_route.txt: IPv4路由表
- ip6_route.txt: IPv6路由表" "$network_dir/routes"
    
    log "基础网络配置备份完成"
}

# 备份系统参数配置
backup_sysctl() {
    local sysctl_dir="$BACKUP_DIR/system/sysctl"
    mkdir -p "$sysctl_dir/sysctl.d"
    
    # 备份sysctl配置
    cp /etc/sysctl.conf "$sysctl_dir/" 2>/dev/null || true
    cp -r /etc/sysctl.d/* "$sysctl_dir/sysctl.d/" 2>/dev/null || true
    sysctl -a > "$sysctl_dir/current_settings.txt" 2>/dev/null || true
    
    write_readme "系统参数配置" "
- sysctl.conf: 主系统参数配置文件
- sysctl.d/: 补充系统参数配置
- current_settings.txt: 当前生效的所有系统参数" "$sysctl_dir"
    
    log "系统参数配置备份完成"
}

# 备份防火墙规则
backup_firewall() {
    local fw_dir="$BACKUP_DIR/firewall"
    mkdir -p "$fw_dir/"{ipv4,ipv6}
    
    # IPv4规则
    if command -v iptables >/dev/null 2>&1; then
        iptables-save > "$fw_dir/ipv4/iptables_rules.txt" 2>/dev/null || true
        iptables -t nat -S > "$fw_dir/ipv4/nat_rules.txt" 2>/dev/null || true
    fi
    
    # IPv6规则
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables-save > "$fw_dir/ipv6/ip6tables_rules.txt" 2>/dev/null || true
        ip6tables -t nat -S > "$fw_dir/ipv6/nat_rules.txt" 2>/dev/null || true
    fi
    
    write_readme "防火墙规则" "
- ipv4/: IPv4防火墙规则和NAT配置
- ipv6/: IPv6防火墙规则和NAT配置
详细信息：
- *tables_rules.txt: 完整防火墙规则备份
- nat_rules.txt: NAT规则配置" "$fw_dir"
    
    log "防火墙规则备份完成"
}

# 主函数
main() {
    # 检测系统环境
    OS_TYPE=$(detect_os)
    NETWORK_MANAGER=$(detect_network_manager)
    
    # 初始化日志系统
    init_logging
    
    log "开始网络配置备份"
    log "系统类型: $OS_TYPE"
    log "网络管理器: $NETWORK_MANAGER"
    
    # 创建目录结构
    create_backup_structure
    
    # 执行各模块备份
    backup_basic_network
    backup_networkmanager
    backup_sysctl
    backup_firewall
    
    # 创建备份压缩包
    cd "$BASE_BACKUP_DIR" || exit 1
    tar -czf "${DATE}_${HOSTNAME}_network_backup.tar.gz" "${DATE}_${HOSTNAME}"
    
    log "网络配置备份完成"
    log "备份文件已保存到: $BASE_BACKUP_DIR/${DATE}_${HOSTNAME}_network_backup.tar.gz"
}

# 执行主函数
main
