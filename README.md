# Nowhere / singbox-lite Linux 工具集

## singbox-lite 管理器

本仓库包含从 [0xdabiaoge/singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 引入并适配的 Lite 节点管理脚本，使用带 Nowhere 协议的 sing-box 核心。主入口是 `singbox.sh`。

在 Linux 服务器上运行：

```sh
sudo bash singbox.sh
```

主菜单的「添加节点」中：

- `[11] Nowhere` 创建 Nowhere Portal 入站；可选择 TCP、UDP 或 TCP+UDP。
- `[12] 批量创建节点` 支持把 Nowhere 与其他 Lite 协议一起规划端口。

Nowhere 入站使用 TLS 1.3、ALPN `now/1` 和脚本生成的自签证书。创建完成后会输出 `vector://` 管理链接及可直接交给 Nowhere sing-box 客户端的出站 JSON；客户端配置包含证书叶节点 SHA-256 `pin`。Nowhere 不写入 Clash/Mihomo YAML，因为这些客户端不支持该协议。

核心包来自 `jokjit/nowhere-singbox` 的 `sing-box.zip`，是 7z 格式的单文件 Linux ELF，脚本固定校验 SHA-256：

```text
EF81126AC8D9FD02234566D8EE844FE983973C6B4B8E840C54F0CC1309F01EB8
```

当前随附核心包只支持 Linux `x86_64/amd64`。服务器需要 `7z`、`jq`、`openssl`、`flock` 等依赖；首次运行会由系统包管理器安装缺失依赖。脚本会在替换核心前用新核心校验 `config.json` 与 `relay.json` 的真实组合配置，并保留失败回滚路径。

核心管理菜单显示二进制自身的 `sing-box version` 输出；固定策略使用 `nowhere-sha256-ef81126a8d9f` 作为归档锁标识，避免把上游模块版本误当作 Nowhere 发布版本。

Lite 脚本组件包括 `singbox.sh`、`advanced_relay.sh`、`parser.sh` 和 `xray_manager.sh`。节点配置及凭据位于 `/usr/local/etc/sing-box`，请按 root 权限运行并妥善保护该目录。

离线检查：

```sh
bash -n singbox.sh tests/test-singbox-nowhere.sh
bash tests/test-singbox-nowhere.sh
```

## 文件

- `singbox.sh`：主菜单、节点向导、核心管理和服务管理。
- `advanced_relay.sh`：高级中转与端口转发组件。
- `parser.sh`：配置解析组件。
- `xray_manager.sh`：Xray 组件。
- `sing-box.zip`：已校验的 Linux x86_64/amd64 Nowhere 核心包。
- `tests/test-singbox-nowhere.sh`：不启动服务的 Nowhere 源码级回归测试。

## 运行要求

脚本面向 Linux 服务器，需要 root 权限。首次运行会按发行版安装 `bash`、`jq`、`openssl`、`flock`、`7z` 等依赖；Alpine/musl 系统会额外安装 `gcompat`，用于运行随附的 glibc 核心。随附核心包只支持 Linux `x86_64/amd64`；Windows 开发机可执行语法检查和 source-only 测试，但不能直接启动其中的 Linux ELF。

配置、证书和节点凭据默认保存在 `/usr/local/etc/sing-box`。核心更新会校验归档 SHA-256、归档成员、ELF 文件和现有组合配置，并在服务验证失败时回滚旧核心。

## 验证

```sh
bash -n singbox.sh advanced_relay.sh parser.sh xray_manager.sh tests/test-singbox-nowhere.sh
bash tests/test-singbox-nowhere.sh
```

GitHub Actions 还会运行 Bash 语法检查、Nowhere 回归测试和 Alpine 环境检查。
