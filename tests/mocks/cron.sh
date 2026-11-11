#!/bin/sh
set -eu
[ "$1" = restart ] || exit 2
if [ -f "$ZIFY_TEST_ROOT/fail-cron" ]; then
    rm -f "$ZIFY_TEST_ROOT/fail-cron"
    exit 1
fi
