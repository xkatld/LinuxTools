#!/bin/bash

# 脚本1的实现
script_1() {
    echo "执行脚本1的操作..."
    # 在这里添加脚本1的具体逻辑
    sleep 1
}

# 脚本2的实现
script_2() {
    echo "执行脚本2的操作..."
    # 在这里添加脚本2的具体逻辑
    sleep 1
}

# 脚本3的实现
script_3() {
    echo "执行脚本3的操作..."
    # 在这里添加脚本3的具体逻辑
    sleep 1
}

# 主菜单函数
main_menu() {
    clear
    echo "脚本合集主菜单"
    echo "---------------"
    echo "请选择要执行的脚本:"
    echo "1. 执行脚本1"
    echo "2. 执行脚本2"
    echo "3. 执行脚本3"
    echo "0. 退出"
    echo "---------------"
    read -p "请输入您的选择 (0-3): " choice
}

# 主程序逻辑
while true
do
    main_menu

    case $choice in
        1)
            script_1
            read -p "按任意键返回主菜单..." 
            ;;
        2)
            script_2
            read -p "按任意键返回主菜单..." 
            ;;
        3)
            script_3
            read -p "按任意键返回主菜单..." 
            ;;
        0)
            echo "退出脚本合集。再见！"
            exit 0
            ;;
        *)
            echo "无效的选择，请重新输入。"
            sleep 2
            ;;
    esac
done
