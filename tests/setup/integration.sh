#!/bin/sh
set -eu
ZIFY_HOME=$(pwd -P)
ZIFY_HTTP_PROVIDER=$ZIFY_HOME/tests/mocks/http-provider.uc
export ZIFY_HOME ZIFY_HTTP_PROVIDER
for tool in ucode uci sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'test: нужен %s\n' "$tool" >&2; exit 1; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/zify-integration-XXXXXX")
procd_pid=''
trap 'if [ -n "$procd_pid" ]; then kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; fi; rm -rf -- "$work"' 0
ZIFY_TEST_ROOT=$work/router
export ZIFY_TEST_ROOT
mkdir -p "$ZIFY_TEST_ROOT/etc/config" "$ZIFY_TEST_ROOT/etc/init.d" "$ZIFY_TEST_ROOT/opt/zapret/ipset" "$ZIFY_TEST_ROOT/tmp" "$work/bin"
sh tests/setup/procd.sh "$ZIFY_TEST_ROOT" &
procd_pid=$!
attempt=0
while [ ! -f "$ZIFY_TEST_ROOT/tmp/procd-ready" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
cat > "$ZIFY_TEST_ROOT/etc/config/zapret" <<'EOF'
config main 'main'
    option NFQWS_OPT '--dpi-desync=fake'
    option DISABLE_IPV6 '1'
    option NFQWS_PORTS_TCP '80,443'
EOF
cc -shared -fPIC -Wall -Wextra -Werror tests/mocks/faults.c -ldl -o "$work/faults.so"
printf "config defaults\n option flow_offloading '0'\n option flow_offloading_hw '0'\n" > "$ZIFY_TEST_ROOT/etc/config/firewall"
cp tests/mocks/zapret-init.sh "$ZIFY_TEST_ROOT/etc/init.d/zapret"
cp tests/mocks/cron.sh "$ZIFY_TEST_ROOT/etc/init.d/cron"
cp tests/mocks/firewall.sh "$ZIFY_TEST_ROOT/etc/init.d/firewall"
cp tests/mocks/curl.sh "$work/bin/curl"
# Only the temporary fixture sees this privilege shim; no host paths are passed to mutations.
cp tests/mocks/id.sh "$work/bin/id"
# Some OpenWrt images omit the stat applet. All writes and rollback must work without it.
cp tests/mocks/missing-stat.sh "$work/bin/stat"
chmod +x "$ZIFY_TEST_ROOT/etc/init.d/"* "$work/bin/"*
PATH=$work/bin:$PATH
export PATH
ucode -S -L "$ZIFY_HOME/src/lib" -D "fixture=$ZIFY_TEST_ROOT" -D "destination=$work/manager" -e '
    import { writefile } from "fs";
    import { default_settings, settings_text } from "settings";
    let c = default_settings();
    c.root = fixture;
    writefile(destination, settings_text(c));
'
if [ "${ZIFY_TEST_BUNDLE:-0}" = 1 ]; then sh tools/bundle.sh >/dev/null; fi
cli_prompt() {
    python3 tests/support/terminal.py sh "$ZIFY_HOME/src/launcher.sh" --config "$work/manager" "$@"
}
cli_raw() { sh "$ZIFY_HOME/src/launcher.sh" --config "$work/manager" "$@"; }
cli() {
    if [ "${ZIFY_TEST_BUNDLE:-0}" = 1 ]; then
        sh "$ZIFY_HOME/dist/zify.sh" --yes --config "$work/manager" "$@"
    else
        sh "$ZIFY_HOME/src/launcher.sh" --yes --config "$work/manager" "$@"
    fi
}
ZIFY_ASSETS_ARCHIVE=${ZIFY_ASSETS_ARCHIVE:-$ZIFY_HOME/.test-tmp/zify-assets-fixture.tar.gz}
export ZIFY_ASSETS_ARCHIVE
if [ ! -f "$ZIFY_ASSETS_ARCHIVE" ]; then python3 tools/build-assets.py --fixtures --output "$ZIFY_ASSETS_ARCHIVE" >/dev/null; fi
cli assets-install "$ZIFY_ASSETS_ARCHIVE" >/dev/null
statefile=$ZIFY_TEST_ROOT/etc/zify/state.json
check_applied() {
    ucode -S -L "$ZIFY_HOME/src/lib" -D "cfg=$work/manager" -e '
        import { settings } from "settings";
        import { configured_strategy } from "status";
        import { read_applied, strategy_hash } from "applied";
        let ctx = settings(getenv("ZIFY_HOME"), cfg), state = read_applied(ctx);
        assert(state != null && state.applied_hash == strategy_hash(configured_strategy(ctx)), "persist exact UCI hash");
        assert(state.applied_at > 0, "persist application timestamp");
    '
}
bad() {
    if "$@" > "$work/error" 2>&1; then
        printf 'expected failure: %s\n' "$*" >&2
        exit 1
    fi
}
equal_file() { cmp "$1" "$2" || { printf 'files differ: %s %s\n' "$1" "$2" >&2; exit 1; }; }

fixture_snapshot() {
    destination=$work/fixture-$1
    mkdir "$destination"
    for name in config state; do
        if [ "$name" = config ]; then path=$ZIFY_TEST_ROOT/etc/config/zapret; else path=$statefile; fi
        if [ -f "$path" ]; then cp -p "$path" "$destination/$name"; else touch "$destination/$name.absent"; fi
    done
}
fixture_restore() {
    destination=$work/fixture-$1
    for name in config state; do
        if [ "$name" = config ]; then path=$ZIFY_TEST_ROOT/etc/config/zapret; else path=$statefile; fi
        if [ -f "$destination/$name" ]; then cp -p "$destination/$name" "$path"; else rm -f "$path"; fi
    done
    cli service restart
}
