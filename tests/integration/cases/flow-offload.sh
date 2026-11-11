#!/bin/sh
set -eu
# FLOWOFFLOAD uses upstream's selective implementation, never global flowtables.
cli service start
cp "$conf" "$work/flow-zapret.before"
cp "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/flow-firewall.before"
cp "$ZIFY_TEST_ROOT/service-actions" "$work/flow-service.before"
bad cli network offload software
equal_file "$conf" "$work/flow-zapret.before"
equal_file "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/flow-firewall.before"
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/flow-service.before"
[ ! -e "$ZIFY_TEST_ROOT/etc/zify/offload.previous" ]
mkdir -p "$ZIFY_TEST_ROOT/opt/zapret/common"
printf '#!/bin/sh\nsync_param() { :; }\nsync_param FLOWOFFLOAD\n' > "$ZIFY_TEST_ROOT/opt/zapret/sync_config.sh"
printf 'nft_apply_flow_offloading() { :; }\n' > "$ZIFY_TEST_ROOT/opt/zapret/common/nft.sh"
cli network offload software
[ "$(cli config get FLOWOFFLOAD)" = software ]
[ "$(uci -c "$ZIFY_TEST_ROOT/etc/config" get 'firewall.@defaults[0].flow_offloading')" = 0 ]
[ "$(uci -c "$ZIFY_TEST_ROOT/etc/config" get 'firewall.@defaults[0].flow_offloading_hw')" = 0 ]
[ "$(tail -n 1 "$ZIFY_TEST_ROOT/service-actions")" = restart ]
cp "$ZIFY_TEST_ROOT/service-actions" "$work/flow-noop-service"
cp "$ZIFY_TEST_ROOT/firewall-actions" "$work/flow-noop-firewall"
cli network offload software
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/flow-noop-service"
equal_file "$ZIFY_TEST_ROOT/firewall-actions" "$work/flow-noop-firewall"
cli network offload hardware
[ "$(cli config get FLOWOFFLOAD)" = hardware ]
# Only a change in global options warrants a full firewall restart.
equal_file "$ZIFY_TEST_ROOT/firewall-actions" "$work/flow-noop-firewall"
cp "$conf" "$work/flow-hardware.before"
touch "$ZIFY_TEST_ROOT/fail-restart"
bad cli network offload none
equal_file "$conf" "$work/flow-hardware.before"
cli network offload restore
[ ! -e "$ZIFY_TEST_ROOT/etc/zify/offload.previous" ]
equal_file "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/flow-firewall.before"
# UCI may normalize whitespace; restoring an absent option must really delete it.
if uci -c "$ZIFY_TEST_ROOT/etc/config" -q get 'zapret.@main[0].FLOWOFFLOAD'; then exit 1; fi
cli service stop
cp "$ZIFY_TEST_ROOT/service-actions" "$work/flow-stopped.before"
cli network offload none
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/flow-stopped.before"
[ ! -e "$ZIFY_TEST_ROOT/state" ]
cp "$conf" "$work/flow-none.before"
cp "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/flow-none-firewall.before"
touch "$ZIFY_TEST_ROOT/fail-firewall"
bad cli network offload restore
equal_file "$conf" "$work/flow-none.before"
equal_file "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/flow-none-firewall.before"
[ -s "$ZIFY_TEST_ROOT/etc/zify/offload.previous" ]
cli network offload donttouch
[ "$(cli config get FLOWOFFLOAD)" = donttouch ]
equal_file "$ZIFY_TEST_ROOT/etc/config/firewall" "$work/flow-none-firewall.before"
cli network offload restore
# Empty upstream values survive a round trip; removal of the package config does not block restoring global flags.
uci -c "$ZIFY_TEST_ROOT/etc/config" set 'zapret.@main[0].FLOWOFFLOAD='
uci -c "$ZIFY_TEST_ROOT/etc/config" commit zapret
cli network offload software
cli network offload restore
[ "$(uci -c "$ZIFY_TEST_ROOT/etc/config" get 'zapret.@main[0].FLOWOFFLOAD')" = '' ]
cli network offload none
mv "$conf" "$work/removed-zapret-config"
cli network offload restore
[ ! -e "$conf" ]
[ ! -e "$ZIFY_TEST_ROOT/etc/zify/offload.previous" ]
mv "$work/removed-zapret-config" "$conf"
uci -c "$ZIFY_TEST_ROOT/etc/config" delete 'zapret.@main[0].FLOWOFFLOAD'
uci -c "$ZIFY_TEST_ROOT/etc/config" commit zapret
cli service start
printf '%s\n' 'flow: upstream modes, capability checks, no-op, stopped service and failure rollback OK'
