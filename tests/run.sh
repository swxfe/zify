#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ZIFY_HOME=$(pwd -P)
ZIFY_HTTP_PROVIDER=$ZIFY_HOME/tests/mocks/http-provider.uc
export ZIFY_HOME ZIFY_HTTP_PROVIDER
ZIFY_ASSETS_ARCHIVE=$ZIFY_HOME/.test-tmp/zify-assets-fixture.tar.gz
export ZIFY_ASSETS_ARCHIVE
python3 tools/build-assets.py --fixtures --output "$ZIFY_ASSETS_ARCHIVE" >/dev/null
exec python3 -B tests/run.py
