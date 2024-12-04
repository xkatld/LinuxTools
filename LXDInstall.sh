#!/bin/bash

# LXD安装脚本

# 确保以root权限运行脚本
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以root权限运行" 
   exit 1
fi

# 更新软件包列表并安装必要的软件包
echo "正在更新软件包列表并安装必要的软件包..."
apt update
apt install curl wget sudo dos2unix jq -y

# 移除UFW防火墙
echo "正在移除UFW防火墙..."
apt remove ufw -y

# 安装Snapd
echo "正在安装Snapd..."
apt install snapd -y

# 通过Snap安装LXD
echo "正在通过Snap安装LXD..."
snap install lxd

# 提示手动初始化
echo "LXD已安装完成。"
echo "请执行 /snap/bin/lxd init 手动配置LXD初始化参数。"
echo "初始化时建议："
echo "- 手动选择存储后端"
echo "- 配置网络"
echo "- 镜像更新选项选择 'no'"

if ! command -v lxc &>/dev/null; then
    if [ -f /snap/bin/lxc ]; then
        echo 'alias lxc="/snap/bin/lxc"' >> /root/.bashrc
        echo 'export PATH=$PATH:/snap/bin' >> /root/.bashrc
        source /root/.bashrc
        echo "LXC 别名和 PATH 已经设置。"
    else
        echo "未找到 LXC 命令。请先安装 LXD。"
    fi
else
    echo "LXC 命令已经在您的 PATH 中可用。"
fi
