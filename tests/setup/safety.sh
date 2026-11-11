#!/bin/sh
set -eu
ZIFY_HOME=$(pwd -P)
ZIFY_HTTP_PROVIDER=$ZIFY_HOME/tests/mocks/http-provider.uc
export ZIFY_HTTP_PROVIDER
ZIFY_REAL_UCODE=$(command -v ucode)
ZIFY_REAL_MV=$(command -v mv)
ZIFY_REAL_MKTEMP=$(command -v mktemp)
sandbox=$(mktemp -d /tmp/zify-safety-XXXXXX)
procd_pid=''
trap 'if [ -n "$procd_pid" ]; then kill "$procd_pid" 2>/dev/null || :; wait "$procd_pid" 2>/dev/null || :; fi; rm -rf -- "$sandbox"' 0
ZIFY_TEST_ROOT=$sandbox/router
export ZIFY_HOME ZIFY_TEST_ROOT ZIFY_REAL_UCODE ZIFY_REAL_MV ZIFY_REAL_MKTEMP
unset ZIFY_TRANSACTION ZIFY_BOOTSTRAP ZIFY_BACKEND
mkdir -p "$sandbox/bin" "$ZIFY_TEST_ROOT/etc/config" "$ZIFY_TEST_ROOT/etc/init.d" "$ZIFY_TEST_ROOT/tmp" "$ZIFY_TEST_ROOT/usr/bin"
sh tests/setup/procd.sh "$ZIFY_TEST_ROOT" &
procd_pid=$!
attempt=0
while [ ! -f "$ZIFY_TEST_ROOT/tmp/procd-ready" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -le 100 ] || exit 1
    sleep 0.01
done
cp tests/mocks/zapret-init.sh "$ZIFY_TEST_ROOT/etc/init.d/zapret"
chmod +x "$ZIFY_TEST_ROOT/etc/init.d/zapret"
printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=443'\n" > "$ZIFY_TEST_ROOT/etc/config/zapret"
cp tests/mocks/id.sh "$sandbox/bin/id"
cp tests/mocks/safety/df.sh "$sandbox/bin/df"
cp tests/mocks/safety/mv.sh "$sandbox/bin/mv"
cp tests/mocks/safety/mktemp.sh "$sandbox/bin/mktemp"
cp tests/mocks/safety/ucode.sh "$sandbox/bin/ucode"
chmod +x "$sandbox/bin/"*
cc -shared -fPIC -Wall -Wextra -Werror tests/mocks/faults.c -ldl -o "$sandbox/faults.so"
LD_PRELOAD=$sandbox/faults.so
export LD_PRELOAD
PATH=$sandbox/bin:$PATH
export PATH
bad() { if "$@" > "$sandbox/error" 2>&1; then printf 'expected failure: %s\n' "$*" >&2; exit 1; fi; }
backend() { sh src/shell/backend.sh "$1" "$ZIFY_TEST_ROOT" zapret "${2:-}" "${3:-}"; }
txn() { sh src/shell/transaction.sh transaction "$ZIFY_TEST_ROOT" zapret version; }
