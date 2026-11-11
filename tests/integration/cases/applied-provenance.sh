#!/bin/sh
set -eu
fixture_restore labelled
cli config get NFQWS_OPT > "$work/restored.opts"
equal_file "$work/flowseal.opts" "$work/restored.opts"
# Import is a manager application and records a fresh baseline, even for custom parameters.
sed 's/--filter-l7=discord,stun/--filter-l7=discord/' "$work/flowseal.opts" > "$work/edited.opts"
cli strategy import "$work/edited.opts"
check_applied
cli config get NFQWS_OPT > "$work/imported.opts"
equal_file "$work/edited.opts" "$work/imported.opts"
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/flowseal-status.out"
grep -q '    Стратегия: general (доступно обновление)$' "$work/flowseal-status.out"
fixture_restore labelled
check_applied
cp "$statefile" "$work/applied.before"
# A genuine manual edit bypasses the manager; status must not rewrite its baseline.
uci -c "$ZIFY_TEST_ROOT/etc/config" set "zapret.@main[0].NFQWS_OPT=$(cat "$work/edited.opts")"
uci -c "$ZIFY_TEST_ROOT/etc/config" commit zapret
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/manual-status.out"
grep -q '    Стратегия: general (изменена пользователем)$' "$work/manual-status.out"
equal_file "$statefile" "$work/applied.before"
cp "$conf" "$work/manual.before"
# Cancelling the manual-change warning must not claim the strategy was cleared.
printf '3\n5\ny\nn\n\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/cancel-clear-manual.out"
grep -q 'Очистка отменена' "$work/cancel-clear-manual.out"
if grep -q 'Стратегия очищена' "$work/cancel-clear-manual.out"; then exit 1; fi
equal_file "$conf" "$work/manual.before"
equal_file "$statefile" "$work/applied.before"
for answer in n ''; do
    printf 'y\n%s\n' "$answer" | cli_prompt source apply flowseal general > "$work/cancel-state.out" 2> "$work/cancel-state.err"
    grep -q 'Ваши ручные изменения будут заменены' "$work/cancel-state.err"
    grep -q 'Действие отменено' "$work/cancel-state.out"
    equal_file "$conf" "$work/manual.before"
    equal_file "$statefile" "$work/applied.before"
done
bad cli_raw source compose flowseal base_general youtube_general < /dev/null > "$work/cancel-state.out"
equal_file "$conf" "$work/manual.before"
equal_file "$statefile" "$work/applied.before"
bad cli_raw strategy import "$work/custom.txt" < /dev/null > "$work/cancel-state.out"
equal_file "$conf" "$work/manual.before"
equal_file "$statefile" "$work/applied.before"
# A catalog-only change adds the conflict suffix without changing saved state.
cp "$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json" "$work/catalog.before"
ucode -S -D "file=$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json" -e '
    import * as fs from "fs";
    let data = json(fs.readfile(file));
    data.catalog = replace(data.catalog, "--filter-l7=discord,stun", "--filter-l7=stun");
    fs.writefile(file, sprintf("%J\n", data));
'
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/conflict-status.out"
grep -q '    Стратегия: general (изменена вами, есть обновление)$' "$work/conflict-status.out"
equal_file "$statefile" "$work/applied.before"
# y authorizes replacing edits; the new application records the updated catalog hash.
cli source apply flowseal general > "$work/accept-state.out"
check_applied
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh src/launcher.sh > "$work/updated-status.out"
grep -q '    Стратегия: general$' "$work/updated-status.out"
cp "$work/catalog.before" "$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json"
fixture_restore labelled
# Compose also records a complete assembly; a failed state publication rolls UCI back.
cli source compose flowseal base_general youtube_general
check_applied
cp "$conf" "$work/state-write.before"
cp "$statefile" "$work/state-write-state.before"
mkdir -p "$work/fail-state-bin"
cp tests/mocks/integration/state-publication-mv.sh "$work/fail-state-bin/mv"
chmod +x "$work/fail-state-bin/mv"
ZIFY_REAL_MV=$(command -v mv)
export ZIFY_REAL_MV
touch "$ZIFY_TEST_ROOT/fail-state-write"
bad env LD_PRELOAD="$work/faults.so" PATH="$work/fail-state-bin:$PATH" /bin/sh "$ZIFY_HOME/src/launcher.sh" --yes --config "$work/manager" source apply flowseal base_general
equal_file "$conf" "$work/state-write.before"
equal_file "$statefile" "$work/state-write-state.before"
# A worker dying without running ucode catch handlers leaves its stage to the supervisor.
touch "$ZIFY_TEST_ROOT/crash-state-write"
bad env LD_PRELOAD="$work/faults.so" /bin/sh "$ZIFY_HOME/src/launcher.sh" --yes --config "$work/manager" source apply flowseal base_general
equal_file "$conf" "$work/state-write.before"
equal_file "$statefile" "$work/state-write-state.before"
for staged in "$ZIFY_TEST_ROOT/etc/zify/".zify-*; do [ ! -e "$staged" ]; done
cli status | grep -q running
fixture_restore labelled
cp "$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json" "$work/source.before"
printf 'bad\n' > "$ZIFY_TEST_ROOT/download"
rm "$ZIFY_TEST_ROOT/mock-sources"
bad cli source refresh flowseal
equal_file "$ZIFY_TEST_ROOT/etc/zify/assets/catalogs/flowseal.json" "$work/source.before"
