# Linux Toolbox

一个面向 Linux 服务器的 Bash 工具箱，当前第一版先聚焦这 5 组高频功能：

1. 系统基础管理
2. SSH 与安全管理
3. 网络诊断与优化
4. Docker 与服务环境
5. 换源

## 当前状态

本仓库已经从“远程下载子脚本再执行”的旧模式，切到“本地模块化执行”的新模式。

结合同类工具箱项目（如 kejilion、NAS 油条工具箱）的常见做法，这一版明确走“实用优先”路线：
- 保留系统信息、SSH、DNS、Docker、换源这类高频运维能力
- 增加公网 IP、当前源摘要、Docker 镜像配置查看这类排障常用入口
- 不把低频、易失控或偏杂项的功能先塞进来，比如游戏、面板大杂烩、压力测试、安全工具集合
- Docker 换源统一收口到“换源”分组，避免在多个菜单重复维护同一套逻辑

当前主入口：
- `install.sh`
- `linuxtools.sh`（兼容入口，内部转发到 `install.sh`）

## 目录结构

```text
linux-toolbox/
├── install.sh
├── linuxtools.sh
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
    ├── bootstrap_selftest.sh
    └── smoke_toolbox_v1.sh
```

## 运行方式

### 远程一键执行

> 现在支持单独执行 `install.sh`：如果当前目录下没有 `lib/` 和 `modules/`，脚本会自动拉取完整工具箱再启动。

分支版入口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckxine/LinuxTools/feat/linux-toolbox-v1/install.sh)
```

如果老大刚 push 完就要马上验证，建议优先用提交 SHA 固定地址，避免 GitHub Raw 分支缓存：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckxine/LinuxTools/c22fa0c/install.sh)
```

### 单文件自举自测

如果老大想验证“只有一个 install.sh 时，能不能自动拉起完整工具箱”，直接跑：

```bash
bash tests/bootstrap_selftest.sh
```

这条测试会做 3 件事：
- 只复制一份 `install.sh` 到临时目录
- 本地打包当前仓库 tar.gz 作为自举源
- 用 `TOOLBOX_BOOTSTRAP_ARCHIVE_URL=file://...` 模拟远程单文件入口，再检查主菜单是否正常出现

如果想手工看输出，也可以直接执行：

```bash
tmpdir="$(mktemp -d)" && \
cp install.sh "$tmpdir/install.sh" && \
tar -czf "$tmpdir/toolbox.tar.gz" -C .. linux-toolbox && \
TOOLBOX_BOOTSTRAP_ARCHIVE_URL="file://$tmpdir/toolbox.tar.gz" bash "$tmpdir/install.sh" --menu-only
```

### 本地运行

```bash
bash install.sh
```

或者：

```bash
bash linuxtools.sh
```

### 查看主菜单（不执行）

```bash
bash install.sh --menu-only
```

## 已实现菜单

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
- 修改后直接提示当前 DNS 接管模式和恢复命令
- 查看监听端口
- 测试指定端口连通性

### 4. Docker 与服务环境
- 安装 Docker
- 安装 Docker Compose 插件
- 查看 Docker 引擎状态
- 查看容器状态
- 查看容器日志
- 清理 Docker 垃圾
- Docker 换源统一收口到“换源 -> Docker 换源”，避免重复菜单入口

### 5. 换源
- 分组入口：系统换源 / Docker 换源
- 系统换源：查看当前系统源、Debian/Ubuntu 换源、恢复 Debian/Ubuntu 官方源、CentOS/Rocky/AlmaLinux 换源
- RPM 系换源会额外处理 CRB / PowerTools，并在可用时写入 EPEL
- 系统换源内置镜像：阿里云、清华大学、中国科大、腾讯云、华为云
- Docker 换源内置镜像：1ms、DaoCloud、中科大、腾讯云
- 支持自定义 Docker 镜像地址
- 支持清空 Docker 镜像加速并查看当前 Docker 配置
- 写入前探测系统镜像可用性
- Docker 镜像地址会先探测 /v2/ 连通性

## 验证方式

### 语法检查

```bash
for f in install.sh lib/*.sh modules/*.sh tests/*.sh; do
  bash -n "$f"
done
```

### 冒烟测试

```bash
bash tests/smoke_toolbox_v1.sh
```

### 单文件自举测试

```bash
bash tests/bootstrap_selftest.sh
```

### 高风险回归测试

```bash
bash tests/hardening_regression.sh
```

## 注意事项

1. 涉及改配置、装软件、改 SSH、换源等操作时，建议使用 root 运行。
2. 修改 SSH 端口、关闭密码登录前，先确认你有可用的密钥登录方式。
3. 系统换源当前已覆盖 Debian / Ubuntu，以及 CentOS / Rocky / AlmaLinux 的基础 repo 写入。
4. Docker 安装默认使用官方安装脚本 `get.docker.com`。
5. Docker 换源会写入 `/etc/docker/daemon.json`，修改后会尝试重启 Docker。
6. RPM 系换源当前采用新增 `linux-toolbox-*.repo` 的方式接管镜像源，便于和原 repo 分开。
7. DNS、SSH、apt 源这类操作都属于高影响变更，建议在远程服务器上谨慎执行。

## 下一步建议

下一阶段可以继续补：
- dhclient 场景的 DNS 接管适配
- 更细的日志与验证输出
- AlmaLinux / Rocky / Alpine 适配
- Docker 常见服务一键安装
- 网络测速与路由检测
