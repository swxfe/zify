#!/bin/sh
set -eu
[ "${ZIFY_DF_FAIL:-0}" = 0 ] || exit 1
printf '%s\n' "$*" >> "$ZIFY_TEST_ROOT/df.calls"
printf 'Filesystem 1K-blocks Used Available Use%% Mounted\nfixture 999999 0 %s 0%% /\n' "${ZIFY_FREE_KB:-999999}"
