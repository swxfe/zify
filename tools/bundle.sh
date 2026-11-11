#!/bin/sh
set -eu
ZIFY_HOME=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
export ZIFY_HOME
exec ucode -S -L "$ZIFY_HOME/src/lib" "$ZIFY_HOME/tools/bundle.uc"
