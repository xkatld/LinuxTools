# Linux Toolbox V1 重构与当前状态

## 当前判断

这个仓库已经不再是单纯的“脚本集合入口”，而是一个面向 Linux 服务器运维场景的 Bash 工具箱雏形。

当前方向已经明确：
1. 实用优先，不追求大而全。
2. 主打服务器高频运维动作，不做大杂烩功能池。
3. 本地模块化执行为主，同时兼容远程单文件入口。
4. 高风险操作统一走“检查 -> 备份 -> 修改 -> 验证 -> 失败回滚/恢复提示”。

## 仓库现状

仓库本地路径：`/home/lucky/projects/linux-toolbox`

当前分支：`feat/linux-toolbox-v1`

当前已经完成的结构：

```text
linux-toolbox/
├── install.sh
├── linuxtools.sh
├── README.md
├── docs/
│   └── linux-toolbox-v1-refactor-plan.md
├── lib/
│   ├── common.sh
│   ├── detect.sh
│   └── ui.sh
├── modules/
│   ├── system.sh
│   ├── security.sh
│   ├── network.sh
│   ├── docker.sh
│   └── mirrors.sh
├── shell/                 # 旧脚本，暂时保留作参考
└── tests/
    ├── smoke_toolbox_v1.sh
    ├── hardening_regression.sh
    └── bootstrap_selftest.sh
```

## 目前已经落地的 5 组功能

### 1. 系统基础管理
- 查看系统概况
- 同步上海时间
- 更新系统软件包
- 安装常用工具集
- 修改主机名
- 创建 sudo 用户

### 2. SSH 与安全管理
- 查看 SSH 当前配置摘要
- 修改 SSH 端口
- 开启/关闭 root 登录
- 开启/关闭密码登录
- 添加 SSH 公钥
- 查看 SSH 登录记录
- 安装 Fail2ban

### 3. 网络诊断与优化
- 查看网络信息摘要
- 查看公网 IP
- 修改 DNS
- 支持 plain / systemd-resolved / resolvconf / NetworkManager 四种常见 DNS 接管方式
- 恢复上次 DNS 配置
- 自动生成 DNS 恢复脚本
- 查看监听端口
- 测试指定端口连通性

### 4. Docker 与服务环境
- 安装 Docker
- 安装 Docker Compose 插件
- 查看 Docker 引擎状态
- 查看容器状态
- 查看容器日志
- 清理 Docker 垃圾

### 5. 换源
- 系统换源 / Docker 换源分组
- 查看当前系统源摘要
- Debian / Ubuntu 换源
- 恢复 Debian / Ubuntu 官方源
- CentOS / Rocky / AlmaLinux 换源
- Docker 镜像源预置、自定义、清空、查看配置

## 已完成的关键重构

### 1. 入口重构
- `install.sh` 已成为主入口
- `linuxtools.sh` 已改成兼容转发入口
- 旧的“远程拉子脚本后再执行”模式已经退到次要位置

### 2. 公共库抽离
已统一抽到 `lib/`：
- 日志输出
- root 检查
- 备份逻辑
- 统一确认提示
- 系统识别
- 包管理器适配

### 3. 高风险功能补强
已经重点补过这些高风险点：
- SSH 改端口后校验新端口是否真的监听
- SSH 修改失败时恢复原配置
- DNS 识别不同接管方式，不再只粗暴改 `/etc/resolv.conf`
- Docker `daemon.json` 合并写入，不再直接覆盖
- 系统换源写入前探测镜像可达性
- Docker 换源写入前探测 `/v2/`

### 4. 菜单取舍调整
当前已经明确不走“大而杂”的路线：
- 去掉低价值、易分散注意力的边角功能
- 保留上海时间同步
- 保留公网 IP、系统源摘要、Docker 引擎状态这类高频排障入口
- Docker 换源统一收口到“换源”分组

### 5. 单文件远程入口补强
`install.sh` 已支持自举模式：
- 如果当前只有单文件 `install.sh`
- 会自动拉取完整工具箱归档
- 再切回完整目录执行

这条链路已经有独立测试覆盖，不只是 README 里写一条命令。

## 当前测试体系

### 1. 冒烟测试
文件：`tests/smoke_toolbox_v1.sh`

作用：
- 检查核心文件是否存在
- 检查主菜单 5 个一级分组是否正常输出
- 额外验证单文件自举后的主菜单是否能拉起

### 2. 高风险回归测试
文件：`tests/hardening_regression.sh`

作用：
- SSH 新端口监听校验
- DNS 模式识别与写入辅助逻辑
- Docker `daemon.json` 合并与清理
- 系统源 / Docker 镜像探测逻辑
- 菜单取舍与核心入口保留情况

### 3. 单文件自举测试
文件：`tests/bootstrap_selftest.sh`

作用：
- 只复制一份 `install.sh`
- 本地打包当前仓库 tar.gz 作为自举源
- 验证单文件入口能自动拉起完整工具箱

## 当前验证方式

```bash
cd /home/lucky/projects/linux-toolbox
for f in install.sh lib/*.sh modules/*.sh tests/*.sh; do
  bash -n "$f"
done
bash tests/bootstrap_selftest.sh
bash tests/hardening_regression.sh
bash tests/smoke_toolbox_v1.sh
```

## 当前设计结论

这版 V1 已经具备继续迭代的基础，重点不是再继续铺功能，而是保持：
1. 菜单清晰
2. 风险可控
3. 修改后可验证
4. 远程单文件入口可自测

也就是说，这个项目当前最合适的节奏是：
- 小步补高频功能
- 每补一项就补测试
- 不把工具箱重新做回“大杂烩脚本集合”

## 下一步建议

下一阶段更值得做的是：
1. 把当前分支推到远程，固定一个可分享的测试入口。
2. 用 commit SHA 固定 Raw 地址做远程安装验证，避免分支 Raw 缓存影响测试。
3. 如果继续扩展，优先补：
   - DNS 进一步兼容 dhclient 场景
   - Docker 常见服务的一键部署模板
   - 系统源摘要展示再更友好一点
   - 更清晰的日志和失败提示

## 不建议现在做的事

当前不建议优先做：
- 面板大集合
- 游戏或花哨功能
- 未经充分约束的第三方脚本聚合
- 太多系统专属特性一次性并入

原因很简单：
- 会让菜单失焦
- 会让验证链路变重
- 会显著提高后续维护成本
