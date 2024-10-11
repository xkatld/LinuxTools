#!/bin/bash

FRP_URL="https://github.com/fatedier/frp/releases/download/v0.60.0/frp_0.60.0_linux_amd64.tar.gz"
FRP_DIR="/usr/local/frp"
DEFAULT_PASSWORD="SHABHmnXgcxuIZfcZEjg"

install_frps() {
    echo "=== 安装 frp 服务端 ==="

    echo "正在下载 frp..."
    wget -O /tmp/frp.tar.gz "$FRP_URL"

    echo "正在解压 frp..."
    mkdir -p "$FRP_DIR"
    tar -xzf /tmp/frp.tar.gz -C "$FRP_DIR" --strip-components=1

    echo "正在创建 frps.ini 配置文件..."
    cat <<EOL > "/etc/frps.ini"
[common]
bind_port = 510
token = $DEFAULT_PASSWORD

vhost_http_port = 80
vhost_https_port = 443
EOL

    echo "正在创建 frps.service 文件..."
    cat <<EOL > "/etc/systemd/system/frps.service"
[Unit]
Description=Frp 服务端
After=network.target

[Service]
ExecStart=$FRP_DIR/frps -c /etc/frps.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOL

    echo "正在设置 frps 服务开机自启..."
    systemctl daemon-reload
    systemctl enable frps.service

    echo "正在启动 frps 服务..."
    systemctl start frps.service

    echo "=== frp 服务端安装和配置完成 ==="
    systemctl status frps.service
}

install_frpc() {
    echo "=== 安装 frp 客户端 ==="

    read -p "请输入服务端的 IP 地址: " SERVER_IP
    read -p "请输入要映射的开放端口范围（例如：520-52000）: " PORT_RANGE
    read -p "是否需要映射 HTTP 端口（80）? (y/n): " MAP_HTTP
    read -p "是否需要映射 HTTPS 端口（443）? (y/n): " MAP_HTTPS

    echo "正在下载 frp..."
    wget -O /tmp/frp.tar.gz "$FRP_URL"

    echo "正在解压 frp..."
    mkdir -p "$FRP_DIR"
    tar -xzf /tmp/frp.tar.gz -C "$FRP_DIR" --strip-components=1

    echo "正在创建 frpc.ini 配置文件..."
    cat <<EOL > "/etc/frpc.ini"
[common]
server = $SERVER_IP
server_port = 510
token = $DEFAULT_PASSWORD

[range:test_tcp]
type = tcp
local_ip = 127.0.0.1
local_port = $PORT_RANGE
remote_port = $PORT_RANGE

[range:test_udp]
type = udp
local_ip = 127.0.0.1
local_port = $PORT_RANGE
remote_port = $PORT_RANGE
EOL

    if [[ "$MAP_HTTP" == "y" ]]; then
        echo "正在添加 HTTP 端口映射..."
        cat <<EOL >> "/etc/frpc.ini"
[http]
type = tcp
local_ip = 127.0.0.1
local_port = 80
remote_port = 80
EOL
    fi

    if [[ "$MAP_HTTPS" == "y" ]]; then
        echo "正在添加 HTTPS 端口映射..."
        cat <<EOL >> "/etc/frpc.ini"
[https]
type = tcp
local_ip = 127.0.0.1
local_port = 443
remote_port = 443
EOL
    fi

    echo "正在创建 frpc.service 文件..."
    cat <<EOL > "/etc/systemd/system/frpc.service"
[Unit]
Description=Frp 客户端
After=network.target

[Service]
ExecStart=$FRP_DIR/frpc -c /etc/frpc.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOL

    echo "正在设置 frpc 服务开机自启..."
    systemctl daemon-reload
    systemctl enable frpc.service

    echo "正在启动 frpc 服务..."
    systemctl start frpc.service

    echo "=== frp 客户端安装和配置完成 ==="
    systemctl status frpc.service
}

uninstall_frp() {
    echo "=== 卸载 frp ==="
    systemctl stop frps.service
    systemctl stop frpc.service
    systemctl disable frps.service
    systemctl disable frpc.service
    rm -rf "$FRP_DIR"
    rm -f "/etc/frps.ini"
    rm -f "/etc/frpc.ini"
    rm -f "/etc/systemd/system/frps.service"
    rm -f "/etc/systemd/system/frpc.service"
    systemctl daemon-reload
    echo "=== frp 卸载完成 ==="
}

echo "=== frp 安装与配置脚本 ==="
read -p "请选择设置类型 (1: 安装服务端, 2: 安装客户端, 3: 卸载 frp): " CHOICE

if [ "$CHOICE" -eq 1 ]; then
    install_frps
elif [ "$CHOICE" -eq 2 ]; then
    install_frpc
elif [ "$CHOICE" -eq 3 ]; then
    uninstall_frp
else
    echo "无效的选择，请选择 1、2 或 3。"
fi
