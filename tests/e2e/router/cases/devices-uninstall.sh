#!/bin/sh
set -eu
devices() {
    zify devices toggle 192.168.1.200
    zify devices list | grep -q 'Исключён 192.168.1.200'
    sh -n /opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh
    nft list table inet zapret | grep -q '192.168.1.200'
    nft -a list chain inet zapret postrouting_hook > "$root/device-rules.before"
    zify devices add 192.168.1.200
    zify devices add 192.168.1.200
    (
        # shellcheck source=/dev/null
        . /opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh
        zapret_custom_firewall_nft
        zapret_custom_firewall_nft
    )
    nft -a list chain inet zapret postrouting_hook > "$root/device-rules.after"
    cmp "$root/device-rules.before" "$root/device-rules.after"
    zify devices clear
    zify devices remove 192.168.1.200
    zify devices remove 192.168.1.200
    health
}
uninstall_manager() {
    zify devices add 192.168.1.200
    zify network quic on
    mkdir -p /etc/zify/backups
    printf legacy > /etc/zify/backups/e2e-uninstall.json
    cp "$conf" "$root/uninstall-config.before"
    zify uninstall manager
    test ! -e /usr/bin/zify
    test ! -e /usr/bin/zify.previous
    test ! -e /etc/zify
    test ! -e /opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh
    cmp "$root/uninstall-config.before" "$conf"
    reject uci -q get firewall.zify_quic
    health
    sh /tmp/zify.sh --yes manager-install /tmp/zify-assets.tar.gz
    test -x /usr/bin/zify
}
