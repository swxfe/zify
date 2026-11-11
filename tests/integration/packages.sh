#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/packages.sh

# Release ZIP includes both packages; missing LuCI is repaired without core reinstall.
helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null
grep -q 'zapret_.*ipk.*luci-app-zapret_.*ipk' "$stage/actions"
: > "$stage/actions"
helper release-install https://fixture.test/release.zip '' 1 2 luci > /dev/null
grep -q 'install .*luci-app-zapret_' "$stage/actions"
if grep -q '/zapret_' "$stage/actions"; then exit 1; fi
: > "$stage/actions"
touch "$stage/missing-luci"
if helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null 2>&1; then exit 1; fi
[ ! -s "$stage/actions" ]
rm "$stage/missing-luci"
# The deleted feeds/local package commands cannot bypass the release installer.
if sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null 2>&1; then exit 1; fi
[ ! -s "$stage/actions" ]
# Exercise the APK path with the same fixtures and no real package manager.
cp tests/mocks/packages/apk.sh "$stage/bin/apk"
chmod +x "$stage/bin/apk"
: > "$stage/actions"
helper release-install https://fixture.test/release.zip '' 1 2 both > /dev/null
grep -q 'add --allow-untrusted .*zapret-.*apk.*luci-app-zapret-.*apk' "$stage/actions"
: > "$stage/actions"
if sh "$project/src/shell/packages.sh" package '' zapret update > /dev/null 2>&1; then exit 1; fi
[ ! -s "$stage/actions" ]
# Selective removal passes exact package names; an installed LuCI dependency blocks core-only removal.
for manager in apk opkg; do
    if [ "$manager" = opkg ]; then rm "$stage/bin/apk"; fi
    touch "$stage/zapret" "$stage/luci-app-zapret"
    : > "$stage/actions"
    if sh "$project/src/shell/packages.sh" package '' zapret remove zapret > /dev/null 2>&1; then exit 1; fi
    [ ! -s "$stage/actions" ]
    sh "$project/src/shell/packages.sh" package '' zapret remove luci-app-zapret
    [ -e "$stage/zapret" ] && [ ! -e "$stage/luci-app-zapret" ]
    if grep -q '^\(remove\|del\) zapret' "$stage/actions"; then exit 1; fi
    sh "$project/src/shell/packages.sh" package '' zapret remove zapret
    [ ! -e "$stage/zapret" ]
    cp "$stage/actions" "$stage/noop.before"
    sh "$project/src/shell/packages.sh" package '' zapret remove zapret
    cmp "$stage/actions" "$stage/noop.before"
done
printf '%s\n' 'packages: core + LuCI releases, missing-package rejection, removed feeds API and selective removal OK'
