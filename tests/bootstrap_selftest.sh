#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/linux-toolbox-bootstrap-selftest.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "断言失败: ${message}" >&2
    echo "未找到: ${needle}" >&2
    echo "实际输出: ${haystack}" >&2
    exit 1
  fi
}

cp "${ROOT_DIR}/install.sh" "${TMP_DIR}/install.sh"
tar -czf "${TMP_DIR}/toolbox.tar.gz" -C "$(dirname "${ROOT_DIR}")" "$(basename "${ROOT_DIR}")"

output="$(TOOLBOX_BOOTSTRAP_ARCHIVE_URL="file://${TMP_DIR}/toolbox.tar.gz" bash "${TMP_DIR}/install.sh" --menu-only 2>/dev/null || true)"

assert_contains '系统基础管理' "${output}" '单文件 install.sh 自举后应能显示主菜单'
assert_contains 'SSH 与安全管理' "${output}" '单文件 install.sh 自举后应加载完整模块'
assert_contains '网络诊断与优化' "${output}" '单文件 install.sh 自举后应包含网络菜单'
assert_contains 'Docker 与服务环境' "${output}" '单文件 install.sh 自举后应包含 Docker 菜单'
assert_contains '换源' "${output}" '单文件 install.sh 自举后应包含换源菜单'

echo "bootstrap_selftest: PASS"
