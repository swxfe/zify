#!/bin/sh
set -eu
out='' url='' headers='' code='200' writeout=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2;;
        --dump-header) headers=$2; shift 2;;
        --write-out) writeout=$2; shift 2;;
        --connect-timeout|--max-time|--max-filesize|--max-redirs|--proto|--proto-redir) shift 2;;
        --*) shift;;
        *) url=$1; shift;;
    esac
done
if [ -n "$headers" ]; then
    if [ -f "$ZIFY_TEST_ROOT/api-status" ]; then code=$(cat "$ZIFY_TEST_ROOT/api-status"); fi
    printf 'HTTP/2 %s\r\n' "$code" > "$headers"
    if [ -f "$ZIFY_TEST_ROOT/api-remaining" ]; then
        printf 'X-RateLimit-Remaining: %s\r\n' "$(cat "$ZIFY_TEST_ROOT/api-remaining")" >> "$headers"
    fi
    if [ -n "$writeout" ]; then printf '%s' "$code"; fi
    if [ -f "$ZIFY_TEST_ROOT/api-transport-fail" ]; then exit 28; fi
    if [ -f "$ZIFY_TEST_ROOT/api-body" ]; then cat "$ZIFY_TEST_ROOT/api-body" > "$out"; exit 0; fi
fi
if [ -f "$ZIFY_TEST_ROOT/mock-release" ]; then
    case "$url" in
        https://api.github.com/repos/remittor/zapret-openwrt/releases/latest)
            printf '{"tag_name":"v72.20260307","assets":[]}' > "$out"
            exit 0;;
    esac
fi
case "$url" in
    https://api.github.com/repos/zify-fixture/manager/commits/main)
        [ ! -f "$ZIFY_TEST_ROOT/update-offline" ] || exit 22
        printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
        exit 0;;
    https://raw.githubusercontent.com/zify-fixture/manager/*/dist/zify.sh)
        [ ! -f "$ZIFY_TEST_ROOT/update-offline" ] || exit 22
        cat "$ZIFY_TEST_ROOT/manager-release"
        exit 0;;
esac
if [ -f "$ZIFY_TEST_ROOT/pause-probe" ]; then
    : > "$ZIFY_TEST_ROOT/probe-entered"
    remaining=1000
    while [ -f "$ZIFY_TEST_ROOT/pause-probe" ] && [ "$remaining" -gt 0 ]; do
        sleep 0.01
        remaining=$((remaining - 1))
    done
    [ ! -f "$ZIFY_TEST_ROOT/pause-probe" ] || exit 98
fi
if [ "$out" != /dev/null ]; then
    cat "$ZIFY_TEST_ROOT/download" > "$out"
    exit 0
fi
[ -f "$ZIFY_TEST_ROOT/state" ] || exit 22
opts=$(uci -c "$ZIFY_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT')
case "$opts:$url" in
    *multisplit:*) exit 0;;
    *fake:https://one.test/*) exit 0;;
    *) exit 22;;
esac
