#!/bin/bash
# 脚本用于开启BBR v3并优化内核网络参数
# 适用于 Debian / Ubuntu / Arch 高版本

# 确保以root身份运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root身份运行" 1>&2
   exit 1
fi

echo "正在检查和启用BBR v3..."

# 更新系统
apt update && apt install curl -y

# 检查当前内核版本
KERNEL_VERSION=$(uname -r)
echo "当前内核版本: $KERNEL_VERSION"

# 检查是否支持BBR v3
if ! cat /proc/sys/net/ipv4/tcp_available_congestion_control | grep -q "bbr3"; then
    echo "当前内核不支持BBR v3，尝试安装更新的内核..."
    
    # 安装backports内核
    curl -s 'https://liquorix.net/install-liquorix.sh' | sudo bash
    
    echo "新内核已安装，需要重启系统才能生效"
    echo "请运行 'reboot' 命令重启系统，然后重新运行此脚本"
    exit 0
fi

# 创建sysctl配置文件
cat > /etc/sysctl.d/99-bbr-v3-network-performance.conf << EOF
# BBR v3配置
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr3

# 文件句柄和inotify设置
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192

# TCP连接重用和端口设置
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# TCP缓冲区设置
net.ipv4.tcp_rmem = 16384 262144 8388608
net.ipv4.tcp_wmem = 32768 524288 16777216

# 连接队列设置
net.core.somaxconn = 8192
net.core.rmem_max = 16777216
net.core.wmem_default = 2097152
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_max_syn_backlog = 10240
net.ipv4.tcp_slow_start_after_idle = 0

# 其他网络性能优化
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
EOF

# 应用sysctl设置
sysctl -p /etc/sysctl.d/99-bbr-v3-network-performance.conf

# 确认BBR v3是否已启用
CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$CURRENT_CC" = "bbr3" ]; then
    echo "BBR v3已成功启用！"
    echo "已应用所有网络性能优化参数"
else
    echo "警告：BBR v3未成功启用，当前使用的拥塞控制算法是: $CURRENT_CC"
    echo "请确认您的内核版本支持BBR v3。目前可用的拥塞控制算法:"
    cat /proc/sys/net/ipv4/tcp_available_congestion_control
    
    # 如果BBR可用但BBR3不可用，则使用BBR
    if cat /proc/sys/net/ipv4/tcp_available_congestion_control | grep -q "bbr"; then
        echo "BBR可用，尝试启用BBR作为替代..."
        echo "net.ipv4.tcp_congestion_control = bbr" > /etc/sysctl.d/99-bbr-network.conf
        sysctl -p /etc/sysctl.d/99-bbr-network.conf
        
        CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
        if [ "$CURRENT_CC" = "bbr" ]; then
            echo "BBR已成功启用作为替代！"
        fi
    fi
fi

echo "脚本执行完成。"
