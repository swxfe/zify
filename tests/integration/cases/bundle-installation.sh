#!/bin/sh
set -eu
# Verify that the standalone artifact runs away from the source tree.
sh tools/bundle.sh >/dev/null
cp dist/zify.sh "$work/standalone.sh"
# Installation uses the same CLI and transaction supervisor as other mutations.
DESTDIR=$work/internal-image sh "$work/standalone.sh" --yes --config "$work/manager" manager-install > "$work/internal-install.log"
equal_file "$work/standalone.sh" "$work/internal-image/usr/bin/zify"
[ -x "$work/internal-image/usr/bin/zify" ]
bad sh "$work/standalone.sh" --yes --config "$work/manager" manager-install unexpected extra
# Show exact package versions and known configured profiles, with independent service state.
mkdir -p "$ZIFY_TEST_ROOT/usr/lib/opkg"
cat > "$ZIFY_TEST_ROOT/usr/lib/opkg/status" <<'EOF'
Package: zapret
Version: 72.20260307-r1
Status: install ok installed

Package: luci-app-zapret
Version: 72.20260307-r1
Status: install ok installed
EOF
touch "$ZIFY_TEST_ROOT/mock-release"
cp "$conf" "$work/no-update.before"
cli update-upstream > "$work/no-update.out"
grep -q 'Новых версий нет' "$work/no-update.out"
equal_file "$conf" "$work/no-update.before"
rm "$ZIFY_TEST_ROOT/mock-release"
cli source compose flowseal base_general youtube_general
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/dashboard.out"
grep -q 'Zapret.*72.20260307-r1' "$work/dashboard.out"
if grep -q 'LuCI Zapret:' "$work/dashboard.out"; then exit 1; fi
grep -q 'youtube_general' "$work/dashboard.out"
grep -q 'base_general' "$work/dashboard.out"
mkdir -p "$ZIFY_TEST_ROOT/bin"
cat > "$ZIFY_TEST_ROOT/bin/ubus" <<'EOF'
#!/bin/sh
set -eu
[ "$*" = '-t 1 call service list {"name":"zapret"}' ]
printf '%s\n' '{"zapret":{"instances":{"nfqws":{"running":true}}}}'
EOF
chmod +x "$ZIFY_TEST_ROOT/bin/ubus"
touch "$ZIFY_TEST_ROOT/procd-running"
mv "$ZIFY_TEST_ROOT/etc/init.d/zapret" "$work/init-procd.saved"
printf '#!/bin/sh\nexit 99\n' > "$ZIFY_TEST_ROOT/etc/init.d/zapret"
chmod +x "$ZIFY_TEST_ROOT/etc/init.d/zapret"
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/procd.out"
grep -q 'Zapret.*активен' "$work/procd.out"
touch "$ZIFY_TEST_ROOT/procd-invalid"
printf '#!/bin/sh\nprintf "invalid\\n"\n' > "$ZIFY_TEST_ROOT/bin/ubus"
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/procd-error.out"
grep -q 'состояние неизвестно' "$work/procd-error.out"
rm "$ZIFY_TEST_ROOT/bin/ubus" "$ZIFY_TEST_ROOT/procd-invalid" "$ZIFY_TEST_ROOT/procd-running"
mv "$work/init-procd.saved" "$ZIFY_TEST_ROOT/etc/init.d/zapret"
printf 'q\n' | ZIFY_COLOR=always ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/colors.out"
grep -q "$(printf '\033')\[38;5;82" "$work/colors.out"
# No installed files or package database: only installation is offered.
mv "$ZIFY_TEST_ROOT/etc/init.d/zapret" "$work/init.saved"
mv "$ZIFY_TEST_ROOT/usr/lib/opkg/status" "$work/status.saved"
printf '1\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/not-installed.out"
grep -q 'Установить Zapret' "$work/not-installed.out"
if grep -q 'Обновить Zapret\|Удалить Zapret' "$work/not-installed.out"; then exit 1; fi
mv "$work/init.saved" "$ZIFY_TEST_ROOT/etc/init.d/zapret"
mv "$work/status.saved" "$ZIFY_TEST_ROOT/usr/lib/opkg/status"
# Startup must not call extraction/temporary-directory helpers, even when they fail.
mkdir "$work/startup-bin"
for helper in mktemp tar base64 gzip; do
    printf '#!/bin/sh\nexit 99\n' > "$work/startup-bin/$helper"
    chmod +x "$work/startup-bin/$helper"
done
printf 'q\n' | PATH=$work/startup-bin:$PATH ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/startup.out"
grep -q 'Установка / обновление / удаление' "$work/startup.out"
grep -q 'Q — выход' "$work/startup.out"
if grep -q 'не проверена\|Ошибка:' "$work/startup.out"; then exit 1; fi
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/menu.out"
grep -q 'Установка / обновление / удаление' "$work/menu.out"
sh "$work/standalone.sh" --help > "$work/help.out"
grep -q "zify \[параметры\]" "$work/help.out"
# The payload does not reread $0, so process substitution and a streamed shell work too.
bash -c 'sh <(cat "$1") --help' -- "$work/standalone.sh" > "$work/substitution.out"
grep -q 'zify \[параметры\]' "$work/substitution.out"
cat "$work/standalone.sh" | sh -s -- --help > "$work/stream.out"
grep -q 'zify \[параметры\]' "$work/stream.out"
printf 'q\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/uninstalled-menu.out"
if grep -q 'Установить команду zify' "$work/uninstalled-menu.out"; then exit 1; fi
# Installation is completed by the installer before the public menu opens.
DESTDIR=$work/bundle-image sh "$work/standalone.sh" --yes --config "$work/manager" manager-install > "$work/installed.out"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/zify"
[ -x "$work/bundle-image/usr/bin/zify" ]
printf 'q\n' | ZIFY_CONFIG=$work/manager DESTDIR=$work/bundle-image python3 tests/support/terminal.py sh "$work/bundle-image/usr/bin/zify" > "$work/installed-menu.out"
if grep -q 'Установить команду zify' "$work/installed-menu.out"; then exit 1; fi
printf 'i\n\nq\n' | ZIFY_CONFIG=$work/manager DESTDIR=$work/bundle-image python3 tests/support/terminal.py sh "$work/standalone.sh" > "$work/installed-shortcut.out"
grep -q 'Установка / обновление / удаление' "$work/installed-shortcut.out"
if grep -q 'Ошибка:' "$work/installed-shortcut.out"; then exit 1; fi
[ ! -e "$work/bundle-image/usr/bin/zify.previous" ]
# Reinstallation is available through the CLI.
DESTDIR=$work/bundle-image sh "$work/standalone.sh" --yes --config "$work/manager" manager-install > "$work/reinstalled.out"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/zify"
equal_file "$work/standalone.sh" "$work/bundle-image/usr/bin/zify.previous"
[ -x "$work/bundle-image/usr/bin/zify" ]
[ -x "$work/bundle-image/usr/bin/zify.previous" ]
printf '2\n3\n\nq\nq\n' | ZIFY_CONFIG=$work/manager python3 tests/support/terminal.py sh "$work/bundle-image/usr/bin/zify" > "$work/installed-actions.out"
cli status | grep -q running
