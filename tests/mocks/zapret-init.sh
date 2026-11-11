#!/bin/sh
set -eu
case "$1" in start|stop|restart|enable|disable) printf '%s\n' "$1" >> "$ZIFY_TEST_ROOT/service-actions";; esac
if [ -f "$ZIFY_TEST_ROOT/noisy-service" ]; then
    printf '%s\n' 'NOISY_SERVICE stdout: Starting daemon /opt/zapret/nfq/nfqws'
    printf '%s\n' 'NOISY_SERVICE stderr: chmod: /opt/zapret/ipset/*.log: No such file or directory' >&2
fi
state=$ZIFY_TEST_ROOT/state
case "$1" in
    running) [ -f "$state" ];;
    enabled) [ -f "$ZIFY_TEST_ROOT/enabled" ];;
    start|restart)
        if [ -f "$ZIFY_TEST_ROOT/fail-restart" ]; then
            rm -f "$ZIFY_TEST_ROOT/fail-restart"
            exit 1
        fi
        : > "$state"
        ;;
    stop)
        if [ -f "$ZIFY_TEST_ROOT/fail-stop" ]; then
            rm -f "$ZIFY_TEST_ROOT/fail-stop" "$state"
            exit 1
        fi
        rm -f "$state"
        ;;
    enable) : > "$ZIFY_TEST_ROOT/enabled";;
    disable) rm -f "$ZIFY_TEST_ROOT/enabled";;
    *) exit 2;;
esac
