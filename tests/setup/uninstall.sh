#!/bin/sh
set -eu
ZIFY_HOME=$(pwd -P)
ZIFY_HTTP_PROVIDER=$ZIFY_HOME/tests/mocks/http-provider.uc
export ZIFY_HTTP_PROVIDER
ZIFY_REAL_UCODE=$(command -v ucode)
work=$(mktemp -d /tmp/zify-uninstall-test.XXXXXX)
procd_pid=''
trap 'if [ -n "$procd_pid" ]; then kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; fi; rm -rf -- "$work"' 0
ZIFY_TEST_ROOT=$work/router
export ZIFY_HOME ZIFY_TEST_ROOT ZIFY_REAL_UCODE
unset ZIFY_TRANSACTION ZIFY_BACKEND ZIFY_BOOTSTRAP
mkdir -p "$work/bin" "$ZIFY_TEST_ROOT/etc/config" "$ZIFY_TEST_ROOT/etc/init.d" \
    "$ZIFY_TEST_ROOT/etc/crontabs" "$ZIFY_TEST_ROOT/etc/zify/backups" \
    "$ZIFY_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d" "$ZIFY_TEST_ROOT/opt/zapret/files/fake" \
    "$ZIFY_TEST_ROOT/usr/bin" "$ZIFY_TEST_ROOT/tmp"
cp tests/mocks/id.sh "$work/bin/id"
cp tests/mocks/uninstall/ucode.sh "$work/bin/ucode"
chmod +x "$work/bin/"*
PATH=$work/bin:$PATH
export PATH
sh tests/setup/procd.sh "$ZIFY_TEST_ROOT" &
procd_pid=$!
attempt=0
while [ ! -f "$ZIFY_TEST_ROOT/tmp/procd-ready" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
for helper in zapret-init cron firewall; do
    if [ "$helper" = zapret-init ]; then target=zapret; else target=$helper; fi
    cp "tests/mocks/$helper.sh" "$ZIFY_TEST_ROOT/etc/init.d/$target"
    chmod +x "$ZIFY_TEST_ROOT/etc/init.d/$target"
done
printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=443'\n" > "$ZIFY_TEST_ROOT/etc/config/zapret"
printf "config defaults\n\toption flow_offloading '1'\n\toption flow_offloading_hw '1'\n" > "$ZIFY_TEST_ROOT/etc/config/firewall"
printf 'fixture executable\n' > "$ZIFY_TEST_ROOT/usr/bin/zify"
printf 'previous executable\n' > "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
printf 'fake payload\n' > "$ZIFY_TEST_ROOT/opt/zapret/files/fake/game.bin"
printf '#!/bin/sh\nset -eu\n' > "$ZIFY_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh"
printf 'backup\n' > "$ZIFY_TEST_ROOT/etc/zify/backups/user.json"
printf '192.168.1.5\n' > "$ZIFY_TEST_ROOT/etc/zify/devices.txt"
touch "$ZIFY_TEST_ROOT/state" "$ZIFY_TEST_ROOT/enabled"
"$ZIFY_REAL_UCODE" -S -L "$ZIFY_HOME/src/lib" -D "root=$ZIFY_TEST_ROOT" -D "destination=$work/config" -e '
    import * as fs from "fs";
    import { default_settings, settings_text } from "settings";
    let c=default_settings(); c.root=root;
    fs.writefile(destination,settings_text(c));
'
cli() { "$ZIFY_REAL_UCODE" -S -L "$ZIFY_HOME/src/lib" -- src/main.uc --yes --config "$work/config" "$@"; }
bad() { if "$@" > "$work/error" 2>&1; then printf 'expected failure: %s\n' "$*" >&2; exit 1; fi; }
