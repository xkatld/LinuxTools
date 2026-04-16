# Linux Toolbox V1 重构方案

## 当前判断

当前基底仓库选择：`xkatld/LinuxTools`

选择原因：
1. 代码量小，便于快速重构。
2. 当前已经有主菜单 + 子脚本的基本形态。
3. 中文交互，适合继续改造成面向服务器运维的工具箱。
4. 比 `kejilion/sh` 这类超大仓库更容易控复杂度。

不选其他候选的原因：
- `kejilion/sh`：功能过多、历史包袱重，第一版容易陷入删改泥潭。
- `SuperNG6/linux-setup.sh`：思路不错，但主入口脚本过大，且仓库许可证文件不完整，直接公开二改不够稳妥。
- `tveal/bash-toolkit`：菜单框架清晰，但方向偏 AWS，会有较多无关代码需要清理。

## 已检查结果

仓库本地路径：`/home/lucky/projects/linux-toolbox`

当前分支：`feat/linux-toolbox-v1`

已验证：
- `linuxtools.sh`
- `shell/apt-update.sh`
- `shell/disk-manager.sh`
- `shell/install-pve.sh`
- `shell/linuxmirrors.sh`
- `shell/ssh-manager.sh`
- `shell/virtual-memory-manager.sh`

以上脚本均通过 `bash -n` 语法检查。

## 当前基底问题

### 1. 主入口是“远程拉脚本再执行”
这会带来几个问题：
- 调试不方便
- 本地版本与远程版本容易漂移
- 安全性和可追踪性一般
- 不利于做统一日志、统一备份、统一验证

### 2. 模块命名和分组不统一
当前是：
- SSH 管理
- 系统升级
- 镜像脚本
- 硬盘管理
- PVE
- 虚拟内存

这更像“脚本集合入口”，还不是完整的“工具箱产品”。

### 3. 缺统一公共库
每个脚本重复写：
- root 检查
- 日志输出
- 系统识别
- 确认提示
- 备份逻辑

### 4. 缺统一验证与回滚
高危改动后，还没有完全收口到一套统一流程里：
- 先检查
- 再备份
- 再修改
- 再验证
- 失败回滚

## 第一版重构目标

将当前仓库改造成：
- 本地模块执行
- 主菜单分组明确
- 统一公共函数库
- 统一日志/备份/验证机制
- 以服务器运维为主的第一版 Linux 工具箱

## 第一版主菜单

### 1. 系统基础管理
建议功能：
- 查看系统概况
- 同步上海时间
- 更新系统软件包
- 安装常用工具集
- 修改主机名
- 创建用户并加入 sudo

### 2. SSH 与安全管理
建议功能：
- 查看 SSH 当前配置摘要
- 修改 SSH 端口
- 开启/关闭 root 登录
- 开启/关闭密码登录
- 添加 SSH 公钥
- 查看 SSH 登录记录
- 安装 Fail2ban

### 3. 网络诊断与优化
建议功能：
- 查看网络信息摘要
- 修改 DNS
- 查看监听端口
- 测试指定端口连通性
- 检查邮件端口
- 查看带宽占用连接
- 检查并启用 BBR

### 4. Docker 与服务环境
建议功能：
- 安装 Docker
- 安装 Compose 插件
- 配置 Docker 镜像加速
- 查看容器状态
- 查看容器日志
- 清理 Docker 垃圾

### 5. 磁盘、文件与备份
建议功能：
- 查看磁盘分区
- 挂载数据盘
- 卸载数据盘
- 查大文件
- 备份指定目录
- 查看/清理 Bash 历史

## 建议目录结构

```text
linux-toolbox/
├── install.sh
├── README.md
├── docs/
│   └── linux-toolbox-v1-refactor-plan.md
├── lib/
│   ├── common.sh
│   ├── detect.sh
│   ├── ui.sh
│   ├── backup.sh
│   └── validate.sh
├── modules/
│   ├── system.sh
│   ├── security.sh
│   ├── network.sh
│   ├── docker.sh
│   └── disk.sh
└── legacy/
    └── shell/
```

## 重构策略

### 阶段 1：保留旧脚本，建立新骨架
- 新增 `install.sh`
- 新增 `lib/`
- 新增 `modules/`
- 旧的 `shell/` 暂时保留，避免一次性拆崩

### 阶段 2：把可复用能力抽到公共库
优先抽这些：
- 日志函数
- root/sudo 检查
- 系统检测
- 包管理器适配
- 统一确认提示
- 配置备份
- 结果验证

### 阶段 3：按菜单逐步迁移
建议迁移顺序：
1. system
2. network
3. security
4. docker
5. disk

### 阶段 4：清理旧入口
当新入口稳定后：
- 弱化旧 `linuxtools.sh`
- 将旧 `shell/` 移到 `legacy/shell/`
- README 改为新结构说明

## 第一批建议落地的文件

### 新建
- `install.sh`
- `lib/common.sh`
- `lib/detect.sh`
- `lib/ui.sh`
- `modules/system.sh`
- `modules/security.sh`
- `modules/network.sh`
- `modules/docker.sh`
- `modules/disk.sh`

### 保留参考
- `shell/ssh-manager.sh`
- `shell/apt-update.sh`
- `shell/disk-manager.sh`

## 关键实现原则

1. 危险操作必须二次确认。
2. 修改配置前必须自动备份。
3. 修改后必须立刻验证。
4. 优先支持 Debian / Ubuntu。
5. 第一版不追求大而全，先追求稳。

## 下一步

下一步直接进入脚手架实现：
1. 建立新目录结构。
2. 写 `install.sh` 主入口。
3. 写 `lib/common.sh`、`lib/detect.sh`、`lib/ui.sh`。
4. 先做系统、网络、SSH 三个模块的空骨架和基础菜单。
5. 跑 `bash -n` 做最小验证。
