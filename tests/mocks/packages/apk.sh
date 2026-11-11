#!/bin/sh
set -eu
case "$1" in
query) printf '%s\n' '[{"name":"zapret","installed-size":1024,"file-size":512}]';;
info) [ -f "$ZIFY_PACKAGE_TEST/$3" ];;
del)
    printf '%s\n' "$*" >> "$ZIFY_PACKAGE_TEST/actions"
    shift
    for pkg do rm -f "$ZIFY_PACKAGE_TEST/$pkg"; done;;
version) :;;
update) :;;
add|upgrade)
    printf '%s\n' "$*" >> "$ZIFY_PACKAGE_TEST/actions";;
*) exit 2;;
esac
