#!/bin/sh
set -eu
noop_update() {
    cp "$conf" "$root/before"
    zify update-upstream > "$root/update"
    grep -q 'Новых версий нет' "$root/update"
    unchanged
}
manager_reinstall() {
    cp "$conf" "$root/before"
    cp /etc/config/zify "$root/manager-before"
    zify manager-install
    test -x /usr/bin/zify
    test -x /usr/bin/zify.previous
    cmp /usr/bin/zify /usr/bin/zify.previous
    cmp "$root/manager-before" /etc/config/zify
    unchanged
}
