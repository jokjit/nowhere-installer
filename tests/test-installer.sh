#!/bin/sh
# Offline behavior tests. All installer writes are redirected into a temp tree.
# Tests intentionally pass literal shell metacharacters, never expansions.
# shellcheck disable=SC2016,SC2329
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
NOWHERE_TEST_SOURCE_ONLY=1
export NOWHERE_TEST_SOURCE_ONLY
# Git for Windows path conversion is adjusted per test shell below.
# shellcheck source=../nowhere.sh
. "$SCRIPT_DIR/nowhere.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 130' INT TERM
passed=0

assert_eq() { [ "$1" = "$2" ] || { printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }; }
assert_has() { grep -F -- "$2" "$1" >/dev/null || { printf 'Missing <%s> in %s\n' "$2" "$1" >&2; exit 1; }; }

# Run assertions as simple commands in a fresh shell so errexit stays enabled.
if [ "${1:-}" = --case ]; then
    case_name=$2
    CONF_DIR=$TEST_ROOT/etc/nowhere
    BIN=$TEST_ROOT/bin/nowhere
    MANAGER=$TEST_ROOT/sbin/nowhere-manager
    RUNNER=$TEST_ROOT/libexec/nowhere-run
    UNIT=$TEST_ROOT/nowhere.service
    INIT=$TEST_ROOT/nowhere.openrc
    LOG=$TEST_ROOT/nowhere.log
    LOCK=$TEST_ROOT/install.lock
    WORK_DIR=$TEST_ROOT/work
    mkdir -p "$CONF_DIR" "$WORK_DIR" "$(dirname "$BIN")"
    INIT_SYSTEM=systemd
    # Git for Windows bundles a native OpenSSL that emits CRLF for `rand`.
    # Normalize only that host-tool output; Linux tests use OpenSSL unchanged.
    case "$(uname -s)" in
        MINGW*|MSYS*)
            MSYS2_ARG_CONV_EXCL='/CN='; export MSYS2_ARG_CONV_EXCL
            openssl() {
                if [ "$1" = rand ]; then
                    command openssl "$@" > "$TEST_ROOT/rand-output" || return 1
                    tr -d '\r' < "$TEST_ROOT/rand-output"
                else command openssl "$@"; fi
            } ;;
    esac

    case "$case_name" in
        ports)
            for p in 1 80 443 2000 65535; do valid_port "$p"; done
            for p in 0 00 08 65536 9999999999999999999999 -1 2.5 '20;id' ''; do
                if valid_port "$p"; then exit 1; fi
            done ;;
        hosts)
            for host in localhost relay.example 192.0.2.1 ::1 '[2001:db8::1]'; do valid_host "$host"; done
            for host in '' 'bad/path' 'bad host' 'a@b' 'a?x=1' '*.example' '$(id)' 'a#b' '[bad' 'ab]'; do
                if valid_host "$host"; then exit 1; fi
            done
            assert_eq "$(url_host 2001:db8::1)" '[2001:db8::1]'
            assert_eq "$(url_host '[::1]')" '[::1]' ;;
        encoding)
            assert_eq "$(url_encode 'a@b:p &+%/#?=$')" 'a%40b%3Ap%20%26%2B%25%2F%23%3F%3D%24'
            assert_eq "$(url_encode '密钥')" '%E5%AF%86%E9%92%A5'
            assert_eq "$(url_encode '-._~AZaz09')" '-._~AZaz09' ;;
        architectures)
            detect_arch x86_64; assert_eq "$TARGET" x86_64-unknown-linux-musl
            detect_arch arm64; assert_eq "$TARGET" aarch64-unknown-linux-musl
            if (detect_arch armv7l) 2>/dev/null; then exit 1; fi ;;
        pins)
            valid_pin aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            if valid_pin nope; then exit 1; fi
            if valid_pin gaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then exit 1; fi ;;
        no_eval)
            key='$(touch SHOULD_NOT_EXIST);`id` & ${HOME}'
            encoded=$(url_encode "$key")
            case "$encoded" in *'%24%28touch%20SHOULD_NOT_EXIST%29'*) ;; *) exit 1 ;; esac
            [ ! -e SHOULD_NOT_EXIST ] ;;
        input_fd)
            printf 'correct\n' > "$TEST_ROOT/input"
            exec 3< "$TEST_ROOT/input"
            INPUT_FD=3
            ask test < /dev/null
            assert_eq "$REPLY" correct ;;
        eof)
            if (ask test < /dev/null) 2>/dev/null; then exit 1; fi ;;
        vector_wizard)
            vector_wizard <<'INPUT'
2001:db8::1
443
a@b:&+%

tcp
udp
0.0.0.0
1080
u@:x
p&+:%
1
AA:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

INPUT
            case "$CONFIG_URL" in
                'vector://a%40b%3A%26%2B%25@[2001:db8::1]:443?'*) ;; *) exit 1 ;;
            esac
            printf '%s\n' "$CONFIG_URL" > "$TEST_ROOT/url"
            assert_has "$TEST_ROOT/url" '&socks=u%40%3Ax:p%26%2B%3A%25@0.0.0.0:1080&'
            assert_has "$TEST_ROOT/url" '&pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&' ;;
        vector_sni)
            vector_wizard <<'INPUT'
relay.example
2000
secret

mix
mix
127.0.0.1
1080
n
2
relay.example

INPUT
            printf '%s\n' "$CONFIG_URL" > "$TEST_ROOT/url"
            assert_has "$TEST_ROOT/url" '&sni=relay.example&socks=127.0.0.1:1080&' ;;
        quick_vector)
            quick_vector_wizard <<'INPUT'
2
vector://secret@relay.example:2000?up=tcp&down=tcp&pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&socks=127.0.0.1:1080&log=info
INPUT
            assert_eq "$CONFIG_URL" 'vector://secret@relay.example:2000?up=tcp&down=tcp&pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&socks=127.0.0.1:1080&log=info'
            [ -z "$CLIENT_URL" ] ;;
        quick_vector_fields)
            quick_vector_wizard <<'INPUT'
1
relay.example
443
secret key
compat-spec
tcp
relay.example
now/1
INPUT
            assert_eq "$CONFIG_URL" 'vector://secret%20key@relay.example:443?up=tcp&down=tcp&sni=relay.example&alpn=now%2F1&socks=127.0.0.1:1080&log=info'
            [ -z "$CLIENT_URL" ]
            quick_vector_wizard <<'INPUT'
1
relay.example
443
secret

udp

aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

INPUT
            assert_eq "$CONFIG_URL" 'vector://secret@relay.example:443?up=udp&down=udp&pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&socks=127.0.0.1:1080&log=info' ;;
        quick_portal)
            detect_public_host() { public_host=203.0.113.9; return 0; }
            generated_certificate() { printf 'test-cert\n' > "$WORK_DIR/cert.pem"; printf 'test-key\n' > "$WORK_DIR/key.pem"; }
            certificate_pin() { CERT_PIN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
            openssl() { if [ "$1" = rand ]; then printf '%064d\n' 1; else return 0; fi; }
            quick_portal_wizard <<'INPUT'
2000
INPUT
            case "$CONFIG_URL" in portal://*'@0.0.0.0:2000?tls=2&crt='*) ;; *) exit 1 ;; esac
            case "$CLIENT_URL" in vector://*'@203.0.113.9:2000?up=tcp&down=tcp&pin='*) ;; *) exit 1 ;; esac
            valid_pin "$CERT_PIN"
            [ -s "$WORK_DIR/cert.pem" ] ;;
        portal_certificate)
            generated_certificate() { printf '%s\n' 'BEGIN CERTIFICATE' > "$WORK_DIR/cert.pem"; printf 'test-key\n' > "$WORK_DIR/key.pem"; }
            certificate_pin() { CERT_PIN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
            openssl() { if [ "$1" = rand ]; then printf '%064d\n' 1; else return 0; fi; }
            cmp() { return 0; }
            portal_wizard <<'INPUT'
127.0.0.1
2000
relay.example

1
INPUT
            [ "${#SHARED_KEY}" -eq 64 ]
            valid_pin "$CERT_PIN"
            printf '%s\n' "$CONFIG_URL" > "$TEST_ROOT/url"
            assert_has "$TEST_ROOT/url" '?tls=2&crt='
            assert_has "$WORK_DIR/cert.pem" 'BEGIN CERTIFICATE'
            first_pin=$CERT_PIN
            cp "$WORK_DIR/cert.pem" "$CONF_DIR/cert.pem"
            cp "$WORK_DIR/key.pem" "$CONF_DIR/key.pem"
            portal_wizard <<'INPUT'
127.0.0.1
2000
relay.example
secret
1
INPUT
            assert_eq "$CERT_PIN" "$first_pin" ;;
        systemd_template|openrc_template)
            systemctl() { printf '%s\n' "$*" >> "$TEST_ROOT/service-calls"; }
            if [ "$case_name" = openrc_template ]; then INIT_SYSTEM=openrc; fi
            write_service
            assert_has "$RUNNER" 'exec /usr/local/bin/nowhere "$config_url"'
            assert_has "$RUNNER" 'read -r config_url'
            [ "$(cat "$CONF_DIR/managed-by")" = nowhere-interactive-v1 ]
            if [ "$INIT_SYSTEM" = systemd ]; then
                assert_has "$UNIT" 'ExecStart=/usr/local/libexec/nowhere-run'
                assert_has "$UNIT" 'Restart=on-failure'
                assert_has "$TEST_ROOT/service-calls" daemon-reload
            else
                assert_has "$INIT" 'supervisor="supervise-daemon"'
                assert_has "$INIT" 'pidfile="/run/nowhere.pid"'
                assert_has "$INIT" 'retry="TERM/20/KILL/5"'
                sh -n "$INIT"
            fi
            sh -n "$RUNNER" ;;
        rollback_active|rollback_stopped|rollback_failure)
            printf 'old binary\n' > "$BIN"
            printf 'old config\n' > "$CONF_DIR/service.url"
            printf 'old cert\n' > "$CONF_DIR/cert.pem"
            service_active() { [ "$case_name" != rollback_stopped ]; }
            service_do() { printf '%s\n' "$1" >> "$TEST_ROOT/actions"; }
            verify_running() { [ "$case_name" != rollback_failure ]; }
            begin_transaction
            printf 'new binary\n' > "$BIN"
            printf 'new config\n' > "$CONF_DIR/service.url"
            printf 'new key\n' > "$CONF_DIR/key.pem"
            if [ "$case_name" = rollback_failure ]; then
                if rollback; then exit 1; fi
            else
                rollback
            fi
            assert_eq "$(cat "$BIN")" 'old binary'
            assert_eq "$(cat "$CONF_DIR/service.url")" 'old config'
            [ ! -f "$CONF_DIR/key.pem" ]
            assert_has "$TEST_ROOT/actions" stop
            if [ "$case_name" != rollback_stopped ]; then assert_has "$TEST_ROOT/actions" start; fi
            ROLLBACK_PENDING=0 ;;
        menu_errexit)
            # shellcheck disable=SC2329
            fail_action() { false; touch "$TEST_ROOT/should-not-exist"; }
            run_action fail_action
            [ ! -f "$TEST_ROOT/should-not-exist" ] ;;
        crash_loop|healthy_service|dead_service)
            sleep() { :; }
            service_active() { [ "$case_name" != dead_service ]; }
            running_pid() {
                if [ "$case_name" = crash_loop ]; then
                    p=$(cat "$TEST_ROOT/pid"); p=$((p + 1)); printf '%s\n' "$p" > "$TEST_ROOT/pid"; printf '%s\n' "$p"
                else printf '101\n'; fi
            }
            printf '100\n' > "$TEST_ROOT/pid"
            if [ "$case_name" = healthy_service ]; then verify_running;
            elif verify_running; then exit 1; fi ;;
        install|update|failed_update|failed_install|reinstall)
            # Exercise real install/update + transaction flow with no package/network/init changes.
            make_work() { trap cleanup EXIT; }
            ensure_deps() { :; }
            select_release() { RELEASE=v1.8.3; }
            confirm() { return 0; }
            show_info() { :; }
            show_logs() { :; }
            systemctl() { :; }
            service_active() { [ -f "$TEST_ROOT/active" ]; }
            service_enable() { touch "$TEST_ROOT/enabled"; }
            service_do() {
                case "$1" in stop) rm -f "$TEST_ROOT/active" ;; start) touch "$TEST_ROOT/active" ;; esac
            }
            verify_running() {
                if [ "$case_name" = failed_update ] || [ "$case_name" = failed_install ]; then
                    [ "$(cat "$BIN")" = old-binary ]
                else service_active; fi
            }
            download_binary() { printf 'new-binary\n' > "$WORK_DIR/nowhere"; }
            configure_wizard() {
                printf 'portal://key@127.0.0.1:2000\n' > "$WORK_DIR/service.url"
                : > "$WORK_DIR/client.url"
            }
            if [ "$case_name" = update ] || [ "$case_name" = failed_update ] || [ "$case_name" = reinstall ]; then
                printf 'nowhere-interactive-v1\n' > "$CONF_DIR/managed-by"
                printf 'old-config\n' > "$CONF_DIR/service.url"
                printf 'v1.8.2\n' > "$CONF_DIR/version"
                if [ "$case_name" != reinstall ]; then
                    printf 'old-binary\n' > "$BIN"; chmod 755 "$BIN"; touch "$TEST_ROOT/active"
                fi
            else
                rmdir "$CONF_DIR"
            fi
            set +e
            (
                set -e
                case "$case_name" in update|failed_update) update_action ;; *) install_action ;; esac
            )
            operation_status=$?
            set -e
            if [ "$case_name" = failed_update ]; then
                [ "$operation_status" -ne 0 ]
                assert_eq "$(cat "$BIN")" old-binary
                assert_eq "$(cat "$CONF_DIR/service.url")" old-config
                [ -f "$TEST_ROOT/active" ]
            elif [ "$case_name" = failed_install ]; then
                [ "$operation_status" -ne 0 ]
                [ ! -f "$BIN" ] && [ ! -f "$CONF_DIR/service.url" ] && [ ! -f "$TEST_ROOT/active" ]
            else
                [ "$operation_status" -eq 0 ]
                assert_eq "$(cat "$BIN")" new-binary
                assert_eq "$(cat "$CONF_DIR/version")" v1.8.3
                if [ "$case_name" = update ] || [ "$case_name" = reinstall ]; then assert_eq "$(cat "$CONF_DIR/service.url")" old-config; fi
            fi
            [ ! -d "$LOCK" ] ;;
        checksum_failure|archive_members|archive_elf)
            RELEASE=v1.8.3; TARGET=x86_64-unknown-linux-musl; ASSET_URL=https://example.invalid/unused
            mkdir "$TEST_ROOT/archive"
            printf '#!/bin/sh\ntouch SHOULD_NOT_RUN\n' > "$TEST_ROOT/archive/nowhere"
            if [ "$case_name" = archive_members ]; then printf 'unexpected\n' > "$TEST_ROOT/archive/extra"; fi
            if [ "$case_name" = archive_members ]; then
                tar -czf "$TEST_ROOT/archive.tar.gz" -C "$TEST_ROOT/archive" nowhere extra
            else tar -czf "$TEST_ROOT/archive.tar.gz" -C "$TEST_ROOT/archive" nowhere; fi
            ASSET_DIGEST=$(sha256sum "$TEST_ROOT/archive.tar.gz"); ASSET_DIGEST=${ASSET_DIGEST%% *}
            if [ "$case_name" = checksum_failure ]; then ASSET_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
            fetch() { cp "$TEST_ROOT/archive.tar.gz" "$2"; }
            if (download_binary) > "$TEST_ROOT/error" 2>&1; then exit 1; fi
            [ ! -e SHOULD_NOT_RUN ]
            case "$case_name" in
                checksum_failure) assert_has "$TEST_ROOT/error" SHA-256 ;;
                archive_members) assert_has "$TEST_ROOT/error" nowhere ;;
                archive_elf) assert_has "$TEST_ROOT/error" ELF ;;
            esac ;;
        deps_apt-get|deps_apk|deps_dnf|deps_yum|deps_zypper|deps_pacman)
            package_manager=${case_name#deps_}
            TEST_PACKAGES=$TEST_ROOT/packages; TEST_READY=$TEST_ROOT/deps-ready
            export TEST_PACKAGES TEST_READY
            have() {
                case "$1" in
                    apt-get|apk|dnf|yum|zypper|pacman) [ "$1" = "$package_manager" ] ;;
                    *) [ -f "$TEST_READY" ] ;;
                esac
            }
            mkdir "$TEST_ROOT/mockbin"
            cat > "$TEST_ROOT/mockbin/$package_manager" <<'PACKAGE'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_PACKAGES"
touch "$TEST_READY"
PACKAGE
            chmod 755 "$TEST_ROOT/mockbin/$package_manager"
            PATH=$TEST_ROOT/mockbin:$PATH
            ensure_deps
            assert_has "$TEST_ROOT/packages" ca-certificates
            assert_has "$TEST_ROOT/packages" openssl
            if [ "$package_manager" = pacman ] && grep -F -- '-Sy' "$TEST_ROOT/packages"; then exit 1; fi ;;
        uninstall_keep|uninstall_purge)
            printf 'nowhere-interactive-v1\n' > "$CONF_DIR/managed-by"
            printf 'saved-config\n' > "$CONF_DIR/service.url"
            mkdir -p "$(dirname "$MANAGER")" "$(dirname "$RUNNER")"
            touch "$BIN" "$MANAGER" "$RUNNER" "$UNIT"
            ask() { REPLY=UNINSTALL; }
            confirm() { [ "$case_name" = uninstall_purge ]; }
            service_active() { return 0; }
            service_do() { :; }
            service_disable() { :; }
            systemctl() { :; }
            (trap cleanup EXIT; uninstall_action)
            [ ! -f "$BIN" ] && [ ! -f "$UNIT" ] && [ ! -f "$MANAGER" ]
            if [ "$case_name" = uninstall_keep ]; then
                assert_eq "$(cat "$CONF_DIR/service.url")" saved-config
            else [ ! -d "$CONF_DIR" ]; fi ;;
        *) printf 'Unknown test: %s\n' "$case_name" >&2; exit 1 ;;
    esac
    exit 0
fi

for case_name in ports hosts encoding architectures pins no_eval input_fd eof \
    vector_wizard vector_sni quick_vector quick_vector_fields quick_portal portal_certificate systemd_template openrc_template \
    rollback_active rollback_stopped rollback_failure menu_errexit crash_loop healthy_service dead_service \
    install update failed_update failed_install reinstall checksum_failure archive_members archive_elf \
    deps_apt-get deps_apk deps_dnf deps_yum deps_zypper deps_pacman uninstall_keep uninstall_purge; do
    if "${TEST_SHELL:-sh}" "$0" --case "$case_name" > "$TEST_ROOT/result" 2>&1; then
        printf 'PASS %s\n' "$case_name"
        passed=$((passed + 1))
    else
        cat "$TEST_ROOT/result"
        printf 'FAIL %s\n' "$case_name" >&2
        exit 1
    fi
done
printf '%s tests passed\n' "$passed"
