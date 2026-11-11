#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

case "$action" in
transaction|call|snapshot-path|snapshot-uninstall)
    exec /bin/sh "$(dirname "$0")/transaction.sh" "$action" "$root" "$profile" "$@"
    ;;
package|release-install)
    exec /bin/sh "$(dirname "$0")/packages.sh" "$action" "$root" "$profile" "$@"
    ;;
check-space) check_space "$1";;
manager-validate)
    /bin/sh -n "$1"
    /bin/sh "$1" version
    ;;
*)
    # Compatibility entry for internal atom calls; business logic lives in ucode.
    # The ordinary UI/worker invokes that logic directly and never takes this path.
    if [ -n "${ZIFY_BOOTSTRAP:-}" ]; then
        ZIFY_NATIVE_ATOM=1 exec ucode -S -e "$ZIFY_BOOTSTRAP zify_run('exit(atom_main(ARGV));');" -- "$action" "$root" "$profile" "$@"
    else
        ZIFY_NATIVE_ATOM=1 exec ucode -S -L "$ZIFY_HOME/src/lib" -- "$ZIFY_HOME/src/atom.uc" "$action" "$root" "$profile" "$@"
    fi
    ;;
esac
