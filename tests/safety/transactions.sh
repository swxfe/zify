#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/safety.sh

export ZIFY_FREE_KB=5119
bad backend check-space 0
export ZIFY_FREE_KB=5120
backend check-space 0
export ZIFY_FREE_KB=5319
bad backend check-space 100
export ZIFY_FREE_KB=5320
backend check-space 100
tail -n 1 "$ZIFY_TEST_ROOT/df.calls" | grep -q "$ZIFY_TEST_ROOT$"
mkdir "$ZIFY_TEST_ROOT/overlay"
backend check-space 100
tail -n 1 "$ZIFY_TEST_ROOT/df.calls" | grep -q "$ZIFY_TEST_ROOT/overlay$"
ZIFY_DF_FAIL=1 bad backend check-space 0
export ZIFY_FREE_KB=999999
ZIFY_SAFETY_INPUT=$sandbox/payload
export ZIFY_SAFETY_INPUT
printf 'FAKE\n' > "$ZIFY_SAFETY_INPUT"
ZIFY_SAFETY_STEP=dynamic-abort bad txn
[ ! -e "$ZIFY_TEST_ROOT/etc/zify/exported.txt" ]
printf 'original export\n' > "$ZIFY_TEST_ROOT/etc/zify/exported.txt"
cp -p "$ZIFY_TEST_ROOT/etc/zify/exported.txt" "$sandbox/export.before"
ZIFY_SAFETY_STEP=dynamic-abort bad txn
cmp "$sandbox/export.before" "$ZIFY_TEST_ROOT/etc/zify/exported.txt"
ZIFY_SAFETY_STEP=asset-abort bad txn
[ ! -e "$ZIFY_TEST_ROOT/opt/zapret/fakes/test.bin" ]
ZIFY_SAFETY_STEP=asset-commit txn
cmp "$ZIFY_SAFETY_INPUT" "$ZIFY_TEST_ROOT/opt/zapret/fakes/test.bin"
ZIFY_SAFETY_STEP=asset-abort bad txn
cmp "$ZIFY_SAFETY_INPUT" "$ZIFY_TEST_ROOT/opt/zapret/fakes/test.bin"
printf '#!/bin/sh\nprintf old\n' > "$ZIFY_TEST_ROOT/usr/bin/zify"
printf '#!/bin/sh\nprintf previous\n' > "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
chmod 700 "$ZIFY_TEST_ROOT/usr/bin/zify"
chmod 740 "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
manager_metadata() {
    "$ZIFY_REAL_UCODE" -S -e 'import * as fs from "fs"; for(let path in ARGV) { let s=fs.stat(path); printf("%J\n",[s.mode,s.uid,s.gid,s.mtime]); }' -- \
        "$ZIFY_TEST_ROOT/usr/bin/zify" "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
}
original_metadata=$(manager_metadata)
cp "$ZIFY_TEST_ROOT/usr/bin/zify" "$sandbox/old"
cp "$ZIFY_TEST_ROOT/usr/bin/zify.previous" "$sandbox/previous"
printf '#!/bin/sh\nprintf new\n' > "$ZIFY_SAFETY_INPUT"
ZIFY_SAFETY_STEP=manager-abort bad txn
cmp "$sandbox/old" "$ZIFY_TEST_ROOT/usr/bin/zify"
cmp "$sandbox/previous" "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
[ "$(manager_metadata)" = "$original_metadata" ]
[ ! -e "$ZIFY_TEST_ROOT/etc/config/zify" ]
# Installing identical contents still changes modes; the write journal must restore them.
cp "$sandbox/old" "$ZIFY_SAFETY_INPUT"
ZIFY_SAFETY_STEP=manager-abort bad txn
cmp "$sandbox/old" "$ZIFY_TEST_ROOT/usr/bin/zify"
cmp "$sandbox/previous" "$ZIFY_TEST_ROOT/usr/bin/zify.previous"
[ "$(manager_metadata)" = "$original_metadata" ]
printf '{"before":true}\n' > "$ZIFY_TEST_ROOT/etc/zify/update.json"
cp "$ZIFY_TEST_ROOT/etc/zify/update.json" "$sandbox/update.before"
printf '{"after":true}\n' > "$ZIFY_SAFETY_INPUT"
ZIFY_SAFETY_STEP=update-abort bad txn
cmp "$sandbox/update.before" "$ZIFY_TEST_ROOT/etc/zify/update.json"
touch "$ZIFY_TEST_ROOT/fail-update-write"
ZIFY_SAFETY_STEP=update-abort bad txn
cmp "$sandbox/update.before" "$ZIFY_TEST_ROOT/etc/zify/update.json"
ZIFY_SAFETY_STEP=update-signal txn > "$sandbox/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -e "$ZIFY_TEST_ROOT/update-published" ] && [ "$attempt" -lt 100 ]; do sleep 0.1; attempt=$((attempt + 1)); done
[ -e "$ZIFY_TEST_ROOT/update-published" ]
kill -TERM "$(cat "$ZIFY_TEST_ROOT/tmp/zify.zapret.lock/pid")"
if wait "$job"; then printf 'interrupted update succeeded\n' >&2; exit 1; fi
cmp "$sandbox/update.before" "$ZIFY_TEST_ROOT/etc/zify/update.json"
for temporary in "$ZIFY_TEST_ROOT/etc/zify/".update-*; do [ ! -e "$temporary" ]; done
ZIFY_SAFETY_STEP=update-commit txn
cmp "$ZIFY_SAFETY_INPUT" "$ZIFY_TEST_ROOT/etc/zify/update.json"
for temporary in "$ZIFY_TEST_ROOT/etc/zify/".update-*; do [ ! -e "$temporary" ]; done
unset ZIFY_SAFETY_STEP
# Equal payloads must replace a symlink before chmod, never change its outside target.
hook=$ZIFY_TEST_ROOT/opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh
mkdir -p "$(dirname "$hook")"
cp "$ZIFY_SAFETY_INPUT" "$sandbox/outside-hook"
chmod 600 "$sandbox/outside-hook"
ln -s "$sandbox/outside-hook" "$hook"
backend device-hook-write "$ZIFY_SAFETY_INPUT"
[ ! -L "$hook" ]
"$ZIFY_REAL_UCODE" -S -e 'import * as fs from "fs"; assert((fs.stat(ARGV[0]).mode & 0777) == 0600);' -- "$sandbox/outside-hook"
cmp "$ZIFY_SAFETY_INPUT" "$hook"
# The package shim models a successful external package operation, then a config failure.
"$ZIFY_REAL_UCODE" -S -L "$ZIFY_HOME/src/lib" -D "root=$ZIFY_TEST_ROOT" -D "destination=$sandbox/manager" -e '
    import * as fs from "fs";
    import { default_settings, settings_text } from "settings";
    let c=default_settings(); c.root=root;
    fs.writefile(destination,settings_text(c));
'
mkdir -p "$ZIFY_TEST_ROOT/usr/lib/opkg"
printf 'Package: zapret\nVersion: 71\nStatus: install ok installed\n' > "$ZIFY_TEST_ROOT/usr/lib/opkg/status"
cp tests/mocks/safety/package-backend.sh "$sandbox/package-backend"
ZIFY_SAFETY_BACKEND=$sandbox/package-backend
export ZIFY_SAFETY_BACKEND
ZIFY_BACKEND=$(cat <<'EOF'
exec /bin/sh "$ZIFY_SAFETY_BACKEND" "$@"
EOF
)
export ZIFY_BACKEND
printf "DISTRIB_ARCH='test_arch'\n" > "$ZIFY_TEST_ROOT/etc/openwrt_release"
cat > "$sandbox/package-http.uc" <<'EOF'
function request(url, options) {
    return {status:200, headers:{}, body:sprintf('%J', {tag_name:'v72', assets:[{
        name:'zapret_v72_test_arch.zip', size:1024,
        browser_download_url:'https://github.com/remittor/zapret-openwrt/releases/download/v72/zapret_v72_test_arch.zip'
    }]})};
}; return {request};
EOF
touch "$ZIFY_TEST_ROOT/fail-restart"
bad env ZIFY_HTTP_PROVIDER="$sandbox/package-http.uc" sh src/launcher.sh --yes --config "$sandbox/manager" install-upstream
cmp "$ZIFY_TEST_ROOT/package-config.before" "$ZIFY_TEST_ROOT/etc/config/zapret"
grep -q 'Version: 72' "$ZIFY_TEST_ROOT/usr/lib/opkg/status"
[ ! -d "$ZIFY_TEST_ROOT/tmp/zify.zapret.lock" ]
unset ZIFY_BACKEND
cp tests/mocks/firewall.sh "$ZIFY_TEST_ROOT/etc/init.d/firewall"
chmod +x "$ZIFY_TEST_ROOT/etc/init.d/firewall"
printf "config defaults\n\toption flow_offloading '0'\n\toption flow_offloading_hw '0'\n" > "$ZIFY_TEST_ROOT/etc/config/firewall"
network() { sh src/launcher.sh --yes --config "$sandbox/manager" network "$@"; }
network offload disable
network offload disable
network offload restore
bad network offload restore
if grep -q '^restart$' "$ZIFY_TEST_ROOT/firewall-actions"; then printf 'unchanged offloading must not restart firewall\n' >&2; exit 1; fi
printf '%s\n' 'safety: space thresholds, asset cleanup, manager rollback, update cleanup, and package boundary OK'
