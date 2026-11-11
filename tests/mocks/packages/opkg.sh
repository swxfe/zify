#!/bin/sh
set -eu
case "$1" in
info) printf 'Size: 1024\n\n';;
status)
    if [ -f "$ZIFY_PACKAGE_TEST/$2" ]; then printf 'Status: install ok installed\n'; fi;;
remove)
    printf '%s\n' "$*" >> "$ZIFY_PACKAGE_TEST/actions"
    shift
    for pkg do rm -f "$ZIFY_PACKAGE_TEST/$pkg"; done;;
list-upgradable)
    [ ! -f "$ZIFY_PACKAGE_TEST/fail-index" ] || exit 1
    if [ -f "$ZIFY_PACKAGE_TEST/new-core" ]; then printf 'zapret - 71 - 72\n'; fi;;
update) ;;
install|upgrade)
    printf '%s\n' "$*" >> "$ZIFY_PACKAGE_TEST/actions"
    shift
    for pkg in "$@"; do
        case "$pkg" in *luci-app-zapret*) touch "$ZIFY_PACKAGE_TEST/luci-app-zapret";;
            *zapret*) touch "$ZIFY_PACKAGE_TEST/zapret";; esac
    done;;
*) exit 2;;
esac
