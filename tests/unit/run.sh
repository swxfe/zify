#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
ZIFY_HOME=$(pwd -P)
export ZIFY_HOME
exec ucode -S -L "$ZIFY_HOME/src/lib" tests/unit/run.uc
