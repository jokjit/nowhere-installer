# Nowhere 交互式 Linux 安装脚本

为 [NodePassProject/Nowhere](https://github.com/NodePassProject/Nowhere) 编写的独立中文安装工具。使用官方 Release 二进制，无需 Docker、Rust 或 Bash。

## 使用

将 `nowhere.sh` 上传到 Linux 服务器，在 SSH 终端执行：

```sh
sudo sh nowhere.sh
```

已经是 root 时执行 `sh nowhere.sh`。Alpine 默认通常没有 sudo，请先使用 root 登录。脚本不需要执行权限，必须保存为 UTF-8、LF 换行。

菜单提供：

```text
1. 快速安装 Portal / Vector
2. 更新 / 安装指定版本
3. 重新配置
4. 状态 / 连接信息
5. 启动
6. 停止
7. 重启
8. 最近 80 行日志
9. 开机自启设置
10. 卸载
0. 退出
```

安装成功后，再次管理无需原始下载文件：

```sh
sudo /usr/local/sbin/nowhere-manager
```

也可以指定操作，配置及确认步骤仍然交互完成：

```sh
sudo sh nowhere.sh install
sudo sh nowhere.sh update
sudo sh nowhere.sh configure
sudo sh nowhere.sh logs
sudo sh nowhere.sh restart
```

## 最简单的节点部署方式

1. 在服务端选择「快速安装 Portal」。默认版本 `latest`，脚本会自动探测公网 IP、生成密钥和持久化证书；监听端口需要手动输入。
2. 安装结束会直接显示完整 Vector URL。复制这条 URL，并在客户端选择「快速安装 Vector」，粘贴即可完成配置。
3. 客户端默认 SOCKS5 地址为 `127.0.0.1:1080`。

「快速安装 Vector」现在也支持按客户端常用字段逐项填写。端口需要手动输入；若本机已有 Portal 配置，Key 会自动复用：

```text
地址       -> vector:// 的主机部分
端口       -> vector:// 的端口部分
Key        -> 自动复用本机 Portal 的共享密钥；独立客户端首次配置时需要输入
网络       -> 同时写入 up 和 down（默认 mix，可选 tcp / udp）
TLS SNI    -> 默认 `swdist.apple.com`，可改为证书对应的域名
ALPN       -> 使用官方默认 `now/1`，不再要求填写
```

向导也保留完整 `vector://` 粘贴模式。脚本自动生成的自签证书会同时输出默认 SNI 和 `pin`；使用受信任 CA 证书时可只使用证书对应的 SNI。

如果自动探测公网 IP 失败，脚本只会额外询问一个公网 IP 或域名。高级模式仍可手动设置监听地址、协议、SOCKS5 账号密码和证书校验方式。
应用程序使用客户端的 SOCKS5 代理。例如在客户端执行：

   ```sh
   curl --socks5-hostname 127.0.0.1:1080 https://example.com
   ```

也可以在已安装 Nowhere 的客户端直接使用服务端给出的 URL：

```sh
nowhere 'vector://共享密钥@服务器地址:2000?up=tcp&down=tcp&pin=证书指纹&socks=127.0.0.1:1080'
```

以上中文字段是说明占位符；实际运行时复制脚本输出的完整 URL。共享密钥有特殊字符时，向导中填写原始值；复制 URL 时保留其中的百分号编码。

Portal 默认同时提供 TCP 和 UDP。主机防火墙、云厂商安全组和 NAT 映射需要分别放行对应的 TCP / UDP 端口；脚本会给出端口提示，不修改防火墙。IPv6 监听可填写 `::`，客户端填写实际 IPv6 地址，脚本会补方括号。

客户端可分别选择上行、下行的 `tcp`、`udp`、`mix`。`mix` 要求服务端两种传输均可访问。SOCKS5 监听非回环地址时，向导强制设置用户名和密码。

## 兼容范围

| 系统系列 | 依赖安装器 | 服务管理 |
| --- | --- | --- |
| Debian / Ubuntu / Linux Mint | apt-get | systemd |
| RHEL / Rocky / AlmaLinux / Fedora / CentOS | dnf / yum | systemd |
| Alpine Linux | apk | OpenRC + supervise-daemon |
| Arch / Manjaro | pacman | systemd |
| openSUSE / SLES | zypper | systemd |

- CPU：**x86_64 / amd64、aarch64 / arm64**；统一下载官方 musl 包，避免不同 glibc 版本造成的兼容问题。
- Shell：POSIX `sh`，兼容 dash、Bash 的 sh 模式及 Alpine BusyBox ash 的语法。
- 必须有正常运行的 systemd 或 OpenRC，以及可访问 GitHub API 和 Release 下载的 HTTPS 网络。
- SysVinit、runit、OpenWrt、无 init 的容器、32 位 ARM、i386、MIPS、RISC-V 暂不支持，会在安装前提示。
- 系统软件源必须可用并包含所需依赖。CentOS 等已停止维护的版本可能需要管理员先修复软件源；Arch 软件包缓存过旧时先按发行版规范更新系统。
- 「支持某系列」指脚本具有对应适配，**不代表已在每个发行版和版本上逐一真机测试**。

截至 2026-09-11，开发时核对的正式版为 **v1.8.3**。main 分支已经包含不同的端点语法和协议行为，因此脚本下载正式 Release，使用正式版支持的紧凑 URL；不自动编译 main。Portal 和 Vector 建议保持相同版本，升级前核对上游发行说明。

## 文件、更新与证书

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/nowhere` | 官方程序 |
| `/usr/local/sbin/nowhere-manager` | 本管理脚本 |
| `/usr/local/libexec/nowhere-run` | 读取配置并启动程序的包装脚本 |
| `/etc/nowhere/service.url` | 本机配置，权限 600 |
| `/etc/nowhere/client.url` | Portal 生成的客户端 URL，权限 600 |
| `/etc/nowhere/cert.pem`、`key.pem` | 持久化证书与私钥，权限 600 |
| `/etc/nowhere/version`、`managed-by` | 版本及管理标记 |
| `/etc/systemd/system/nowhere.service` | systemd 服务 |
| `/etc/init.d/nowhere` | OpenRC 服务 |
| `/var/log/nowhere.log` | OpenRC 日志；systemd 使用 journal |

每台机器管理一个名为 `nowhere` 的实例。服务以 root 运行，支持低于 1024 的端口。配置不会作为 shell 代码执行，systemd/OpenRC 服务文件也不直接嵌入密钥；上游程序使用命令行 URL，因此有权限查看进程参数的本机用户仍可能看到密钥。

下载先校验 GitHub Release 元数据提供的 SHA-256，再检查压缩包结构和本机可执行性。缺少校验摘要的旧发行包会被拒绝。SHA-256 是完整性检查，并不等同于独立的发布者签名。

更新不会修改现有证书和 URL。下载完成后才停止服务，原子替换程序，并检查实际服务进程连续运行 5 秒；失败则恢复旧程序及配置。更新前服务若是停止状态，检查后恢复停止状态。首次安装失败会撤回程序和连接配置，保留管理文件和日志，方便重试。主机突然断电或 `kill -9` 不会执行 shell 的自动恢复逻辑。

默认生成有效期 10 年的持久化自签名证书，客户端以 `pin` 校验，不需要域名。复用证书可避免重启后指纹改变。导入已有证书时，脚本复制证书和私钥，不跟随 ACME 原文件自动续期；更换证书需重新配置，并同步更新客户端指纹。已有受信任 CA 证书的服务端也可让 Vector 选择 SNI 域名校验。

卸载默认保留 `/etc/nowhere`；再次安装可以直接复用。只有再次确认才删除配置、密钥、证书和 OpenRC 日志。systemd 的历史 journal 由系统日志策略清理。OpenRC 日志请按服务器运维策略配置 logrotate；脚本不接管全局日志设置。

异常中断后若提示安装锁残留，先检查 `/run/nowhere-installer.lock/pid` 和对应进程，确认没有安装操作在运行后，再移除该锁目录。

## 发布为一行下载命令

本项目已发布到 GitHub：<https://github.com/jokjit/nowhere-installer>。

```sh
curl -fsSL 'https://raw.githubusercontent.com/jokjit/nowhere-installer/master/nowhere.sh' -o nowhere.sh && sudo sh nowhere.sh
```

没有 curl 但有 wget 的机器也可以：

```sh
wget -O nowhere.sh 'https://raw.githubusercontent.com/jokjit/nowhere-installer/master/nowhere.sh' && sh nowhere.sh
```

推荐先保存后执行，便于安装时自动保存管理入口。通过 `curl | sudo sh` 运行时，脚本从 `/dev/tty` 读取交互输入，但无法自动保存原始脚本为管理命令。

## 验证

本地离线回归检查不会安装软件或启动系统服务；文件操作都指向临时目录：

```sh
sh -n nowhere.sh
shellcheck -x -P SCRIPTDIR -s sh nowhere.sh tests/test-installer.sh
sh tests/test-installer.sh
```

回归覆盖输入校验、URL 编码、证书复用、服务模板、安装、更新、卸载后重装、失败回滚和进程反复重启检测。服务管理与包管理模拟无法代替 Linux 真机上的 systemd/OpenRC 安装测试。

`tests/upstream-smoke.mjs` 使用官方程序，在回环地址运行 Portal、Vector 和测试 HTTP 服务，验证 TCP/TCP、TCP/UDP、UDP/TCP、UDP/UDP、Mix/Mix、SOCKS5 密码以及错误证书指纹拒绝：

```sh
node tests/upstream-smoke.mjs /path/to/nowhere
```

需要 Node.js 22+ 和 OpenSSL；可通过第三个参数指定 OpenSSL 路径。测试结束会关闭自己创建的进程并清理临时证书，不改动系统服务。

随附 GitHub Actions 配置，发布仓库后会运行 dash、Bash、Alpine ash 离线测试，以及已固定 SHA-256 的 v1.8.3 Linux musl 程序回环测试。工作流文件已准备好，但本地创建文件不代表 GitHub CI 已经运行。
