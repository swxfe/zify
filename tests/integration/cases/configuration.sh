#!/bin/sh
set -eu
# Atomic writes retain permissions without invoking stat, and a failed read cannot publish.
mkdir -p "$ZIFY_TEST_ROOT/etc/zify"
modefile=$ZIFY_TEST_ROOT/etc/zify/mode-test.txt
printf 'before\n' > "$modefile"
chmod 640 "$modefile"
metadata() {
    ucode -S -e 'import * as fs from "fs"; let s=fs.stat(ARGV[0]); printf("%d %d %d", s.mode, s.uid, s.gid);' -- "$modefile"
}
mode_before=$(metadata)
printf 'after\n' > "$work/mode-input"
sh src/shell/backend.sh state-write "$ZIFY_TEST_ROOT" zapret "$work/mode-input" mode-test.txt
[ "$(metadata)" = "$mode_before" ]
equal_file "$modefile" "$work/mode-input"
bad sh src/shell/backend.sh state-write "$ZIFY_TEST_ROOT" zapret "$work/missing-input" mode-test.txt
equal_file "$modefile" "$work/mode-input"
conf=$ZIFY_TEST_ROOT/etc/config/zapret
hosts=$ZIFY_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user.txt
printf 'original.example\n' > "$hosts"
cli status | grep -q stopped
cli service start
cli status | grep -q running
ucode -S -L "$ZIFY_HOME/src/lib" tests/integration/session-cache.uc "$work/manager"
# Missing and empty UCI options both mean no strategy, not a read failure.
sh tools/bundle.sh >/dev/null
cp "$ZIFY_TEST_ROOT/service-actions" "$work/noop-actions.before"
cp "$conf" "$work/noop-config.before"
cli config set DISABLE_IPV6 1
bad cli config set NFQWS_PORTS_TCP 999999
equal_file "$conf" "$work/noop-config.before"
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/noop-actions.before"
for malformed in '1 ' '1
'; do
    uci -c "$ZIFY_TEST_ROOT/etc/config" set "zapret.@main[0].DISABLE_IPV6=$malformed"
    uci -c "$ZIFY_TEST_ROOT/etc/config" commit zapret
    cli config set DISABLE_IPV6 1
    actual=$(cli config get DISABLE_IPV6 && printf x)
    [ "$actual" = "$(printf '1\nx')" ]
done
cp "$conf" "$work/noop-config.before"
# A bad later key cannot leave an earlier batch entry staged or committed.
bad sh src/shell/backend.sh config-set "$ZIFY_TEST_ROOT" zapret DISABLE_IPV6 0 'bad.key' 1
equal_file "$conf" "$work/noop-config.before"
cp "$conf" "$work/option.before"
uci -c "$ZIFY_TEST_ROOT/etc/config" delete 'zapret.@main[0].NFQWS_OPT'
uci -c "$ZIFY_TEST_ROOT/etc/config" commit zapret
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/empty-option.out"
grep -q '    Стратегия: не выбрана$' "$work/empty-option.out"
uci -c "$ZIFY_TEST_ROOT/etc/config" set 'zapret.@main[0].NFQWS_OPT='
uci -c "$ZIFY_TEST_ROOT/etc/config" commit zapret
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/empty-option.out"
grep -q '    Стратегия: не выбрана$' "$work/empty-option.out"
cp "$work/option.before" "$conf"
cli config set DISABLE_IPV6 0
[ "$(cli config get DISABLE_IPV6)" = 0 ]
# Selective removal requires an explicit choice and confirmation; n/Enter preserve state.
for answer in n ''; do
    printf '1\n4\n3\n\n%s\nq\nq\nq\n' "$answer" | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/cancel.out"
    grep -q 'Y — подтвердить' "$work/cancel.out"
    if grep -q 'Установить Zapret' "$work/cancel.out"; then exit 1; fi
done
[ -f "$conf" ]
bad cli config set DISABLE_IPV6 2
bad cli config set NFQWS_PORTS_TCP 65536
bad cli config set NFQWS_PORTS_TCP 500-10
fixture_snapshot valid-ports
printf '%s\n' '--filter-tcp=80,443,2000-3000' '--dpi-desync=fake' > "$work/valid-ports.txt"
cli strategy import "$work/valid-ports.txt"
cli config get NFQWS_PORTS_TCP | grep -q '2000-3000'
fixture_restore valid-ports
