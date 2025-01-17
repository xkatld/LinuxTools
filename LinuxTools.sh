#!/bin/bash

download_script() {
    local url="$1"
    local script_content=$(curl -s "$url")
    
    if [ -z "$script_content" ]; then
        echo "错误：无法从 $url 下载脚本"
        return 1
    fi
    
    echo "$script_content"
}

execute_github_script() {
    local url="$1"
    local script_content=$(download_script "$url")
    
    if [ $? -eq 0 ]; then
        # 创建临时脚本文件
        local temp_script=$(mktemp)
        echo "$script_content" > "$temp_script"
        
        # 使脚本可执行
        chmod +x "$temp_script"
        
        # 执行脚本
        bash "$temp_script"
        
        # 清理临时文件
        rm "$temp_script"
    else
        echo "脚本执行失败"
    fi
}

# 主菜单函数
main_menu() {
    clear
    echo "LinuxTools脚本菜单 作者:xkatld"
    echo "------------------"
    echo "1. 执行安装LXD"
    echo "2. 执行管理Swap"
    echo "3. 执行管理SSH"
    echo "5. 执行安装Docker"
    echo "6. 执行换安装源"
    echo "6. 执行换网络配置备份"
    echo "0. 退出"
    echo "------------------"
    read -p "请输入您的选择 (0-6)：" choice
}

# 主程序逻辑
while true
do
    main_menu

    case $choice in
        1)
            echo "正在执行来自LinuxTools的LXDInstall..."
            execute_github_script "https://www.ghproxy.cn/https://raw.githubusercontent.com/xkatld/linuxtools/refs/heads/main/LXDInstall.sh"
            read -p "按任意键返回主菜单..." 
            ;;
        2)
            echo "正在执行来自LinuxTools的LinuxSWAP..."
            execute_github_script "https://www.ghproxy.cn/https://raw.githubusercontent.com/xkatld/linuxtools/refs/heads/main/LinuxSWAP.sh"
            read -p "按任意键返回主菜单..." 
            ;;
        3)
            echo "正在执行来自LinuxTools的LinuxSSH..."
            execute_github_script "https://www.ghproxy.cn/https://raw.githubusercontent.com/xkatld/LinuxTools/refs/heads/main/LinuxSSH.sh"
            read -p "按任意键返回主菜单..." 
            ;;
        5)
            echo "正在执行来自linuxmirrors的docker..."
            execute_github_script "https://linuxmirrors.cn/docker.sh"
            read -p "按任意键返回主菜单..." 
            ;;
        6)
            echo "正在执行来自linuxmirrors的main..."
            execute_github_script "https://linuxmirrors.cn/main.sh"
            read -p "按任意键返回主菜单..." 
            ;;
        7)
            echo "正在执行来自LinuxTools的网络备份脚本..."
            execute_github_script "https://www.ghproxy.cn/https://raw.githubusercontent.com/xkatld/LinuxTools/refs/heads/main/network-backup.sh"
            read -p "按任意键返回主菜单..." 
            ;;
        0)
            echo "退出LinuxTools脚本菜单。再见！"
            exit 0
            ;;
        *)
            echo "无效的选择，请重新输入。"
            sleep 2
            ;;
    esac
done
