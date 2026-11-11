#!/bin/sh
set -eu
networking() {
    uci export firewall > "$root/firewall-before"
    uci export zapret > "$root/offload-zapret-before"
    zify network offload software
    [ "$(zify config get FLOWOFFLOAD)" = software ]
    [ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 0 ]
    [ "$(uci get 'firewall.@defaults[0].flow_offloading_hw')" = 0 ]
    nft list flowtable inet zapret ft > "$root/software-flowtable"
    nft list table inet zapret > "$root/software-rules"
    grep -q 'flow add @ft' "$root/software-rules"
    grep -q 'queue' "$root/software-rules"
    health
    zify network offload hardware
    [ "$(zify config get FLOWOFFLOAD)" = hardware ]
    nft list flowtable inet zapret ft > "$root/hardware-flowtable"
    grep -q 'flags offload' "$root/hardware-flowtable"
    health
    zify network offload donttouch
    [ "$(zify config get FLOWOFFLOAD)" = donttouch ]
    [ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 0 ]
    zify network offload disable
    [ "$(zify config get FLOWOFFLOAD)" = none ]
    [ "$(uci get 'firewall.@defaults[0].flow_offloading')" = 0 ]
    zify network offload restore
    uci export firewall > "$root/firewall-after"
    cmp "$root/firewall-before" "$root/firewall-after"
    uci export zapret > "$root/offload-zapret-after"
    cmp "$root/offload-zapret-before" "$root/offload-zapret-after"
    zify network quic on
    [ "$(uci get firewall.zify_quic.name)" = ZIFY_Block_QUIC ]
    nft list ruleset | grep -q ZIFY_Block_QUIC
    zify network quic off
    reject uci -q get firewall.zify_quic
    health
}
