#!/usr/bin/env bash
set -euo pipefail

mirrors_detect_codename() {
    ensure_os_detected
    if [[ -n "${VERSION_CODENAME:-}" ]]; then
        echo "${VERSION_CODENAME}"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -cs
    else
        echo "stable"
    fi
}

mirrors_get_major_version() {
    local version="${1:-${OS_VERSION:-}}"
    echo "${version%%.*}"
}

mirrors_render_main_menu() {
    cat <<'EOF'
1) 系统换源
2) Docker 换源
0) 返回上级菜单
EOF
}

mirrors_render_system_menu() {
    cat <<'EOF'
1) 查看当前系统源
2) Debian/Ubuntu 换源
3) 恢复 Debian/Ubuntu 官方源
4) CentOS/Rocky/AlmaLinux 换源
0) 返回上级菜单
EOF
}

mirrors_render_docker_menu() {
    cat <<'EOF'
1) 使用 1ms 镜像加速
2) 使用 DaoCloud 镜像加速
3) 使用中科大镜像加速
4) 使用腾讯云镜像加速
5) 使用自定义 Docker 镜像地址
6) 清空 Docker 镜像加速
7) 查看当前 Docker 镜像配置
0) 返回上级菜单
EOF
}

mirrors_get_official_base() {
    local distro="$1"
    case "${distro}" in
        ubuntu) echo "https://archive.ubuntu.com" ;;
        debian) echo "https://deb.debian.org" ;;
        rocky) echo "https://dl.rockylinux.org/pub/rocky" ;;
        almalinux) echo "https://repo.almalinux.org/almalinux" ;;
        centos) echo "https://vault.centos.org" ;;
        *) return 1 ;;
    esac
}

mirrors_get_security_base() {
    local distro="$1"
    local profile="${2:-custom}"
    case "${distro}:${profile}" in
        ubuntu:official) echo "https://security.ubuntu.com" ;;
        ubuntu:*) echo "$(mirrors_get_official_base ubuntu)" ;;
        debian:official) echo "https://security.debian.org" ;;
        debian:*) echo "$(mirrors_get_official_base debian)" ;;
        *) return 1 ;;
    esac
}

mirrors_get_system_source_selection() {
    local source_choice="$1"
    case "${source_choice}" in
        1) echo 'https://mirrors.aliyun.com|https://mirrors.aliyun.com|阿里云' ;;
        2) echo 'https://mirrors.tuna.tsinghua.edu.cn|https://mirrors.tuna.tsinghua.edu.cn|清华大学' ;;
        3) echo 'https://mirrors.ustc.edu.cn|https://mirrors.ustc.edu.cn|中国科大' ;;
        4) echo 'https://mirrors.cloud.tencent.com|https://mirrors.cloud.tencent.com|腾讯云' ;;
        5) echo 'https://repo.huaweicloud.com|https://repo.huaweicloud.com|华为云' ;;
        *) return 1 ;;
    esac
}

mirrors_get_docker_mirror_url() {
    local choice="$1"
    case "${choice}" in
        1) echo 'https://docker.1ms.run' ;;
        2) echo 'https://docker.m.daocloud.io' ;;
        3) echo 'https://docker.mirrors.ustc.edu.cn' ;;
        4) echo 'https://mirror.ccs.tencentyun.com' ;;
        *) return 1 ;;
    esac
}

mirrors_get_docker_mirror_name() {
    local choice="$1"
    case "${choice}" in
        1) echo '1ms' ;;
        2) echo 'DaoCloud' ;;
        3) echo '中科大' ;;
        4) echo '腾讯云' ;;
        *) return 1 ;;
    esac
}

mirrors_get_rpm_baseurl() {
    local distro="$1"
    local major_version="$2"
    local repo_name="$3"
    local mirror_base="$4"
    case "${distro}" in
        rocky)
            case "${repo_name}" in
                BaseOS|AppStream|CRB|PowerTools|HighAvailability|NFV)
                    echo "${mirror_base%/}/rockylinux/${major_version}/${repo_name}/\$basearch/os/"
                    ;;
                extras|Extras)
                    echo "${mirror_base%/}/rockylinux/${major_version}/extras/\$basearch/os/"
                    ;;
                *) return 1 ;;
            esac
            ;;
        almalinux)
            case "${repo_name}" in
                BaseOS|AppStream|CRB|PowerTools)
                    echo "${mirror_base%/}/almalinux/${major_version}/${repo_name}/\$basearch/os/"
                    ;;
                extras|Extras)
                    echo "${mirror_base%/}/almalinux/${major_version}/extras/\$basearch/os/"
                    ;;
                *) return 1 ;;
            esac
            ;;
        centos)
            case "${repo_name}" in
                BaseOS) echo "${mirror_base%/}/${major_version}/BaseOS/\$basearch/os/" ;;
                AppStream) echo "${mirror_base%/}/${major_version}/AppStream/\$basearch/os/" ;;
                CRB) echo "${mirror_base%/}/${major_version}/CRB/\$basearch/os/" ;;
                PowerTools) echo "${mirror_base%/}/${major_version}/PowerTools/\$basearch/os/" ;;
                extras|Extras) echo "${mirror_base%/}/${major_version}/extras/\$basearch/os/" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

mirrors_get_rpm_optional_repo_name() {
    local distro="$1"
    local major_version="$2"
    case "${distro}" in
        rocky|almalinux|centos)
            if [[ "${major_version}" -ge 9 ]]; then
                echo "CRB"
            else
                echo "PowerTools"
            fi
            ;;
        *) return 1 ;;
    esac
}

mirrors_get_epel_baseurl() {
    local major_version="$1"
    local mirror_base="$2"
    echo "${mirror_base%/}/epel/${major_version}/Everything/\$basearch/"
}

mirrors_probe_apt_mirror() {
    local mirror_base="$1"
    local distro="$2"
    local codename="$3"
    local url="${mirror_base%/}/${distro}/dists/${codename}/Release"
    curl -fsI --connect-timeout 8 --max-time 15 "${url}" >/dev/null
}

mirrors_probe_url() {
    local url="$1"
    curl -fsI --connect-timeout 8 --max-time 15 "${url}" >/dev/null
}

mirrors_probe_docker_mirror() {
    local mirror_url="$1"
    curl -fsI --connect-timeout 8 --max-time 15 "${mirror_url%/}/v2/" >/dev/null
}

mirrors_write_ubuntu_sources() {
    local mirror_base="$1"
    local security_base="${2:-${mirror_base}}"
    local codename
    codename=$(mirrors_detect_codename)
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        backup_file /etc/apt/sources.list.d/ubuntu.sources
        cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: ${mirror_base}/ubuntu
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${security_base}/ubuntu
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    else
        backup_file /etc/apt/sources.list
        cat > /etc/apt/sources.list <<EOF
deb ${mirror_base}/ubuntu ${codename} main restricted universe multiverse
deb ${mirror_base}/ubuntu ${codename}-updates main restricted universe multiverse
deb ${mirror_base}/ubuntu ${codename}-backports main restricted universe multiverse
deb ${security_base}/ubuntu ${codename}-security main restricted universe multiverse
EOF
    fi
}

mirrors_write_debian_sources() {
    local mirror_base="$1"
    local security_base="$2"
    local codename
    codename=$(mirrors_detect_codename)
    if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
        backup_file /etc/apt/sources.list.d/debian.sources
        cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: ${mirror_base}/debian
Suites: ${codename} ${codename}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${security_base}/debian-security
Suites: ${codename}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    else
        backup_file /etc/apt/sources.list
        cat > /etc/apt/sources.list <<EOF
deb ${mirror_base}/debian ${codename} main contrib non-free non-free-firmware
deb ${mirror_base}/debian ${codename}-updates main contrib non-free non-free-firmware
deb ${security_base}/debian-security ${codename}-security main contrib non-free non-free-firmware
EOF
    fi
}

mirrors_write_rpm_repo_file() {
    local distro="$1"
    local mirror_base="$2"
    local major_version="$3"
    local repo_dir="${4:-/etc/yum.repos.d}"
    local repo_file="${repo_dir}/linux-toolbox-${distro}.repo"
    mkdir -p "${repo_dir}"
    backup_file "${repo_file}"

    local baseos appstream extras optional_repo optional_baseurl
    baseos="$(mirrors_get_rpm_baseurl "${distro}" "${major_version}" "BaseOS" "${mirror_base}")"
    appstream="$(mirrors_get_rpm_baseurl "${distro}" "${major_version}" "AppStream" "${mirror_base}")"
    extras="$(mirrors_get_rpm_baseurl "${distro}" "${major_version}" "extras" "${mirror_base}")"
    optional_repo="$(mirrors_get_rpm_optional_repo_name "${distro}" "${major_version}" 2>/dev/null || true)"
    if [[ -n "${optional_repo}" ]]; then
        optional_baseurl="$(mirrors_get_rpm_baseurl "${distro}" "${major_version}" "${optional_repo}" "${mirror_base}" 2>/dev/null || true)"
    fi

    cat > "${repo_file}" <<EOF
[linux-toolbox-baseos]
name=Linux Toolbox BaseOS
baseurl=${baseos}
enabled=1
gpgcheck=0

[linux-toolbox-appstream]
name=Linux Toolbox AppStream
baseurl=${appstream}
enabled=1
gpgcheck=0

[linux-toolbox-extras]
name=Linux Toolbox Extras
baseurl=${extras}
enabled=1
gpgcheck=0
EOF

    if [[ -n "${optional_repo:-}" && -n "${optional_baseurl:-}" ]]; then
        cat >> "${repo_file}" <<EOF

[linux-toolbox-${optional_repo,,}]
name=Linux Toolbox ${optional_repo}
baseurl=${optional_baseurl}
enabled=1
gpgcheck=0
EOF
    fi
}

mirrors_write_epel_repo_file() {
    local major_version="$1"
    local mirror_base="$2"
    local repo_dir="${3:-/etc/yum.repos.d}"
    local repo_file="${repo_dir}/linux-toolbox-epel.repo"
    local epel_baseurl
    epel_baseurl="$(mirrors_get_epel_baseurl "${major_version}" "${mirror_base}")"
    mkdir -p "${repo_dir}"
    backup_file "${repo_file}"
    cat > "${repo_file}" <<EOF
[linux-toolbox-epel]
name=Linux Toolbox EPEL
baseurl=${epel_baseurl}
enabled=1
gpgcheck=0
EOF
}

mirrors_format_apt_sources() {
    local file_path="$1"
    awk '
        $1 ~ /^deb/ && $2 ~ /^https?:\/\// {
            printf("[APT] %s | suite=%s\n", $2, $3)
        }
        /^URIs:/ { uri=$2 }
        /^Suites:/ { printf("[APT] %s | suites=%s\n", uri, substr($0, 9)) }
    ' "${file_path}" 2>/dev/null || true
}

mirrors_format_rpm_sources() {
    local file_path="$1"
    awk -F= '
        /^baseurl=/ { printf("[RPM] baseurl=%s\n", $2) }
        /^(mirrorlist|metalink)=/ { printf("[RPM] %s=%s\n", $1, $2) }
    ' "${file_path}" 2>/dev/null || true
}

mirrors_render_current_sources_summary() {
    local target="${1:-}"
    if [[ -n "${target}" ]]; then
        if [[ -d "${target}" ]]; then
            while IFS= read -r file; do
                mirrors_format_rpm_sources "${file}"
            done < <(find "${target}" -maxdepth 1 -type f 2>/dev/null | sort)
        elif [[ -f "${target}" ]]; then
            if grep -qE '^(deb|URIs:)' "${target}" 2>/dev/null; then
                mirrors_format_apt_sources "${target}"
            else
                mirrors_format_rpm_sources "${target}"
            fi
        fi
        return 0
    fi

    ensure_os_detected
    case "${OS_ID}" in
        ubuntu|debian)
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                mirrors_format_apt_sources /etc/apt/sources.list.d/ubuntu.sources
            elif [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
                mirrors_format_apt_sources /etc/apt/sources.list.d/debian.sources
            fi
            mirrors_format_apt_sources /etc/apt/sources.list
            ;;
        centos|rocky|almalinux|rhel|fedora)
            while IFS= read -r file; do
                mirrors_format_rpm_sources "${file}"
            done < <(find /etc/yum.repos.d -maxdepth 1 -type f 2>/dev/null | sort)
            ;;
        *)
            echo "暂不支持当前系统的源摘要显示。"
            ;;
    esac
}

mirrors_show_current_system_sources() {
    clear_screen
    print_section "当前系统源"
    ensure_os_detected
    echo "系统: ${OS_PRETTY_NAME}"
    echo
    mirrors_render_current_sources_summary
    pause_enter
}

mirrors_select_system_source() {
    print_section "系统换源"
    cat <<'EOF'
1) 阿里云
2) 清华大学
3) 中国科大
4) 腾讯云
5) 华为云
EOF
    read -r -p "请选择镜像源: " source_choice
    local selection
    selection="$(mirrors_get_system_source_selection "${source_choice}")" || {
        log_error "无效镜像源选项。"
        pause_enter
        return 1
    }
    IFS='|' read -r mirror_base security_base mirror_name <<< "${selection}"
}

mirrors_apply_system_apt() {
    require_root || return 1
    ensure_os_detected
    mirrors_select_system_source || return 1
    local codename
    codename="$(mirrors_detect_codename)"

    case "${OS_ID}" in
        ubuntu)
            if ! mirrors_probe_apt_mirror "${mirror_base}" "ubuntu" "${codename}"; then
                log_error "镜像源探测失败：${mirror_name} (${codename}) 暂不可用。"
                pause_enter
                return 1
            fi
            mirrors_write_ubuntu_sources "${mirror_base}" "${security_base}"
            ;;
        debian)
            if ! mirrors_probe_apt_mirror "${mirror_base}" "debian" "${codename}"; then
                log_error "镜像源探测失败：${mirror_name} (${codename}) 暂不可用。"
                pause_enter
                return 1
            fi
            mirrors_write_debian_sources "${mirror_base}" "${security_base}"
            ;;
        *)
            log_error "系统换源当前只支持 Debian/Ubuntu。"
            pause_enter
            return 1
            ;;
    esac

    update_package_index
    log_ok "已切换到 ${mirror_name} 系统镜像源。"
    pause_enter
}

mirrors_restore_official() {
    require_root || return 1
    ensure_os_detected
    local codename
    codename="$(mirrors_detect_codename)"
    case "${OS_ID}" in
        ubuntu)
            local mirror_base security_base
            mirror_base="$(mirrors_get_official_base ubuntu)"
            security_base="$(mirrors_get_security_base ubuntu official)"
            if ! mirrors_probe_apt_mirror "${mirror_base}" "ubuntu" "${codename}"; then
                log_error "Ubuntu 官方源探测失败，暂不执行恢复。"
                pause_enter
                return 1
            fi
            mirrors_write_ubuntu_sources "${mirror_base}" "${security_base}"
            ;;
        debian)
            local mirror_base security_base
            mirror_base="$(mirrors_get_official_base debian)"
            security_base="$(mirrors_get_security_base debian official)"
            if ! mirrors_probe_apt_mirror "${mirror_base}" "debian" "${codename}"; then
                log_error "Debian 官方源探测失败，暂不执行恢复。"
                pause_enter
                return 1
            fi
            mirrors_write_debian_sources "${mirror_base}" "${security_base}"
            ;;
        *)
            log_error "恢复官方源当前只支持 Debian/Ubuntu。"
            pause_enter
            return 1
            ;;
    esac
    update_package_index
    log_ok "已恢复官方软件源。"
    pause_enter
}

mirrors_apply_system_rpm() {
    require_root || return 1
    ensure_os_detected
    case "${OS_ID}" in
        centos|rocky|almalinux) ;;
        *)
            log_error "RPM 系换源当前只支持 CentOS / Rocky / AlmaLinux。"
            pause_enter
            return 1
            ;;
    esac

    mirrors_select_system_source || return 1
    local major_version probe_url epel_probe_url
    major_version="$(mirrors_get_major_version "${OS_VERSION}")"
    probe_url="$(mirrors_get_rpm_baseurl "${OS_ID}" "${major_version}" "BaseOS" "${mirror_base}")"
    if ! mirrors_probe_url "${probe_url//\$basearch/x86_64}"; then
        log_error "RPM 镜像探测失败：${mirror_name} (${OS_ID} ${major_version}) 暂不可用。"
        pause_enter
        return 1
    fi

    mirrors_write_rpm_repo_file "${OS_ID}" "${mirror_base}" "${major_version}"

    epel_probe_url="$(mirrors_get_epel_baseurl "${major_version}" "${mirror_base}" | sed 's/\$basearch/x86_64/')"
    if mirrors_probe_url "${epel_probe_url}"; then
        mirrors_write_epel_repo_file "${major_version}" "${mirror_base}"
        log_info "已额外写入 EPEL 镜像源。"
    else
        log_warn "未探测到可用 EPEL 镜像，已跳过 EPEL 写入。"
    fi

    update_package_index
    log_ok "已写入 ${OS_ID} ${major_version} 镜像源（linux-toolbox-${OS_ID}.repo）。"
    pause_enter
}

mirrors_apply_docker_mirror_url() {
    local mirror_url="$1"
    local mirror_name="$2"
    require_root || return 1
    [[ -n "${mirror_url}" ]] || { log_error "Docker 镜像地址不能为空。"; pause_enter; return 1; }
    if ! mirrors_probe_docker_mirror "${mirror_url}"; then
        log_error "Docker 镜像探测失败：${mirror_name} (${mirror_url}) 暂不可用。"
        pause_enter
        return 1
    fi
    mkdir -p /etc/docker
    backup_file /etc/docker/daemon.json
    docker_merge_daemon_json /etc/docker/daemon.json "${mirror_url}"
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl restart docker || true
    fi
    docker info 2>/dev/null | grep -A3 'Registry Mirrors' || true
    log_ok "已配置 Docker 镜像源：${mirror_name}"
    pause_enter
}

mirrors_apply_docker_preset() {
    local choice="$1"
    local mirror_url mirror_name
    mirror_url="$(mirrors_get_docker_mirror_url "${choice}")" || {
        log_error "无效 Docker 镜像源选项。"
        pause_enter
        return 1
    }
    mirror_name="$(mirrors_get_docker_mirror_name "${choice}")"
    mirrors_apply_docker_mirror_url "${mirror_url}" "${mirror_name}"
}

mirrors_apply_docker_custom() {
    print_section "自定义 Docker 镜像地址"
    read -r -p "请输入 Docker 镜像地址（例如 https://docker.1ms.run ）: " mirror_url
    [[ -n "${mirror_url}" ]] || { log_error "Docker 镜像地址不能为空。"; pause_enter; return 1; }
    mirrors_apply_docker_mirror_url "${mirror_url}" "自定义地址"
}

mirrors_clear_docker_mirror() {
    require_root || return 1
    if [[ ! -f /etc/docker/daemon.json ]]; then
        log_warn "/etc/docker/daemon.json 不存在，无需清空。"
        pause_enter
        return 0
    fi
    backup_file /etc/docker/daemon.json
    docker_clear_registry_mirrors /etc/docker/daemon.json
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl restart docker || true
    fi
    log_ok "已清空 Docker registry-mirrors 配置。"
    pause_enter
}

mirrors_show_docker_config() {
    clear_screen
    print_section "当前 Docker 镜像配置"
    if [[ -f /etc/docker/daemon.json ]]; then
        cat /etc/docker/daemon.json
    else
        echo "/etc/docker/daemon.json 不存在。"
    fi
    echo
    docker info 2>/dev/null | grep -A3 'Registry Mirrors' || true
    pause_enter
}

module_system_mirrors_menu() {
    while true; do
        clear_screen
        print_section "系统换源"
        mirrors_render_system_menu
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) mirrors_show_current_system_sources ;;
            2) mirrors_apply_system_apt ;;
            3) mirrors_restore_official ;;
            4) mirrors_apply_system_rpm ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}

module_docker_mirrors_menu() {
    while true; do
        clear_screen
        print_section "Docker 换源"
        mirrors_render_docker_menu
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1|2|3|4) mirrors_apply_docker_preset "${choice}" ;;
            5) mirrors_apply_docker_custom ;;
            6) mirrors_clear_docker_mirror ;;
            7) mirrors_show_docker_config ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}

module_mirrors_menu() {
    while true; do
        clear_screen
        print_section "换源"
        mirrors_render_main_menu
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) module_system_mirrors_menu ;;
            2) module_docker_mirrors_menu ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}
