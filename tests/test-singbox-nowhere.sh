#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/singbox-nowhere-test.XXXXXX")"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

# Windows development hosts may not have jq in Git Bash. CI/Linux uses the
# system jq; JQ_EXE is an optional path for the local offline test.
if [ -n "${JQ_EXE:-}" ]; then
    PATH="$(dirname -- "$JQ_EXE"):$PATH"
fi
command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { printf 'openssl is required\n' >&2; exit 1; }

export SINGBOXLITE_TEST_SOURCE_ONLY=1
# Source the manager without entering its dependency installer or menu.
. "$SCRIPT_DIR/singbox.sh"

# The test uses isolated ports and does not need to inspect the host's socket
# table. Override the platform-specific probe so Windows Git Bash is quiet.
_check_port_occupied() { return 1; }

SINGBOX_DIR="$TEST_ROOT/state"
SINGBOX_BIN="$TEST_ROOT/missing-sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
RELAY_CONFIG_FILE="$SINGBOX_DIR/relay.json"
METADATA_FILE="$SINGBOX_DIR/metadata.json"
CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
YQ_BINARY="$TEST_ROOT/missing-yq"
mkdir -p "$SINGBOX_DIR"
printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$CONFIG_FILE"
printf '%s\n' '{}' > "$METADATA_FILE"
printf '%s\n' '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$RELAY_CONFIG_FILE"
printf '%s\n' 'proxies: []' > "$CLASH_YAML_FILE"

# The test owns the state lock so atomic helpers do not require a host flock.
export SINGBOXLITE_LOCK_HELD=1

# Reproduce the empty relay arrays that break the bundled core's merge filter.
merge_fixture="$TEST_ROOT/merge.json"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"},"experimental":{"items":[]}}' > "$merge_fixture"
_normalize_nowhere_merge_config_locked "$merge_fixture"
jq -e 'has("inbounds") == false and .outbounds == [{"type":"direct","tag":"direct"}] and .route == {"final":"direct"} and .experimental.items == []' "$merge_fixture" >/dev/null
before=$(cat "$merge_fixture")
_normalize_nowhere_merge_config_locked "$merge_fixture"
[ "$before" = "$(cat "$merge_fixture")" ]
_normalize_nowhere_merge_config_locked "$RELAY_CONFIG_FILE"
jq -e '. == {"route":{}}' "$RELAY_CONFIG_FILE" >/dev/null

server_ip=127.0.0.1
BATCH_MODE=true
BATCH_IP=127.0.0.1
BATCH_PORT=24443
BATCH_NOWHERE_NETWORK=tcp+udp
BATCH_SNI=nowhere.test

output=$(_add_nowhere 2>&1)
printf '%s\n' "$output" | grep -Fq 'vector://' || { printf 'Nowhere vector link was not emitted\n' >&2; exit 1; }
printf '%s\n' "$output" | grep -Fq 'Nowhere 客户端 JSON' || { printf 'Nowhere client JSON was not emitted\n' >&2; exit 1; }

tag="nowhere-in-24443"
jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .type == "nowhere"' "$CONFIG_FILE" >/dev/null
jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .network == ["tcp","udp"]' "$CONFIG_FILE" >/dev/null
jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .tls.enabled == true and .tls.alpn == ["now/1"] and .tls.min_version == "1.3" and .tls.max_version == "1.3"' "$CONFIG_FILE" >/dev/null

cert_path=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .tls.certificate_path' "$CONFIG_FILE")
pin=$(jq -r --arg tag "$tag" '.[$tag].certificatePin' "$METADATA_FILE")
actual_pin=$(_cert_sha256_hex "$cert_path")
[ "$pin" = "$actual_pin" ] || { printf 'certificate pin mismatch\n' >&2; exit 1; }
jq -e --arg tag "$tag" '.[$tag].yaml == false and .[$tag].variant == "nowhere"' "$METADATA_FILE" >/dev/null
jq -e --arg tag "$tag" --arg pin "$pin" '.[$tag].clientConfig.type == "nowhere" and .[$tag].clientConfig.up == "mix" and .[$tag].clientConfig.down == "mix" and .[$tag].clientConfig.pin == $pin' "$METADATA_FILE" >/dev/null
jq -r --arg tag "$tag" '.[$tag].share_link' "$METADATA_FILE" | grep -Fq 'socks=127.0.0.1:1080'

_detect_main_node_variant "$tag" | grep -Fxq nowhere
_check_port_in_singbox_file "$CONFIG_FILE" 24443 tcp
_check_port_in_singbox_file "$CONFIG_FILE" 24443 udp
if _check_port_in_singbox_file "$CONFIG_FILE" 24443 tcp "$tag"; then
    printf 'excluded Nowhere tag still reported as a conflict\n' >&2
    exit 1
fi

# Rebuilding artifacts after a certificate/SNI change must refresh the pin and
# the native client configuration instead of leaving the old fingerprint.
new_cert="$SINGBOX_DIR/${tag}.replacement.pem"
new_key="$SINGBOX_DIR/${tag}.replacement.key"
_generate_self_signed_cert changed.test "$new_cert" "$new_key" >/dev/null
_atomic_modify_json "$CONFIG_FILE" '(.inbounds[] | select(.tag == $tag) | .tls.server_name) = $sni | (.inbounds[] | select(.tag == $tag) | .tls.certificate_path) = $cert | (.inbounds[] | select(.tag == $tag) | .tls.key_path) = $key' \
    --arg tag "$tag" --arg sni changed.test --arg cert "$new_cert" --arg key "$new_key"
_refresh_modified_node_artifacts "$tag" ""
new_pin=$(jq -r --arg tag "$tag" '.[$tag].certificatePin' "$METADATA_FILE")
[ "$new_pin" = "$(_cert_sha256_hex "$new_cert")" ] || { printf 'updated certificate pin mismatch\n' >&2; exit 1; }
[ "$new_pin" != "$pin" ] || { printf 'certificate pin did not change\n' >&2; exit 1; }
jq -e --arg tag "$tag" --arg pin "$new_pin" '.[$tag].clientConfig.pin == $pin and .[$tag].clientConfig.tls.server_name == "changed.test"' "$METADATA_FILE" >/dev/null

BATCH_PORT=24444
BATCH_NOWHERE_NETWORK=udp
_add_nowhere >/dev/null
jq -e '.inbounds[] | select(.tag == "nowhere-in-24444") | .network == ["udp"]' "$CONFIG_FILE" >/dev/null
jq -e '."nowhere-in-24444".carrier == "udp"' "$METADATA_FILE" >/dev/null

printf 'Nowhere source tests passed\n'
