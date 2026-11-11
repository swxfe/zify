#!/bin/sh
set -eu
if [ "${ZIFY_NATIVE_ATOM:-0}" != 1 ] && [ -n "${ZIFY_TRANSACTION:-}" ] && [ -n "${ZIFY_UNINSTALL_FAULT:-}" ]; then
    sh "$ZIFY_HOME/src/shell/backend.sh" uninstall-cleanup "$ZIFY_TEST_ROOT" zapret "${ZIFY_UNINSTALL_KIND:-manager}"
    if [ "$ZIFY_UNINSTALL_FAULT" = signal ]; then
        touch "$ZIFY_TEST_ROOT/cleanup-complete"
        sleep 2
    fi
    exit 73
fi
exec "$ZIFY_REAL_UCODE" "$@"
