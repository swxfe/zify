#!/bin/sh
# ZIFY_VERSION=@VERSION@
# ZIFY_FORMAT=2
# SPDX-License-Identifier: AGPL-3.0-only
# Source and license: https://github.com/swxfe/zify
# Generated from src/. This file contains readable shell and ucode source.
set -eu
ZIFY_PID=$$
export ZIFY_PID
command -v ucode >/dev/null 2>&1 || {
    printf '%s\n' 'zify: требуется ucode и пакет ucode-mod-fs' >&2
    exit 127
}
