#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  "install.sh"
  "lib/common.sh"
  "lib/detect.sh"
  "lib/ui.sh"
  "modules/system.sh"
  "modules/security.sh"
  "modules/network.sh"
  "modules/docker.sh"
  "modules/mirrors.sh"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "${ROOT_DIR}/${file}" ]]; then
    echo "缺少文件: ${file}" >&2
    exit 1
  fi
done

menu_output="$(printf '0\n' | bash "${ROOT_DIR}/install.sh" --menu-only 2>/dev/null || true)"

for label in \
  "系统基础管理" \
  "SSH 与安全管理" \
  "网络诊断与优化" \
  "Docker 与服务环境" \
  "换源"; do
  if ! grep -q "${label}" <<<"${menu_output}"; then
    echo "主菜单缺少分组: ${label}" >&2
    exit 1
  fi
done

echo "smoke_toolbox_v1: PASS"
