#!/bin/bash

set -euo pipefail

readonly SWAP_FILE_PATH="/swapfile"
readonly SYSCTL_FILE="/etc/sysctl.d/99-swap-tuning.conf"

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "需要 root 权限"
        exit 1
    fi
}

show_memory_status() {
    echo ""
    echo "=== 内存状态 ==="
    free -h
    echo ""
}

show_zram_status() {
    echo "=== ZRAM 状态 ==="
    if command -v zramctl &>/dev/null && [[ -b /dev/zram0 ]]; then
        zramctl --output-all
    else
        echo "无 ZRAM 设备"
    fi
    echo ""
}

show_swap_status() {
    echo "=== Swap 状态 ==="
    swapon --summary 2>/dev/null || echo "无活动 Swap"
    echo ""
}

apply_aggressive_settings() {
    log_info "应用激进内存策略..."
    cat > "$SYSCTL_FILE" << 'EOF'
vm.swappiness = 200
vm.vfs_cache_pressure = 500
vm.page-cluster = 0
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
    log_ok "swappiness=200, vfs_cache_pressure=500, page-cluster=0"
}

remove_aggressive_settings() {
    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        sysctl --system >/dev/null 2>&1
        log_info "已清理内核参数"
    fi
}

zram_create() {
    echo ""
    echo "=> 创建 ZRAM"
    echo ""
    show_memory_status

    local mem_mb
    mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    log_info "物理内存: ${mem_mb}MB"
    echo ""

    local zram_size
    read -p "ZRAM 大小 (MB): " -r zram_size
    if [[ ! "$zram_size" =~ ^[1-9][0-9]*$ ]]; then
        log_error "无效数字"
        return 1
    fi

    echo ""
    echo "压缩算法:"
    echo "  1) lz4"
    echo "  2) zstd"
    echo "  3) lzo"
    local algo_choice zram_algo
    read -p "选择 [1-3]: " -r algo_choice
    case "$algo_choice" in
        1) zram_algo="lz4" ;;
        2) zram_algo="zstd" ;;
        3) zram_algo="lzo" ;;
        *) zram_algo="lz4" ;;
    esac

    log_info "清理现有 ZRAM..."
    systemctl stop zramswap.service 2>/dev/null || true
    systemctl disable zramswap.service 2>/dev/null || true
    for zdev in /dev/zram*; do
        [[ -b "$zdev" ]] || continue
        swapoff "$zdev" 2>/dev/null || true
        zramctl --reset "$zdev" 2>/dev/null || true
    done
    rmmod zram 2>/dev/null || true
    sleep 1

    log_info "创建 ${zram_size}MB ZRAM..."
    modprobe zram num_devices=1
    local zram_dev
    zram_dev=$(zramctl --find --size "${zram_size}M" --algorithm "${zram_algo}")
    if [[ -z "$zram_dev" ]]; then
        log_error "创建失败"
        return 1
    fi

    mkswap "$zram_dev"
    swapon -p 32767 "$zram_dev"

    log_info "写入开机配置..."
    apt-get install -y zram-tools >/dev/null 2>&1 || true
    systemctl daemon-reload
    local config_file="/etc/default/zramswap"
    cat > "$config_file" << EOF
ALGO=${zram_algo}
PERCENT=$((zram_size * 100 / mem_mb))
PRIORITY=32767
EOF
    systemctl enable zramswap.service 2>/dev/null || true

    apply_aggressive_settings
    log_ok "ZRAM 已创建: ${zram_dev} ${zram_size}MB ${zram_algo}"
}

zram_remove() {
    echo ""
    echo "=> 删除 ZRAM"
    echo ""
    show_zram_status

    read -p "确认删除? [y/N]: " -r confirm
    if [[ ! "${confirm:-N}" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi

    log_info "停止服务..."
    systemctl stop zramswap.service 2>/dev/null || true
    systemctl disable zramswap.service 2>/dev/null || true

    log_info "关闭 ZRAM swap..."
    for zdev in /dev/zram*; do
        [[ -b "$zdev" ]] || continue
        swapoff "$zdev" 2>/dev/null || true
        zramctl --reset "$zdev" 2>/dev/null || true
    done

    log_info "卸载模块..."
    rmmod zram 2>/dev/null || true

    log_info "卸载 zram-tools..."
    apt-get purge -y zram-tools 2>/dev/null || true
    rm -f /etc/default/zramswap

    remove_aggressive_settings
    log_ok "ZRAM 已删除"
}

zram_test() {
    echo ""
    echo "=> ZRAM 压力测试"
    echo ""
    show_memory_status
    show_zram_status

    local target_gb workers
    read -p "目标内存 (GB): " -r target_gb
    read -p "进程数: " -r workers

    if [[ ! "$target_gb" =~ ^[1-9][0-9]*$ ]] || [[ ! "$workers" =~ ^[1-9][0-9]*$ ]]; then
        log_error "无效输入"
        return 1
    fi

    local per_worker_mb=$(( target_gb * 1024 / workers ))
    log_info "启动 ${workers} 个进程, 每个 ${per_worker_mb}MB"
    echo ""

    cleanup_test() {
        pkill -f "zram-test-worker" 2>/dev/null || true
    }
    trap cleanup_test EXIT

    for i in $(seq 1 "$workers"); do
        log_info "启动 Worker $i/${workers}..."
        python3 -c "
import sys, random
size_mb = int(sys.argv[1])
data = bytearray(size_mb * 1024 * 1024)
for i in range(0, len(data), 4096):
    data[i:i+100] = bytes([random.randint(0,255) for _ in range(100)])
print(f'Worker $i: {size_mb}MB 已分配')
sys.stdout.flush()
input()
" "$per_worker_mb" &
        sleep 2

        if (( i % 2 == 0 )); then
            echo ""
            zramctl --output NAME,DISKSIZE,DATA,COMPR,COMP-RATIO 2>/dev/null || true
            free -h | grep -E "Mem|Swap"
            echo ""
        fi
    done

    echo ""
    log_ok "全部启动完成"
    echo ""
    show_memory_status
    show_zram_status

    local zram_data zram_compr
    zram_data=$(zramctl -b 2>/dev/null | awk '/zram/{sum+=$4} END{print int(sum/1024/1024)}')
    zram_compr=$(zramctl -b 2>/dev/null | awk '/zram/{sum+=$5} END{print int(sum/1024/1024)}')
    zram_data=${zram_data:-0}
    zram_compr=${zram_compr:-0}

    echo "=== 测试结果 ==="
    echo "ZRAM 数据: ${zram_data}MB"
    echo "压缩后: ${zram_compr}MB"
    if [[ $zram_compr -gt 0 ]]; then
        local ratio
        ratio=$(echo "scale=2; $zram_data / $zram_compr" | bc)
        echo "压缩率: ${ratio}:1"
    fi
    echo ""

    read -p "按回车结束测试..." -r
    cleanup_test
    trap - EXIT
    log_ok "测试完成"
}

zram_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        echo "========================================"
        echo "  ZRAM 管理"
        echo "========================================"
        show_zram_status
        echo "  1) 创建 ZRAM"
        echo "  2) 删除 ZRAM"
        echo "  3) 压力测试"
        echo "  0) 返回"
        echo "========================================"
        read -p "选择 [0-3]: " -r choice

        case "$choice" in
            1) zram_create ;;
            2) zram_remove ;;
            3) zram_test ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

swap_create() {
    echo ""
    echo "=> 创建 Swap 文件"
    echo ""
    show_memory_status

    if [[ -f "${SWAP_FILE_PATH}" ]]; then
        log_error "Swap 文件已存在"
        return 1
    fi

    local disk_available
    disk_available=$(df -m / | awk 'NR==2{print $4}')
    log_info "磁盘可用: ${disk_available}MB"
    echo ""

    local swap_size
    read -p "Swap 大小 (MB): " -r swap_size
    if [[ ! "$swap_size" =~ ^[1-9][0-9]*$ ]]; then
        log_error "无效数字"
        return 1
    fi

    log_info "创建 ${swap_size}MB Swap..."
    if ! fallocate -l "${swap_size}M" "${SWAP_FILE_PATH}" 2>/dev/null; then
        log_warn "fallocate 失败, 使用 dd..."
        dd if=/dev/zero of="${SWAP_FILE_PATH}" bs=1M count="${swap_size}" status=progress
    fi

    chmod 600 "${SWAP_FILE_PATH}"
    mkswap "${SWAP_FILE_PATH}"
    swapon "${SWAP_FILE_PATH}"

    if ! grep -q "${SWAP_FILE_PATH}" /etc/fstab; then
        echo "${SWAP_FILE_PATH} none swap sw 0 0" >> /etc/fstab
    fi

    apply_aggressive_settings
    log_ok "Swap 已创建: ${SWAP_FILE_PATH} ${swap_size}MB"
}

swap_remove() {
    echo ""
    echo "=> 删除 Swap 文件"
    echo ""
    show_swap_status

    if [[ ! -f "${SWAP_FILE_PATH}" ]]; then
        log_error "Swap 文件不存在"
        return 1
    fi

    read -p "确认删除? [y/N]: " -r confirm
    if [[ ! "${confirm:-N}" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi

    log_info "关闭 Swap..."
    swapoff "${SWAP_FILE_PATH}" 2>/dev/null || true

    log_info "删除文件..."
    rm -f "${SWAP_FILE_PATH}"

    log_info "清理 fstab..."
    grep -v "${SWAP_FILE_PATH}" /etc/fstab > /etc/fstab.tmp
    mv /etc/fstab.tmp /etc/fstab

    remove_aggressive_settings
    log_ok "Swap 已删除"
}

swap_test() {
    echo ""
    echo "=> Swap 压力测试"
    echo ""
    show_memory_status
    show_swap_status

    local target_gb workers
    read -p "目标内存 (GB): " -r target_gb
    read -p "进程数: " -r workers

    if [[ ! "$target_gb" =~ ^[1-9][0-9]*$ ]] || [[ ! "$workers" =~ ^[1-9][0-9]*$ ]]; then
        log_error "无效输入"
        return 1
    fi

    local per_worker_mb=$(( target_gb * 1024 / workers ))
    log_info "启动 ${workers} 个进程, 每个 ${per_worker_mb}MB"
    echo ""

    cleanup_test() {
        pkill -f "swap-test-worker" 2>/dev/null || true
    }
    trap cleanup_test EXIT

    for i in $(seq 1 "$workers"); do
        log_info "启动 Worker $i/${workers}..."
        python3 -c "
import sys, random
size_mb = int(sys.argv[1])
data = bytearray(size_mb * 1024 * 1024)
for i in range(0, len(data), 4096):
    data[i:i+100] = bytes([random.randint(0,255) for _ in range(100)])
print(f'Worker $i: {size_mb}MB 已分配')
sys.stdout.flush()
input()
" "$per_worker_mb" &
        sleep 2

        if (( i % 2 == 0 )); then
            echo ""
            free -h | grep -E "Mem|Swap"
            echo ""
        fi
    done

    echo ""
    log_ok "全部启动完成"
    echo ""
    show_memory_status
    show_swap_status

    read -p "按回车结束测试..." -r
    cleanup_test
    trap - EXIT
    log_ok "测试完成"
}

swap_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        echo "========================================"
        echo "  Swap 文件管理"
        echo "========================================"
        show_swap_status
        echo "  1) 创建 Swap"
        echo "  2) 删除 Swap"
        echo "  3) 压力测试"
        echo "  0) 返回"
        echo "========================================"
        read -p "选择 [0-3]: " -r choice

        case "$choice" in
            1) swap_create ;;
            2) swap_remove ;;
            3) swap_test ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        echo "========================================"
        echo "  虚拟内存管理"
        echo "========================================"
        show_memory_status
        echo "  1) ZRAM 管理"
        echo "  2) Swap 文件管理"
        echo "  0) 退出"
        echo "========================================"
        read -p "选择 [0-2]: " -r choice

        case "$choice" in
            1) zram_menu ;;
            2) swap_menu ;;
            0) log_info "退出"; exit 0 ;;
            *) log_error "无效选项" ;;
        esac
    done
}

check_root
main_menu
