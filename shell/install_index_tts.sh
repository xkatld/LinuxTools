#!/bin/bash

# 更新包列表
sudo apt update

# 安装 git 和 git-lfs
sudo apt install -y git git-lfs

# 初始化 git-lfs
git lfs install

# 克隆项目
git clone https://github.com/index-tts/index-tts.git
cd index-tts

# 安装 uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# 安装依赖
uv sync --all-extras

# 安装 modelscope
uv tool install "modelscope"

# 下载模型
mkdir -p checkpoints
modelscope download --model IndexTeam/IndexTTS-2 --local_dir checkpoints

# 检查 GPU 配置
uv run tools/gpu_check.py

echo "安装完成！运行 uv run webui.py 启动应用"
