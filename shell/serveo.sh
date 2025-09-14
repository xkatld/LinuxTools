#!/usr/bin/env bash
if ! command -v ssh >/dev/null 2>&1; then
  echo "请先安装 ssh：sudo apt update && sudo apt install openssh-client"
  exit 1
fi

read -p "请输入要映射的本地端口（默认 8080）: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8080}

ssh -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -R 80:localhost:"${LOCAL_PORT}" serveo.net
