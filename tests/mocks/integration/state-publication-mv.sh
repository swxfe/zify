#!/bin/sh
set -eu
for arg do
    case "$arg" in */etc/zify/state.json)
        if [ -e "$ZIFY_TEST_ROOT/fail-state-write" ]; then rm -f "$ZIFY_TEST_ROOT/fail-state-write"; exit 91; fi;;
    esac
done
exec "$ZIFY_REAL_MV" "$@"
