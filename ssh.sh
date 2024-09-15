#!/bin/bash

# 提示用户输入自定义密码
read -p "请输入新的root密码: " CUSTOM_PASSWORD
echo

# 提示用户输入自定义端口
read -p "请输入新的SSH端口（例如：2222）: " CUSTOM_PORT
echo

# 设置root密码
echo "root:$CUSTOM_PASSWORD" | sudo chpasswd

# 修改SSH配置文件以允许root登录并使用密码认证
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config

# 设置自定义SSH端口
sudo sed -i "s/^#\?Port.*/Port $CUSTOM_PORT/g" /etc/ssh/sshd_config

# 重启SSH服务以应用更改
sudo service sshd restart

echo "Root密码和SSH端口已成功设置。"