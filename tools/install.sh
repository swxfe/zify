#!/bin/sh
set -eu
umask 022
project=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
destination=${DESTDIR:-}
case "$destination" in ''|/*) ;; *) printf '%s\n' 'DESTDIR должен быть абсолютным' >&2; exit 1;; esac
case "/$destination/" in */../*|*/./*) exit 1;; esac
if [ "${1:-}" = uninstall ]; then
    DESTDIR=$destination /bin/sh "$project/src/launcher.sh" --yes uninstall manager
    exit 0
fi
[ "$#" -eq 0 ] || exit 2
sh "$project/tools/bundle.sh"
# The same supervisor and Copy-on-Write implementation serve source and bundled installs.
archive=${ZIFY_ASSETS_ARCHIVE:-$project/dist/zify-assets.tar.gz}
[ -f "$archive" ] || { printf '%s\n' 'Сначала соберите ассеты: make dist' >&2; exit 1; }
DESTDIR=$destination /bin/sh "$project/dist/zify.sh" --yes manager-install "$archive"
