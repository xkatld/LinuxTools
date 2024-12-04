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

# 禁用镜像自动更新
echo "正在禁用镜像自动更新..."
lxc config set core.images_auto_update_interval 0
