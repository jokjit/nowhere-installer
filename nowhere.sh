#!/bin/sh
# Nowhere interactive installer. POSIX sh; no Bash, Docker or Rust required.
# Upstream: https://github.com/NodePassProject/Nowhere
set -eu

REPO=NodePassProject/Nowhere
BIN=/usr/local/bin/nowhere
MANAGER=/usr/local/sbin/nowhere-manager
RUNNER=/usr/local/libexec/nowhere-run
CONF_DIR=/etc/nowhere
UNIT=/etc/systemd/system/nowhere.service
INIT=/etc/init.d/nowhere
LOG=/var/log/nowhere.log
LOCK=/run/nowhere-installer.lock
WORK_DIR=
LOCK_HELD=0
ROLLBACK_PENDING=0
WAS_ACTIVE=0
INPUT_FD=0
INIT_SYSTEM=
MANAGER_URL="https://raw.githubusercontent.com/$REPO/master/nowhere.sh"

say() { printf '%s\n' "$*"; }
warn() { printf '提示：%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ask() {
    # Never consume the script stream when invoked through a pipe.
    printf '%s' "$1" >&2
    if [ -n "${2:-}" ]; then printf ' [%s]' "$2" >&2; fi
    printf '：' >&2
    IFS= read -r REPLY <&"$INPUT_FD" || die '输入已结束。请在交互式终端中运行脚本。'
    REPLY=${REPLY:-${2:-}}
}

confirm() {
    ask "$1 (y/N)" n
    case "$REPLY" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

valid_port() {
    case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}

ask_port() {
    while :; do
        ask "$1" "$2"
        if valid_port "$REPLY"; then return; fi
        warn '端口必须是 1–65535 的整数，不带前导零。'
    done
}

valid_host() {
    # Accept a hostname, IPv4 or bare/bracketed IPv6; reject URL delimiters.
    case "$1" in
        ''|*[!a-zA-Z0-9.:[\]-]*|*'['*'['*|*']'*']'*) return 1 ;;
    esac
    case "$1" in
        \[*\])
            vh_inner=${1#\[}; vh_inner=${vh_inner%\]}
            case "$vh_inner" in *[!0-9a-fA-F:]*|'') return 1 ;; esac
            case "$vh_inner" in *:*) return 0 ;; *) return 1 ;; esac ;;
        *'['*|*']'*) return 1 ;;
        *:*) case "$1" in *[!0-9a-fA-F:]*) return 1 ;; esac ;;
        -*|.*|*..*) return 1 ;;
    esac
    return 0
}

url_host() {
    case "$1" in \[*\]) printf '%s' "$1" ;; *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac
}

ask_host() {
    while :; do
        ask "$1" "${2:-}"
        if valid_host "$REPLY"; then REPLY=$(url_host "$REPLY"); return; fi
        warn '请输入 IP 或域名，不要附带协议、路径或端口。'
    done
}

url_encode() {
    # Encode bytes, including non-ASCII UTF-8. Never evaluate user input.
    printf '%s' "$1" | od -An -v -tu1 | awk '
        { for (i=1; i<=NF; i++) {
            n=$i
            if ((n>=48 && n<=57) || (n>=65 && n<=90) ||
                (n>=97 && n<=122) || n==45 || n==46 || n==95 || n==126)
                printf "%c", n
            else printf "%%%02X", n
        }}'
}

valid_pin() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
}

detect_arch() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64) ARCH=x86_64 ;;
        aarch64|arm64) ARCH=aarch64 ;;
        *) die '官方 Linux 安装包仅支持 x86_64、ARM64；32 位 ARM、i386、MIPS、RISC-V 暂不支持。' ;;
    esac
    TARGET=$ARCH-unknown-linux-musl
}

detect_init() {
    if [ -d /run/systemd/system ] && have systemctl; then
        INIT_SYSTEM=systemd
    elif [ -d /run/openrc ] && have rc-service && have rc-update && have supervise-daemon; then
        INIT_SYSTEM=openrc
    else
        die '需要正在运行的 systemd 或 OpenRC（含 supervise-daemon）。SysVinit、runit、无 init 的容器暂不支持。'
    fi
}

ensure_deps() {
    missing=
    for dep in curl jq tar gzip openssl sha256sum od awk; do
        have "$dep" || missing="$missing $dep"
    done
    ca_found=0
    for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
        [ ! -s "$ca" ] || ca_found=1
    done
    if [ -z "$missing" ] && [ "$ca_found" -eq 1 ]; then return; fi
    say "正在安装下载、校验和证书依赖：${missing:- CA 证书}"
    if have apt-get; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq tar gzip openssl coreutils
    elif have apk; then
        apk add --no-cache ca-certificates curl jq tar gzip openssl coreutils
    elif have dnf; then
        dnf install -y ca-certificates curl jq tar gzip openssl coreutils
    elif have yum; then
        yum install -y ca-certificates curl jq tar gzip openssl coreutils
    elif have zypper; then
        zypper --non-interactive install ca-certificates curl jq tar gzip openssl coreutils
    elif have pacman; then
        # Avoid a partial Arch upgrade (pacman -Sy).
        pacman -S --needed --noconfirm ca-certificates curl jq tar gzip openssl coreutils
    else
        die "无法自动安装依赖。请手动安装 ca-certificates curl jq tar gzip openssl coreutils 后重试。缺少：$missing"
    fi
    for dep in curl jq tar gzip openssl sha256sum od awk; do
        have "$dep" || die "依赖仍缺失：$dep"
    done
}

fetch() {
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 600 --retry 2 \
        --user-agent 'nowhere-interactive-installer' --output "$2" "$1"
}

make_work() {
    if [ -n "$WORK_DIR" ]; then return; fi
    WORK_DIR=$(mktemp -d /tmp/nowhere-installer.XXXXXXXX) || die '无法创建临时目录。'
    chmod 700 "$WORK_DIR"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}

acquire_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        LOCK_HELD=1
        printf '%s\n' "$$" > "$LOCK/pid"
    else
        die "另一个管理操作正在运行，或上次异常中断留下锁：$LOCK。请先确认锁内 pid 对应进程已退出。"
    fi
}

service_active() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet nowhere.service ;;
        openrc) rc-service nowhere status >/dev/null 2>&1 ;;
    esac
}

service_do() {
    case "$INIT_SYSTEM" in
        systemd) systemctl "$1" nowhere.service ;;
        openrc) rc-service nowhere "$1" ;;
    esac
}

service_enable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable nowhere.service ;;
        openrc) rc-update add nowhere default ;;
    esac
}

service_disable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl disable nowhere.service ;;
        openrc) rc-update del nowhere default ;;
    esac
}

running_pid() {
    case "$INIT_SYSTEM" in
        systemd)
            pid_property=$(systemctl show --property=MainPID nowhere.service) || return 1
            printf '%s\n' "${pid_property#MainPID=}" ;;
        openrc)
            supervisor_pid=$(cat /run/nowhere.pid) || return 1
            case "$supervisor_pid" in ''|*[!0-9]*) return 1 ;; esac
            children=$(cat "/proc/$supervisor_pid/task/$supervisor_pid/children") || return 1
            for child_pid in $children; do
                case "$child_pid" in *[!0-9]*) continue ;; esac
                child_exe=$(readlink "/proc/$child_pid/exe") || continue
                if [ "$child_exe" = "$BIN" ]; then printf '%s\n' "$child_pid"; return; fi
            done
            return 1 ;;
    esac
}

verify_running() {
    # Detect crash loops too: the actual child must retain its PID throughout.
    check_pid=
    check_i=0
    while [ "$check_i" -lt 5 ]; do
        sleep 1
        service_active || return 1
        current_pid=$(running_pid) || return 1
        case "$current_pid" in ''|0|*[!0-9]*) return 1 ;; esac
        [ -z "$check_pid" ] || [ "$check_pid" = "$current_pid" ] || return 1
        check_pid=$current_pid
        check_i=$((check_i + 1))
    done
}

require_managed() {
    [ -f "$CONF_DIR/managed-by" ] && [ "$(cat "$CONF_DIR/managed-by")" = nowhere-interactive-v1 ] ||
        die '未找到本脚本管理的安装，请先选择安装。'
}

check_conflicts() {
    if [ -e "$CONF_DIR/managed-by" ]; then require_managed; return; fi
    for owned_path in "$BIN" "$MANAGER" "$RUNNER" "$CONF_DIR" "$UNIT" "$INIT"; do
        if [ -e "$owned_path" ] || [ -L "$owned_path" ]; then
            die "发现已有文件 $owned_path；为避免覆盖其他安装，请先迁移或移除冲突文件。"
        fi
    done
}

atomic_copy() {
    # Same-filesystem rename also works while the old executable is running.
    cp "$1" "$2.new"
    chmod "$3" "$2.new"
    mv -f "$2.new" "$2"
}

begin_transaction() {
    mkdir "$WORK_DIR/backup"
    for item in service.url client.url cert.pem key.pem version; do
        if [ -f "$CONF_DIR/$item" ]; then cp -p "$CONF_DIR/$item" "$WORK_DIR/backup/$item"; fi
    done
    [ ! -f "$BIN" ] || cp -p "$BIN" "$WORK_DIR/backup/nowhere"
    WAS_ACTIVE=0
    if service_active; then WAS_ACTIVE=1; fi
    ROLLBACK_PENDING=1
}

rollback() {
    warn '操作失败，正在恢复之前的程序和配置。'
    service_do stop >/dev/null 2>&1 || :
    for item in service.url client.url cert.pem key.pem version; do
        if [ -f "$WORK_DIR/backup/$item" ]; then
            atomic_copy "$WORK_DIR/backup/$item" "$CONF_DIR/$item" 600 || return 1
        else
            rm -f "$CONF_DIR/$item" "$CONF_DIR/$item.new" || return 1
        fi
    done
    if [ -f "$WORK_DIR/backup/nowhere" ]; then
        atomic_copy "$WORK_DIR/backup/nowhere" "$BIN" 755 || return 1
    else
        rm -f "$BIN" "$BIN.new" || return 1
        service_disable >/dev/null 2>&1 || :
    fi
    if [ "$WAS_ACTIVE" -eq 1 ]; then
        service_do start && verify_running || return 1
    fi
}

cleanup() {
    cleanup_status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$ROLLBACK_PENDING" -eq 1 ]; then
        if ! rollback; then
            warn "自动恢复未完成。备份保留在 $WORK_DIR/backup，请检查服务日志。"
            WORK_DIR=
        fi
        cleanup_status=1
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
    if [ "$LOCK_HELD" -eq 1 ]; then rm -f "$LOCK/pid"; rmdir "$LOCK"; fi
    exit "$cleanup_status"
}

select_release() {
    ask '安装版本（latest 为最新正式版，或输入 v1.8.3）' latest
    release_input=$REPLY
    case "$release_input" in
        latest) release_api="https://api.github.com/repos/$REPO/releases/latest" ;;
        *)
            printf '%s\n' "$release_input" | LC_ALL=C grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
                die '版本格式应为 v1.8.3；脚本仅选择正式发行版。'
            release_api="https://api.github.com/repos/$REPO/releases/tags/$release_input" ;;
    esac
    say '正在读取官方 GitHub Release 信息……'
    fetch "$release_api" "$WORK_DIR/release.json" || die '获取版本失败，请检查网络、版本号或 GitHub API 限流。'
    RELEASE=$(jq -er '.tag_name | select(type == "string")' "$WORK_DIR/release.json") || die 'Release 缺少版本号。'
    printf '%s\n' "$RELEASE" | LC_ALL=C grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || die 'Release 版本号不合法。'
    jq -e '.draft == false and .prerelease == false' "$WORK_DIR/release.json" >/dev/null || die '不支持草稿或预发布版本。'
    asset="nowhere-$TARGET.tar.gz"
    ASSET_URL=$(jq -er --arg n "$asset" '[.assets[] | select(.name == $n)] | select(length == 1) | .[0].browser_download_url' "$WORK_DIR/release.json") ||
        die "该版本未提供 $asset。"
    ASSET_DIGEST=$(jq -er --arg n "$asset" '.assets[] | select(.name == $n) | .digest | select(type == "string")' "$WORK_DIR/release.json") ||
        die '该安装包缺少官方 SHA-256 元数据，无法校验，请选择较新的发行版。'
    case "$ASSET_DIGEST" in sha256:*) ASSET_DIGEST=${ASSET_DIGEST#sha256:} ;; *) die '不支持的安装包校验算法。' ;; esac
    valid_pin "$ASSET_DIGEST" || die '安装包 SHA-256 格式不合法。'
    [ "$ASSET_URL" = "https://github.com/$REPO/releases/download/$RELEASE/$asset" ] || die '安装包地址不属于预期的官方 Release。'
}

download_binary() {
    say "下载 $RELEASE / $TARGET……"
    fetch "$ASSET_URL" "$WORK_DIR/nowhere.tar.gz" || die '安装包下载失败；现有服务未被替换。'
    actual_digest=$(sha256sum "$WORK_DIR/nowhere.tar.gz")
    actual_digest=${actual_digest%% *}
    [ "$actual_digest" = "$ASSET_DIGEST" ] || die 'SHA-256 校验失败，已拒绝安装。'
    archive_names=$(tar -tzf "$WORK_DIR/nowhere.tar.gz") || die '安装包无法读取。'
    [ "$archive_names" = nowhere ] || die '安装包必须只包含 nowhere 文件。'
    archive_types=$(tar -tvzf "$WORK_DIR/nowhere.tar.gz") || die '安装包无法读取。'
    case "$archive_types" in -*) ;; *) die '安装包中的 nowhere 不是普通文件。' ;; esac
    tar -xOzf "$WORK_DIR/nowhere.tar.gz" nowhere > "$WORK_DIR/nowhere"
    chmod 700 "$WORK_DIR/nowhere"
    elf_magic=$(od -An -tx1 -N4 "$WORK_DIR/nowhere" | tr -d ' \n')
    [ "$elf_magic" = 7f454c46 ] || die '下载文件不是 Linux ELF 可执行程序。'
    "$WORK_DIR/nowhere" --version > "$WORK_DIR/binary-version" 2>&1 || die '安装包无法在本机执行，请检查架构和内核版本。'
    binary_version=$(cat "$WORK_DIR/binary-version")
    case "$binary_version" in "nowhere-$RELEASE "*) ;; *) die '安装包内部版本与所选 Release 不一致。' ;; esac
    say "校验通过：$binary_version"
}

ask_key() {
    while :; do
        ask "$1"
        if [ -n "$REPLY" ]; then SHARED_KEY=$REPLY; break; fi
        if [ "$2" = generate ]; then SHARED_KEY=$(openssl rand -hex 32); break; fi
        warn '客户端密钥必须与 Portal 完全一致。'
    done
    ENCODED_KEY=$(url_encode "$SHARED_KEY")
}

generated_certificate() {
    if [ -s "$CONF_DIR/cert.pem" ] && [ -s "$CONF_DIR/key.pem" ]; then
        cp "$CONF_DIR/cert.pem" "$WORK_DIR/cert.pem"
        cp "$CONF_DIR/key.pem" "$WORK_DIR/key.pem"
        say '复用已保存的证书，保持客户端指纹不变。'
    else
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -subj '/CN=nowhere' -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
            > "$WORK_DIR/openssl.log" 2>&1 || die '生成证书失败。'
    fi
}

detect_public_host() {
    public_host=
    for public_ip_url in https://api.ipify.org https://ifconfig.me/ip; do
        public_candidate=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 8 \
            "$public_ip_url" 2>/dev/null | tr -d ' \r\n' || :)
        if valid_host "$public_candidate"; then
            public_host=$(url_host "$public_candidate")
            return 0
        fi
    done
    return 1
}

reuse_or_generate_key() {
    ENCODED_KEY=
    if [ -s "$CONF_DIR/service.url" ]; then
        ENCODED_KEY=$(sed -n 's#^portal://\([^@]*\)@.*#\1#p' "$CONF_DIR/service.url" | head -n 1)
    fi
    if [ -z "$ENCODED_KEY" ]; then
        SHARED_KEY=$(openssl rand -hex 32)
        ENCODED_KEY=$(url_encode "$SHARED_KEY")
    else
        say '复用已保存的共享密钥。'
    fi
}

certificate_pin() {
    openssl x509 -in "$1" -outform DER -out "$WORK_DIR/cert.der" || die '无法解析证书。'
    CERT_PIN=$(sha256sum "$WORK_DIR/cert.der")
    CERT_PIN=${CERT_PIN%% *}
    valid_pin "$CERT_PIN" || die '无法计算证书指纹。'
}

portal_wizard() {
    say '配置 Portal 服务端：默认同时监听同一端口的 TCP 和 UDP。'
    ask_host '本机监听地址（0.0.0.0 为所有 IPv4；:: 为所有 IPv6）' 0.0.0.0
    listen_host=$REPLY
    ask_port '监听端口' 2000
    listen_port=$REPLY
    ask_host '供客户端连接的公网 IP 或域名（不自动探测）'
    public_host=$REPLY
    ask_key '共享密钥（留空生成 256 位随机密钥）' generate
    say '证书方式：1) 自动生成持久化证书，客户端校验指纹  2) 使用已有 PEM 证书和私钥'
    ask '请选择' 1
    case "$REPLY" in
        1)
            generated_certificate ;;
        2)
            ask '证书链 PEM 文件绝对路径'; cert_source=$REPLY
            ask '私钥 PEM 文件绝对路径'; key_source=$REPLY
            case "$cert_source:$key_source" in /*:/*) ;; *) die '证书和私钥必须使用绝对路径。' ;; esac
            [ -r "$cert_source" ] && [ -r "$key_source" ] || die '证书或私钥不可读。'
            cp "$cert_source" "$WORK_DIR/cert.pem"
            cp "$key_source" "$WORK_DIR/key.pem" ;;
        *) die '无效的证书选项。' ;;
    esac
    openssl x509 -in "$WORK_DIR/cert.pem" -checkend 0 -noout >/dev/null || die '证书已过期或无法解析。'
    openssl x509 -in "$WORK_DIR/cert.pem" -pubkey -noout > "$WORK_DIR/cert.pub"
    openssl pkey -in "$WORK_DIR/key.pem" -passin pass: -pubout > "$WORK_DIR/key.pub" 2>/dev/null || die '私钥无效；无人值守服务需要无密码私钥。'
    cmp -s "$WORK_DIR/cert.pub" "$WORK_DIR/key.pub" || die '证书和私钥不匹配。'
    certificate_pin "$WORK_DIR/cert.pem"
    CONFIG_URL="portal://$ENCODED_KEY@$listen_host:$listen_port?tls=2&crt=$CONF_DIR/cert.pem&key=$CONF_DIR/key.pem&log=info"
    CLIENT_URL="vector://$ENCODED_KEY@$public_host:$listen_port?up=tcp&down=tcp&pin=$CERT_PIN&socks=127.0.0.1:1080&log=info"
    say "将监听 $listen_host:$listen_port（TCP + UDP）。请在主机防火墙及云安全组放行对应端口。"
}

quick_portal_wizard() {
    say '快速安装 Portal：只需输入端口，密钥和证书会自动生成。'
    listen_host=0.0.0.0
    ask_port '监听端口' 2000
    listen_port=$REPLY
    if detect_public_host; then
        say "自动检测到公网地址：$public_host"
    else
        ask_host '客户端连接用的公网 IP 或域名'
        public_host=$REPLY
    fi
    reuse_or_generate_key
    generated_certificate
    openssl x509 -in "$WORK_DIR/cert.pem" -checkend 0 -noout >/dev/null || die '证书已过期或无法解析。'
    openssl x509 -in "$WORK_DIR/cert.pem" -pubkey -noout > "$WORK_DIR/cert.pub"
    openssl pkey -in "$WORK_DIR/key.pem" -passin pass: -pubout > "$WORK_DIR/key.pub" 2>/dev/null || die '私钥无效。'
    cmp -s "$WORK_DIR/cert.pub" "$WORK_DIR/key.pub" || die '证书和私钥不匹配。'
    certificate_pin "$WORK_DIR/cert.pem"
    CONFIG_URL="portal://$ENCODED_KEY@$listen_host:$listen_port?tls=2&crt=$CONF_DIR/cert.pem&key=$CONF_DIR/key.pem&log=info"
    CLIENT_URL="vector://$ENCODED_KEY@$public_host:$listen_port?up=tcp&down=tcp&pin=$CERT_PIN&socks=127.0.0.1:1080&log=info"
    say "Portal 将监听 $listen_host:$listen_port（TCP + UDP）。"
}

ask_transport() {
    while :; do
        ask "$1（tcp / udp / mix）" tcp
        case "$REPLY" in tcp|udp|mix) return ;; *) warn '仅支持 tcp、udp、mix。' ;; esac
    done
}

vector_wizard() {
    say '配置 Vector 客户端：本地 SOCKS5 默认只允许本机访问。'
    ask_host 'Portal IP 或域名'; remote_host=$REPLY
    ask_port 'Portal 端口' 2000; remote_port=$REPLY
    ask_key 'Portal 共享密钥（填写原始密钥，不要填写 URL 编码后的值）' required
    ask_transport '上行协议'; transport_up=$REPLY
    ask_transport '下行协议'; transport_down=$REPLY
    ask_host '本地 SOCKS5 监听 IP' 127.0.0.1; socks_host=$REPLY
    ask_port '本地 SOCKS5 端口' 1080; socks_port=$REPLY
    socks_value="$socks_host:$socks_port"
    case "$socks_host" in
        127.0.0.1|'[::1]') socks_auth=optional ;;
        *) socks_auth=required; say 'SOCKS5 监听非回环地址，必须设置用户名和密码。' ;;
    esac
    if [ "$socks_auth" = required ] || confirm '是否启用 SOCKS5 用户名/密码'; then
        ask 'SOCKS5 用户名'; socks_user=$REPLY
        ask 'SOCKS5 密码'; socks_pass=$REPLY
        [ -n "$socks_user" ] && [ -n "$socks_pass" ] || die 'SOCKS5 用户名和密码不能为空。'
        socks_user_bytes=$(printf '%s' "$socks_user" | wc -c)
        socks_pass_bytes=$(printf '%s' "$socks_pass" | wc -c)
        [ "$socks_user_bytes" -le 255 ] && [ "$socks_pass_bytes" -le 255 ] || die 'SOCKS5 用户名和密码不能超过 255 字节。'
        # Upstream splits the RAW query at : and @, then decodes components once.
        socks_value="$(url_encode "$socks_user"):$(url_encode "$socks_pass")@$socks_value"
    fi
    say '服务端身份校验：1) SHA-256 证书指纹（本脚本生成的 Portal 选此项）  2) CA 证书 + SNI 域名'
    ask '请选择' 1
    case "$REPLY" in
        1)
            ask 'Portal 证书 SHA-256 指纹（64 位十六进制，可带冒号）'
            pin_value=$(printf '%s' "$REPLY" | tr -d ':' | tr 'A-F' 'a-f')
            valid_pin "$pin_value" || die '证书指纹格式错误。'
            tls_query="pin=$pin_value" ;;
        2)
            ask_host '证书对应的 SNI 域名'
            case "$REPLY" in *:*|\[*\]) die 'SNI 应填写证书对应的 DNS 域名。' ;; esac
            [ "$REPLY" != none ] || die 'none 会关闭证书校验，请填写域名。'
            tls_query="sni=$REPLY" ;;
        *) die '无效的校验方式。' ;;
    esac
    CONFIG_URL="vector://$ENCODED_KEY@$remote_host:$remote_port?up=$transport_up&down=$transport_down&$tls_query&socks=$socks_value&log=info"
    CLIENT_URL=
    say "本地 SOCKS5：$socks_host:$socks_port"
}

quick_vector_wizard() {
    say '快速安装 Vector：粘贴 Portal 输出的完整 Vector URL 即可。'
    while :; do
        ask 'Vector URL'
        case "$REPLY" in
            vector://*'@'*'?'*'socks='*) ;;
            *) warn '请粘贴以 vector:// 开头、包含 socks= 的完整 URL。'; continue ;;
        esac
        case "$REPLY" in *[![:print:]]*|*' '*|*'	'*) warn 'URL 不能包含空格或换行。'; continue ;; esac
        [ "${#REPLY}" -le 4096 ] || die 'URL 太长。'
        CONFIG_URL=$REPLY
        CLIENT_URL=
        say 'Vector 将使用 URL 中的 SOCKS5 设置。'
        return
    done
}

configure_wizard() {
    say '一键部署：1) 快速安装 Portal（服务器）  2) 快速安装 Vector（客户端）  3) 高级 Portal  4) 高级 Vector'
    ask '请选择' 1
    case "$REPLY" in
        1) quick_portal_wizard ;;
        2) quick_vector_wizard ;;
        3) portal_wizard ;;
        4) vector_wizard ;;
        *) die '无效的角色选项。' ;;
    esac
    printf '%s\n' "$CONFIG_URL" > "$WORK_DIR/service.url"
    printf '%s\n' "$CLIENT_URL" > "$WORK_DIR/client.url"
}

write_service() {
    mkdir -p "$(dirname "$BIN")" "$(dirname "$MANAGER")" "$(dirname "$RUNNER")" "$CONF_DIR"
    chmod 700 "$CONF_DIR"
    cat > "$WORK_DIR/runner" <<'RUNNER_EOF'
#!/bin/sh
set -eu
umask 077
IFS= read -r config_url < /etc/nowhere/service.url
case "$config_url" in portal://*|vector://*) ;; *) exit 1 ;; esac
export TMPDIR=/tmp
cd /etc/nowhere
exec /usr/local/bin/nowhere "$config_url"
RUNNER_EOF
    atomic_copy "$WORK_DIR/runner" "$RUNNER" 755
    if [ "$INIT_SYSTEM" = systemd ]; then
        cat > "$WORK_DIR/service" <<'SYSTEMD_EOF'
[Unit]
Description=Nowhere Portal / Vector relay
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/local/libexec/nowhere-run
WorkingDirectory=/etc/nowhere
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM
UMask=0077
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
        atomic_copy "$WORK_DIR/service" "$UNIT" 644
        systemctl daemon-reload
    else
        cat > "$WORK_DIR/service" <<'OPENRC_EOF'
#!/sbin/openrc-run
description="Nowhere Portal / Vector relay"
command="/usr/local/libexec/nowhere-run"
supervisor="supervise-daemon"
pidfile="/run/nowhere.pid"
retry="TERM/20/KILL/5"
respawn_delay=3
respawn_max=5
respawn_period=60
output_log="/var/log/nowhere.log"
error_log="/var/log/nowhere.log"
depend() { need net; }
start_pre() {
    checkpath --file --mode 0600 --owner root:root "$output_log"
    ulimit -n 65535 || return 1
}
OPENRC_EOF
        atomic_copy "$WORK_DIR/service" "$INIT" 755
    fi
    if [ -f "$0" ] && [ "$0" != "$MANAGER" ]; then
        atomic_copy "$0" "$MANAGER" 755
    elif [ ! -f "$MANAGER" ]; then
        # When started as curl | sh, fetch a managed copy for later operations.
        fetch "$MANAGER_URL" "$WORK_DIR/manager" || die '无法保存管理脚本，请稍后重新下载脚本。'
        atomic_copy "$WORK_DIR/manager" "$MANAGER" 755
    fi
    printf '%s\n' nowhere-interactive-v1 > "$CONF_DIR/managed-by"
}

apply_config() {
    atomic_copy "$WORK_DIR/service.url" "$CONF_DIR/service.url" 600
    atomic_copy "$WORK_DIR/client.url" "$CONF_DIR/client.url" 600
    if [ -f "$WORK_DIR/cert.pem" ]; then
        atomic_copy "$WORK_DIR/cert.pem" "$CONF_DIR/cert.pem" 600
        atomic_copy "$WORK_DIR/key.pem" "$CONF_DIR/key.pem" 600
    fi
}

start_checked() {
    if service_do start && verify_running; then return; fi
    warn '启动检查失败，最近的服务日志如下：'
    show_logs
    die '请检查端口占用、监听地址、证书或配置。'
}

install_action() {
    make_work; acquire_lock; check_conflicts; detect_arch; ensure_deps
    if [ -s "$CONF_DIR/service.url" ] && [ -x "$BIN" ]; then die '已经安装，请使用更新或重新配置菜单。'; fi
    select_release
    if [ -s "$CONF_DIR/service.url" ] && confirm '发现卸载后保留的配置，是否直接复用'; then
        cp "$CONF_DIR/service.url" "$WORK_DIR/service.url"
        if [ -f "$CONF_DIR/client.url" ]; then cp "$CONF_DIR/client.url" "$WORK_DIR/client.url"; else : > "$WORK_DIR/client.url"; fi
    else
        configure_wizard
    fi
    confirm "确认安装 $RELEASE 并设置开机自启" || return 0
    download_binary
    write_service
    # Failed initial installs remain stopped and inspectable; rerun installation to retry.
    begin_transaction
    atomic_copy "$WORK_DIR/nowhere" "$BIN" 755
    apply_config
    printf '%s\n' "$RELEASE" > "$CONF_DIR/version"
    start_checked
    service_enable
    ROLLBACK_PENDING=0
    say '安装完成，服务已启动并启用开机自启。'
    say "版本：$RELEASE；服务管理：$INIT_SYSTEM；配置目录：$CONF_DIR"
    say "管理命令：sudo $MANAGER"
    if [ -s "$CONF_DIR/client.url" ]; then
        say "Portal 的客户端连接配置已保存到：$CONF_DIR/client.url（权限 600）"
        say '复制下面这条 URL 到客户端，选择“快速安装 Vector”即可：'
        cat "$CONF_DIR/client.url"
    fi
}

update_action() {
    require_managed; make_work; acquire_lock; detect_arch; ensure_deps
    [ -s "$CONF_DIR/service.url" ] || die '配置不存在，请重新安装。'
    select_release
    say "当前版本：$(cat "$CONF_DIR/version" 2>/dev/null || printf '未知')；目标版本：$RELEASE"
    confirm '确认更新（保留证书和连接配置）' || return 0
    download_binary
    begin_transaction
    service_do stop
    atomic_copy "$WORK_DIR/nowhere" "$BIN" 755
    printf '%s\n' "$RELEASE" > "$CONF_DIR/version"
    # Even a previously stopped service is checked, then returned to its previous state.
    start_checked
    if [ "$WAS_ACTIVE" -eq 0 ]; then service_do stop; fi
    ROLLBACK_PENDING=0
    say '更新完成；原有配置、证书和运行状态已保留。'
}

configure_action() {
    require_managed; make_work; acquire_lock; ensure_deps
    [ -x "$BIN" ] || die '程序不存在，请选择安装。'
    configure_wizard
    confirm '确认替换配置并重启服务' || return 0
    begin_transaction
    service_do stop
    apply_config
    start_checked
    ROLLBACK_PENDING=0
    say '配置已更新。'
    show_info
}

show_info() {
    require_managed
    say "版本：$(cat "$CONF_DIR/version" 2>/dev/null || printf '未完成安装')"
    if service_active; then say '状态：运行中'; else say '状态：未运行'; fi
    say "服务管理：$INIT_SYSTEM；配置目录：$CONF_DIR"
    say "管理命令：sudo $MANAGER"
    if [ -s "$CONF_DIR/service.url" ]; then
        # Display secrets only by explicit request at the terminal.
        if confirm '是否显示连接配置（包含共享密钥，请妥善保存）'; then
            say '本机启动 URL：'; cat "$CONF_DIR/service.url"
            if [ -s "$CONF_DIR/client.url" ]; then
                IFS= read -r saved_client < "$CONF_DIR/client.url" || saved_client=
                if [ -n "$saved_client" ]; then say '客户端 URL（在客户端使用）：'; say "$saved_client"; fi
            fi
            if [ -f "$CONF_DIR/cert.pem" ]; then
                openssl x509 -in "$CONF_DIR/cert.pem" -noout -fingerprint -sha256
            fi
        fi
    fi
}

show_logs() {
    case "$INIT_SYSTEM" in
        systemd) journalctl -u nowhere.service -n 80 --no-pager ;;
        openrc) if [ -f "$LOG" ]; then tail -n 80 "$LOG"; else say '暂无日志。'; fi ;;
    esac
}

control_action() {
    require_managed; make_work; acquire_lock
    service_do "$1"
    case "$1" in start|restart) verify_running || die '服务未稳定运行，请查看日志。' ;; esac
    say "服务操作完成：$1"
}

boot_action() {
    require_managed; make_work; acquire_lock
    ask '开机自启：1) 启用  2) 禁用' 1
    case "$REPLY" in 1) service_enable ;; 2) service_disable ;; *) die '无效选项。' ;; esac
}

uninstall_action() {
    require_managed; make_work; acquire_lock
    say "将删除程序、管理脚本和服务文件。配置目录 $CONF_DIR 默认保留。"
    ask '确认卸载请输入 UNINSTALL'
    [ "$REPLY" = UNINSTALL ] || return 0
    purge_config=0
    if confirm '是否同时永久删除配置、密钥、证书及 OpenRC 日志'; then purge_config=1; fi
    if service_active; then service_do stop; fi
    service_disable
    case "$INIT_SYSTEM" in
        systemd) rm -f "$UNIT"; systemctl daemon-reload; systemctl reset-failed nowhere.service >/dev/null 2>&1 || : ;;
        openrc) rm -f "$INIT" ;;
    esac
    rm -f "$BIN" "$MANAGER" "$RUNNER"
    if [ "$purge_config" -eq 1 ]; then
        rm -rf "$CONF_DIR"
        rm -f "$LOG"
        say '卸载完成，配置已删除。'
    else
        say "卸载完成。配置已保留在 $CONF_DIR；再次安装前请备份所需文件。"
    fi
}

run_action() {
    # Keep the menu alive after a failed action WITHOUT disabling errexit in it.
    set +e
    ( set -eu; "$@" )
    action_status=$?
    set -e
    if [ "$action_status" -ne 0 ]; then warn "本次操作未完成（退出码 $action_status）。"; fi
}

usage() {
    cat <<'HELP'
Nowhere 交互式安装管理脚本
用法：sudo sh nowhere.sh [menu|install|update|configure|status|logs|start|stop|restart|boot|uninstall]
默认打开中文菜单。install/update/configure 等命令仍会询问配置和确认。
兼容：x86_64 / ARM64，systemd / OpenRC，POSIX sh。
使用 --help 查看帮助；不支持无人值守静默安装。
HELP
}

main() {
    case "${1:-menu}" in --help|-h|help) usage; return ;; esac
    [ "$#" -le 1 ] || die '参数过多，请使用 --help 查看用法。'
    case "${1:-menu}" in menu|install|update|configure|status|logs|start|stop|restart|boot|uninstall) ;; *) die '未知命令，请使用 --help 查看用法。' ;; esac
    [ "$(uname -s)" = Linux ] || die '该安装脚本只在 Linux 中执行；请复制到 Linux 服务器运行。'
    umask 077
    if [ "$(id -u)" -ne 0 ]; then
        if have sudo && [ -f "$0" ]; then exec sudo sh "$0" "$@"; fi
        die '需要 root 权限，请先保存脚本，然后使用 sudo sh nowhere.sh 运行。'
    fi
    # /dev/tty is separate from stdin, so curl | sudo sh will not swallow prompts.
    if [ -t 0 ]; then
        INPUT_FD=0
    elif ( : < /dev/tty ) 2>/dev/null; then
        exec 3<> /dev/tty
        INPUT_FD=3
    else
        die '需要交互式终端，请通过 SSH 登录后运行；远程命令可使用 ssh -t。'
    fi
    detect_init
    case "${1:-menu}" in
        install) install_action; return ;;
        update) update_action; return ;;
        configure) configure_action; return ;;
        status) show_info; return ;;
        logs) require_managed; show_logs; return ;;
        start|stop|restart) control_action "$1"; return ;;
        boot) boot_action; return ;;
        uninstall) uninstall_action; return ;;
    esac
    while :; do
        say ''
        say '========== Nowhere 安装管理 =========='
        say ' 1. 安装 Portal / Vector'
        say ' 2. 更新 / 安装指定版本'
        say ' 3. 重新配置'
        say ' 4. 状态 / 连接信息'
        say ' 5. 启动'
        say ' 6. 停止'
        say ' 7. 重启'
        say ' 8. 最近 80 行日志'
        say ' 9. 开机自启设置'
        say '10. 卸载'
        say ' 0. 退出'
        ask '请选择' 0
        case "$REPLY" in
            1) run_action install_action ;; 2) run_action update_action ;;
            3) run_action configure_action ;; 4) run_action show_info ;;
            5) run_action control_action start ;; 6) run_action control_action stop ;;
            7) run_action control_action restart ;; 8) run_action require_managed_logs ;;
            9) run_action boot_action ;; 10) run_action uninstall_action ;;
            0) return ;; *) warn '请输入菜单中的编号。' ;;
        esac
    done
}

require_managed_logs() { require_managed; show_logs; }

# Source-only mode is used by the offline regression tests; no installation runs.
if [ "${NOWHERE_TEST_SOURCE_ONLY:-0}" != 1 ]; then main "$@"; fi
