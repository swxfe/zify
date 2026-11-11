#!/bin/sh
set -eu
# Code, catalogs, fakes and legal files move together, pinned to one release revision.
mkdir -p "$ZIFY_TEST_ROOT/usr/bin"
cp "$work/standalone.sh" "$ZIFY_TEST_ROOT/usr/bin/zify"
ZIFY_UPDATE_CONFIG=$work/manager ZIFY_UPDATE_BASE=$work/standalone.sh ucode -S -L "$ZIFY_HOME/src/lib" tests/integration/manager-update.uc
python3 tests/performance/navigation.py "$work/manager" "$work/faults.so"
