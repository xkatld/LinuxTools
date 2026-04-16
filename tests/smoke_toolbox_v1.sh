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

assert_menu_contains_labels() {
  local menu_output="$1"

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
}

menu_output="$(printf '0\n' | bash "${ROOT_DIR}/install.sh" --menu-only 2>/dev/null || true)"
assert_menu_contains_labels "${menu_output}"

bootstrap_test_dir="$(mktemp -d /tmp/linux-toolbox-smoke.XXXXXX)"
trap 'rm -rf "${bootstrap_test_dir}"' EXIT
cp "${ROOT_DIR}/install.sh" "${bootstrap_test_dir}/install.sh"
tar -czf "${bootstrap_test_dir}/toolbox.tar.gz" -C "$(dirname "${ROOT_DIR}")" "$(basename "${ROOT_DIR}")"
bootstrap_output="$(TOOLBOX_BOOTSTRAP_ARCHIVE_URL="file://${bootstrap_test_dir}/toolbox.tar.gz" bash "${bootstrap_test_dir}/install.sh" --menu-only 2>/dev/null || true)"
assert_menu_contains_labels "${bootstrap_output}"

echo "smoke_toolbox_v1: PASS"
