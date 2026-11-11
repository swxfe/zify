#!/bin/sh
set -eu
backend() { /bin/sh "$ZIFY_HOME/src/shell/backend.sh" "$1" "$ZIFY_TEST_ROOT" zapret "$ZIFY_SAFETY_INPUT" "${2:-}"; }
step=${ZIFY_SAFETY_STEP:-}
if [ "${ZIFY_NATIVE_ATOM:-0}" = 1 ]; then step=''; fi
case "$step" in
dynamic-abort) backend state-write exported.txt; exit 73;;
asset-abort|asset-commit)
    backend asset-file "$ZIFY_TEST_ROOT/opt/zapret/fakes/test.bin"
    [ "$ZIFY_SAFETY_STEP" != asset-abort ] || exit 73
    exit 0;;
manager-abort)
    backend manager-install "$ZIFY_TEST_ROOT"
    backend manager-config-init "$ZIFY_TEST_ROOT"
    exit 73;;
update-abort|update-commit)
    backend state-write update.json
    [ "$ZIFY_SAFETY_STEP" != update-abort ] || exit 73
    exit 0;;
update-signal)
    backend state-write update.json
    : > "$ZIFY_TEST_ROOT/update-published"
    sleep 2
    exit 0;;
esac
exec "$ZIFY_REAL_UCODE" "$@"
