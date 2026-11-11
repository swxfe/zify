#!/bin/sh
set -eu
for arg do
    case "$arg" in */etc/zify/update.json)
        if [ -f "$ZIFY_TEST_ROOT/fail-update-write" ]; then rm -f "$ZIFY_TEST_ROOT/fail-update-write"; exit 91; fi;;
    esac
done
exec "$ZIFY_REAL_MV" "$@"
