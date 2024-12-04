#!/bin/bash

# 判断系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法确定系统类型，请手动检查和安装OpenSSH server。"
    exit 1
fi

# 检查并安装sshd
case "$OS" in
    ubuntu|debian)
        if ! dpkg -l | grep -q openssh-server; then
            echo "OpenSSH server未安装，正在安装..."
            sudo apt update
            sudo apt install -y openssh-server
        fi
        ;;
    centos|rhel|fedora)
        if ! rpm -qa | grep -q openssh-server; then
            echo "OpenSSH server未安装，正在安装..."
            sudo yum install -y openssh-server
        fi
        ;;
    *)
        echo "未识别的系统类型，无法自动安装OpenSSH server。请手动安装。"
        exit 1
        ;;
esac

# 提示用户输入自定义密码
read -s -p "请输入新的root密码: " CUSTOM_PASSWORD
echo
read -s -p "请再次输入新的root密码以确认: " CUSTOM_PASSWORD_CONFIRM
echo

# 检查密码是否匹配
if [ "$CUSTOM_PASSWORD" != "$CUSTOM_PASSWORD_CONFIRM" ]; then
    echo "密码不匹配，请重新运行脚本。"
    exit 1
fi

# 提示用户输入自定义端口
read -p "请输入新的SSH端口（例如：22）: " CUSTOM_PORT
echo

# 验证端口是否为数字
if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]]; then
    echo "错误：端口必须是数字。"
    exit 1
fi

# 设置root密码
echo "root:$CUSTOM_PASSWORD" | sudo chpasswd

# 修改SSH配置文件以允许root登录并使用密码认证
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 设置自定义SSH端口
sudo sed -i "s/^#\?Port.*/Port $CUSTOM_PORT/" /etc/ssh/sshd_config

# 重启SSH服务以应用更改
sudo systemctl restart sshd

echo "Root密码和SSH端口已成功设置。请注意，允许root直接登录可能存在安全风险。"
