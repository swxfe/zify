#!/bin/sh
set -eu
case "$1" in restart|reload) ;; *) exit 2;; esac
printf '%s\n' "$1" >> "$ZIFY_TEST_ROOT/firewall-actions"
if [ -f "$ZIFY_TEST_ROOT/fail-firewall" ]; then
    rm -f "$ZIFY_TEST_ROOT/fail-firewall"
    exit 1
fi
