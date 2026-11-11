#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/uninstall.sh

uci -c "$ZIFY_TEST_ROOT/etc/config" export zapret > "$work/zapret.original"
cli network offload disable
cli network quic on
printf '7 1 * * * /bin/true # unrelated\n0 4 * * * zify # zify:zapret\n' > "$ZIFY_TEST_ROOT/etc/crontabs/root"
cp -pR "$ZIFY_TEST_ROOT/etc/zify" "$work/state.before"
cp "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/firewall.before"
cp "$ZIFY_TEST_ROOT/etc/config/zapret" "$work/zapret.before"
cp "$ZIFY_TEST_ROOT/etc/crontabs/root" "$work/cron.before"
assert_restored() {
    diff -r "$work/state.before" "$ZIFY_TEST_ROOT/etc/zify"
    cmp "$work/firewall.before" "$ZIFY_TEST_ROOT/etc/config/firewall"
    cmp "$work/zapret.before" "$ZIFY_TEST_ROOT/etc/config/zapret"
    cmp "$work/cron.before" "$ZIFY_TEST_ROOT/etc/crontabs/root"
    test -f "$ZIFY_TEST_ROOT/usr/bin/zify"
    test -f "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
    test -f "$ZIFY_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh"
    test -f "$ZIFY_TEST_ROOT/opt/zapret/files/fake/game.bin"
    test -f "$ZIFY_TEST_ROOT/state"
    test -f "$ZIFY_TEST_ROOT/enabled"
    test ! -d "$ZIFY_TEST_ROOT/tmp/zify.zapret.lock"
}
touch "$ZIFY_TEST_ROOT/fail-firewall"
bad cli uninstall manager
assert_restored
ZIFY_UNINSTALL_FAULT=abort bad cli uninstall manager
assert_restored
ZIFY_UNINSTALL_KIND=all ZIFY_UNINSTALL_FAULT=abort bad cli uninstall manager
assert_restored
ZIFY_UNINSTALL_FAULT=signal cli uninstall manager > "$work/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -f "$ZIFY_TEST_ROOT/cleanup-complete" ] && [ "$attempt" -lt 100 ]; do sleep 0.1; attempt=$((attempt + 1)); done
test -f "$ZIFY_TEST_ROOT/cleanup-complete"
kill -TERM "$(cat "$ZIFY_TEST_ROOT/tmp/zify.zapret.lock/pid")"
if wait "$job"; then printf 'interrupted uninstall passed unexpectedly\n' >&2; exit 1; fi
assert_restored
cli uninstall manager
uci -c "$ZIFY_TEST_ROOT/etc/config" export zapret > "$work/zapret.restored"
cmp "$work/zapret.original" "$work/zapret.restored"
test -f "$ZIFY_TEST_ROOT/opt/zapret/files/fake/game.bin"
test -f "$ZIFY_TEST_ROOT/state"
test -f "$ZIFY_TEST_ROOT/enabled"
test ! -e "$ZIFY_TEST_ROOT/usr/bin/zify"
test ! -e "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
test ! -e "$ZIFY_TEST_ROOT/etc/zify"
test ! -e "$ZIFY_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh"
test "$(uci -c "$ZIFY_TEST_ROOT/etc/config" -q get 'firewall.@defaults[0].flow_offloading')" = 1
test "$(uci -c "$ZIFY_TEST_ROOT/etc/config" -q get 'firewall.@defaults[0].flow_offloading_hw')" = 1
if uci -c "$ZIFY_TEST_ROOT/etc/config" -q get firewall.zify_quic; then exit 1; fi
printf '7 1 * * * /bin/true # unrelated\n' > "$work/cron.expected"
cmp "$work/cron.expected" "$ZIFY_TEST_ROOT/etc/crontabs/root"
cli uninstall manager
# Selectively removing zify preserves its config/backups unless explicitly selected.
mkdir -p "$ZIFY_TEST_ROOT/etc/zify/backups"
printf 'keep me\n' > "$ZIFY_TEST_ROOT/etc/zify/backups/selected.json"
cp data/zify "$ZIFY_TEST_ROOT/etc/config/zify"
printf 'executable\n' > "$ZIFY_TEST_ROOT/usr/bin/zify"
cli uninstall components manager
[ ! -e "$ZIFY_TEST_ROOT/usr/bin/zify" ]
[ -s "$ZIFY_TEST_ROOT/etc/config/zify" ]
[ -s "$ZIFY_TEST_ROOT/etc/zify/backups/selected.json" ]
uci -c "$ZIFY_TEST_ROOT/etc/config" export zapret > "$work/zapret.restored"
cmp "$work/zapret.original" "$work/zapret.restored"
cli uninstall components manager config
[ ! -e "$ZIFY_TEST_ROOT/etc/config/zify" ]
[ ! -e "$ZIFY_TEST_ROOT/etc/zify" ]
[ -s "$ZIFY_TEST_ROOT/opt/zapret/files/fake/game.bin" ]
uci -c "$ZIFY_TEST_ROOT/etc/config" export zapret > "$work/zapret.restored"
cmp "$work/zapret.original" "$work/zapret.restored"
printf '%s\n' 'uninstall: failure/signal rollback, backups, firewall, cron, idempotency and preserved Zapret OK'
