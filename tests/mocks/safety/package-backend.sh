#!/bin/sh
set -eu
case "$1" in
release-install)
    [ -z "${ZIFY_TRANSACTION:-}" ] && [ ! -d "$ZIFY_TEST_ROOT/tmp/zify.zapret.lock" ] || exit 81
    printf 'Package: zapret\nVersion: 72\nStatus: install ok installed\n' > "$ZIFY_TEST_ROOT/usr/lib/opkg/status"
    printf "config main 'main'\n\toption NFQWS_OPT '--filter-tcp=444'\n" > "$ZIFY_TEST_ROOT/etc/config/zapret"
    cp "$ZIFY_TEST_ROOT/etc/config/zapret" "$ZIFY_TEST_ROOT/package-config.before"
    : > "$ZIFY_TEST_ROOT/package-complete";;
call) [ -e "$ZIFY_TEST_ROOT/package-complete" ] || exit 82
    exec /bin/sh "$ZIFY_HOME/src/shell/backend.sh" "$@";;
*) exec /bin/sh "$ZIFY_HOME/src/shell/backend.sh" "$@";; esac
