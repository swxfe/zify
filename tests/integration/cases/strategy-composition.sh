#!/bin/sh
set -eu
cli source apply flowseal general
check_applied
cp "$ZIFY_TEST_ROOT/service-actions" "$work/reapply-actions.before"
cli source apply flowseal general
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/reapply-actions.before"
cli config get NFQWS_OPT > "$work/flowseal.opts"
grep -q 'ACTIVE_DISCORD_UDP.bin' "$work/flowseal.opts"
[ "$(grep -c '^#general$' "$work/flowseal.opts")" -eq 1 ]
[ "$(grep -c '^#' "$work/flowseal.opts")" -eq 1 ]
[ "$(grep -c '^--new$' "$work/flowseal.opts")" -eq 4 ]
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '    Стратегия: general$' "$work/flowseal-status.out"
cli config get NFQWS_PORTS_TCP | grep -q 1024-65535
[ -s "$ZIFY_TEST_ROOT/opt/zapret/fakes/ACTIVE_DISCORD_UDP.bin" ]
fixture_snapshot labelled
cli source group manager games Gv1
# Opening the composer while Flowseal is active leaves the live state untouched.
cp "$conf" "$work/blocked-compose-conf.before"
cp "$statefile" "$work/blocked-compose-state.before"
cp "$ZIFY_TEST_ROOT/service-actions" "$work/blocked-compose-actions.before"
printf '3\n2\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/blocked-compose.out"
grep -q 'zify > стратегии > сборка' "$work/blocked-compose.out"
equal_file "$conf" "$work/blocked-compose-conf.before"
equal_file "$statefile" "$work/blocked-compose-state.before"
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/blocked-compose-actions.before"
# Clearing is transactional even when stopping the service partially fails.
touch "$ZIFY_TEST_ROOT/fail-stop"
bad cli strategy clear
equal_file "$conf" "$work/blocked-compose-conf.before"
equal_file "$statefile" "$work/blocked-compose-state.before"
cli status | grep -q running
# The explicit clear button unlocks the composer in the same menu session.
printf '3\n5\ny\n\n2\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/clear-strategy.out"
grep -q 'Стратегия очищена' "$work/clear-strategy.out"
grep -q 'zify > стратегии > сборка' "$work/clear-strategy.out"
if grep -q 'Ошибка:' "$work/clear-strategy.out"; then cat "$work/clear-strategy.out"; exit 1; fi
[ -z "$(uci -c "$ZIFY_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT' || :)" ]
[ "$(cli config get NFQWS_ENABLE)" = 0 ]
cli status | grep -q stopped
check_applied
cp "$conf" "$work/clear-conf.before"
cp "$statefile" "$work/clear-state.before"
cp "$ZIFY_TEST_ROOT/service-actions" "$work/clear-actions.before"
cli strategy clear
equal_file "$conf" "$work/clear-conf.before"
equal_file "$statefile" "$work/clear-state.before"
equal_file "$ZIFY_TEST_ROOT/service-actions" "$work/clear-actions.before"
cli source apply flowseal general
bad cli source compose flowseal base_general base_general
cli source group flowseal base base_general
check_applied
cli config get NFQWS_OPT > "$work/grouped.opts"
grep -q 'hostlist=/opt/zapret/ipset/zapret-hosts-google.txt' "$work/grouped.opts"
[ "$(grep -c '^#general$' "$work/grouped.opts")" -eq 1 ]
[ "$(grep -c '^#base_general$' "$work/grouped.opts")" -eq 1 ]
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '    Стратегия: general + base_general$' "$work/flowseal-status.out"
# Clear Flowseal before composing independent groups; unrelated YouTube stays intact.
cli source remove flowseal
cli source group manager youtube Yv99
# Group editor performs the same transactions and shows the live composition.
printf '3\n2\n1\nq\nq\n1\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/strategy-menu.out"
grep -q 'Базовый трафик.*base_general' "$work/strategy-menu.out"
grep -q 'YouTube.*Yv99' "$work/strategy-menu.out"
grep -q 'general' "$work/strategy-menu.out"
if grep -q 'Ошибка:' "$work/strategy-menu.out"; then cat "$work/strategy-menu.out"; exit 1; fi
# Games are a direct strategy-menu entry and absent from the composer.
printf '3\n3\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/games-menu.out"
grep -q 'zify > стратегии > игры' "$work/games-menu.out"
if grep -q 'Игры:' "$work/strategy-menu.out"; then exit 1; fi
cp "$conf" "$work/cancel-group.before"
printf '3\n2\n1\nq\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/cancel-group.out"
equal_file "$conf" "$work/cancel-group.before"
printf '3\n2\n1\nd\n\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/disable-group.out"
cli config get NFQWS_OPT > "$work/disabled-group.opts"
if grep -q '^#base_general$' "$work/disabled-group.opts"; then exit 1; fi
grep -q '^#Yv99$' "$work/disabled-group.opts"
cli status | grep -q running
# Old ALT9 headings and caches remain usable; games replacement is not a manual edit.
ucode -S -D "file=$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "#general\n", "#general_ALT9_\n");
    fs.writefile(file, sprintf("%J\n", data));
'
cli source apply flowseal general_alt9
cli source group flowseal games games_general
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/alt9.out"
grep -q '    Стратегия: general_alt9 + games_general$' "$work/alt9.out"
cli source remove flowseal
cli config get NFQWS_OPT | grep -q '^#games_general$'
cli source remove flowseal games
[ -z "$(uci -c "$ZIFY_TEST_ROOT/etc/config" -q get 'zapret.@main[0].NFQWS_OPT' || :)" ]
[ "$(cli config get NFQWS_ENABLE)" = 0 ]
cli status | grep -q stopped
# A failed restart restores the empty configuration, disabled nfqws and stopped service.
cp "$conf" "$work/disabled.before"
cp "$statefile" "$work/disabled-state.before"
touch "$ZIFY_TEST_ROOT/fail-restart"
bad cli source group flowseal base base_general
equal_file "$conf" "$work/disabled.before"
equal_file "$statefile" "$work/disabled-state.before"
cli status | grep -q stopped
cli source group flowseal base base_general
[ "$(cli config get NFQWS_ENABLE)" = 1 ]
cli status | grep -q running
# Restore the original cached name for the following independent scenarios.
ucode -S -D "file=$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "#general_ALT9_\n", "#general\n");
    fs.writefile(file, sprintf("%J\n", data));
'

# Native selection follows the prototype: Flowseal/custom switch, explicit games survive.
cli source select manager v98
# Only strategy pickers restore the active item when reopened.
printf '3\n2\n1\nq\n1\nq\nq\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/active-selection.out"
[ "$(grep -c '^  > .*v98.*(активна)' "$work/active-selection.out")" -eq 2 ]
cli source select manager Yv99
cli source select manager Gv1
cli source select flowseal general
cli config get NFQWS_OPT > "$work/native-flow.opts"
grep -q '^#general$' "$work/native-flow.opts"
grep -q '^#Gv1$' "$work/native-flow.opts"
if grep -q '^#v98$\|^#Yv99$' "$work/native-flow.opts"; then exit 1; fi
cli source select manager Yv99
cli config get NFQWS_OPT > "$work/native-custom.opts"
grep -q '^#Yv99$' "$work/native-custom.opts"
grep -q '^#Gv1$' "$work/native-custom.opts"
if grep -q '^#general$' "$work/native-custom.opts"; then exit 1; fi
cli source select manager v98
cli source select manager Gv1
cli config get NFQWS_OPT > "$work/native-groups.opts"
for name in v98 Yv99 Gv1; do grep -q "^#$name$" "$work/native-groups.opts"; done
cp "$conf" "$work/native-select.before"
cp "$statefile" "$work/native-select-state.before"
touch "$ZIFY_TEST_ROOT/fail-restart"
bad cli source select flowseal general
equal_file "$conf" "$work/native-select.before"
equal_file "$statefile" "$work/native-select-state.before"
cli source select flowseal general
check_applied
cli source group flowseal base base_general
