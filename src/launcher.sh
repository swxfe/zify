#!/bin/sh
set -eu

ZIFY_HOME=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
export ZIFY_HOME
if ! command -v ucode >/dev/null 2>&1; then
    printf '%s\n' 'zify: требуется ucode и модуль ucode-mod-fs' >&2
    exit 127
fi
exec ucode -S -L "$ZIFY_HOME/src/lib" -- "$ZIFY_HOME/src/main.uc" "$@"
