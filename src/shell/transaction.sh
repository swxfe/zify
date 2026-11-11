#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

config_unchanged() {
    remaining=$#
    literal=0
    while [ "$remaining" -gt 0 ]; do
        argument=$1; shift; remaining=$((remaining - 1))
        if [ "$literal" = 1 ]; then set -- "$@" "$argument"; continue; fi
        case "$argument" in
            --config|-c) [ "$remaining" -gt 0 ] || return 1; shift; remaining=$((remaining - 1));;
            --config=*|--yes|-y|--non-interactive) ;;
            --) literal=1;;
            *) set -- "$@" "$argument";;
        esac
    done
    [ "$#" -eq 4 ] && [ "$1" = config ] && [ "$2" = set ] || return 1
    case "$3" in DISABLE_IPV6) ;;
        *) return 1;; esac
    # Only committed configuration is read, under the same exclusive lock as writes.
    current=$(uci -c "$confdir" -t "$lock/delta" -q get "$profile.$section.$3" && printf x) || return 1
    # Preserve trailing newlines in the value; remove the sentinel and UCI's one terminator only.
    current=${current%x}
    current=${current%?}
    [ "$current" = "$4" ]
}

snapshot() {
    for idx in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
        managed_path "$idx"
        path=$managed_file
        if [ -f "$path" ]; then cp -p "$path" "$lock/$idx"; else : > "$lock/$idx.absent"; fi
    done
}
cleanup_staged() {
    [ -f "$lock/staged.paths" ] || return 0
    while IFS= read -r staged; do
        case "$staged" in *"/../"*|*"/./"*) return 1;; esac
        case "${staged##*/}" in .zify-*) ;; *) return 1;; esac
        case "$staged" in
            "$root/etc/zify/"*|"$base/"*|"$root/tmp/"*|            "$root/etc/config/.zify-"*|"$root/etc/crontabs/.zify-"*|"$root/usr/bin/.zify-"*) ;;
            *) return 1;;
        esac
        rm -f -- "$staged" || return 1
    done < "$lock/staged.paths"
    rm -f "$lock/staged.paths"
}
reset_all() {
    ZIFY_ROLLBACK=1
    export ZIFY_ROLLBACK
    if [ -f "$lock/uninstall.ready" ]; then
        for tree in state zapret; do
            if [ "$tree" = state ]; then path=$root/etc/zify; else path=$base; fi
            if [ -d "$lock/uninstall-$tree" ]; then
                rm -rf -- "$path" || return 1
                mkdir -p "$(dirname "$path")" || return 1
                cp -pR "$lock/uninstall-$tree" "$path" || return 1
            elif [ -f "$lock/uninstall-$tree.absent" ]; then
                rm -rf -- "$path" || return 1
            fi
        done
    fi
    journal=''
    if [ -f "$lock/changed" ]; then journal=$(cat "$lock/changed") || return 1; fi
    force_restore=0
    # Recovery also accepts snapshots from an older installed manager.
    if [ ! -f "$lock/changed" ]; then force_restore=1; fi
    runtime_changed=0
    for idx in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
        managed_path "$idx"
        path=$managed_file
        touched=0
        case "
$journal
" in *"
$path
"*) touched=1;; esac
        different=0
        if [ -f "$lock/$idx" ]; then
            if ! cmp -s "$lock/$idx" "$path"; then different=1; fi
            if [ "$different" = 1 ] || [ "$touched" = 1 ] || [ "$force_restore" = 1 ]; then
                atomic_copy "$lock/$idx" "$path" || return 1
            fi
        elif [ -f "$lock/$idx.absent" ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
            different=1
            rm -f "$path" || return 1
        fi
        case "$idx:$different" in 0:1|1:1|2:1|3:1|6:1|7:1|10:1|11:1|17:1) runtime_changed=1;; esac
    done
    if [ -f "$lock/native.paths" ]; then
        index=0
        while IFS= read -r path; do
            case "$path" in "$root/etc/zify/"*|"$base/"*|"$root/tmp/"*) ;; *) return 1;; esac
            case "$path" in *"/../"*|*"/./"*) return 1;; esac
            if [ -f "$lock/native.$index" ]; then atomic_copy "$lock/native.$index" "$path" || return 1
            elif [ -f "$lock/native.$index.absent" ]; then
                rm -f -- "$path" || return 1
            else return 1; fi
            index=$((index + 1))
        done < "$lock/native.paths"
    fi
    if [ -f "$lock/firewall.restart" ]; then "$root/etc/init.d/firewall" restart || return 1
    elif [ -f "$lock/firewall.touched" ]; then "$root/etc/init.d/firewall" reload || return 1; fi
    if [ -f "$lock/cron.before" ]; then
        atomic_copy "$lock/cron.before" "$root/etc/crontabs/root" || return 1
        "$root/etc/init.d/cron" restart || return 1
    elif [ -f "$lock/cron.absent" ]; then
        rm -f "$root/etc/crontabs/root" || return 1
        "$root/etc/init.d/cron" restart || return 1
    fi
    if [ -x "$init" ]; then
        if [ -f "$lock/enabled" ]; then
            if ! "$init" enabled >/dev/null 2>&1; then service enable || return 1; fi
        elif [ -f "$lock/disabled" ]; then
            if "$init" enabled >/dev/null 2>&1; then service disable || return 1; fi
        fi
        if [ -f "$lock/running" ]; then
            if [ "$force_restore" = 1 ] || [ "$runtime_changed" = 1 ] || [ -f "$lock/service.touched" ] || ! "$init" running >/dev/null 2>&1; then
                service restart || return 1
            fi
        elif [ "$force_restore" = 1 ] || [ -f "$lock/service.touched" ] || "$init" running >/dev/null 2>&1; then
            service stop || return 1
        fi
    fi
    : > "$lock/changed"
    rm -f "$lock/service.touched"
    cleanup_staged || return 1
    unset ZIFY_ROLLBACK
}
finish() {
    rc=$?
    trap - 0
    trap '' INT TERM HUP
    if [ "$rc" -ne 0 ] && [ -f "$lock/ready" ]; then
        printf '%s\n' 'zify: восстановление конфигурации и состояния сервиса' >&2
        if ! reset_all; then
            printf 'zify: откат не завершён; резервная копия: %s\n' "$lock" >&2
            exit 1
        fi
    fi
    if [ "$rc" = 0 ] && [ "${ZIFY_REPORT_CHANGE:-0}" = 1 ] &&
       { [ -s "$lock/changed" ] || [ -f "$lock/service.touched" ] ||
         [ -f "$lock/firewall.touched" ] || [ -f "$lock/cron.before" ] || [ -f "$lock/cron.absent" ]; }; then rc=10; fi
    if ! cleanup_staged; then
        printf 'zify: не удалось очистить временные файлы; снимок: %s\n' "$lock" >&2
        exit 1
    fi
    # Only this invocation's fixed lock directory is removed.
    case "$lock" in "$root/tmp/zify.$profile.lock") rm -rf -- "$lock";; esac
    exit "$rc"
}

# An abandoned transaction is restored before accepting the next mutation.
# A directory inside the old lock prevents two invocations from recovering it.
acquire_lock() {
    if mkdir "$lock" 2>/dev/null; then return; fi
    [ -f "$lock/pid" ] || fail "занято: $lock"
    previous_pid=$(cat "$lock/pid")
    case "$previous_pid" in ''|*[!0-9]*) fail 'повреждён pid блокировки';; esac
    if kill -0 "$previous_pid" 2>/dev/null; then fail 'транзакция ещё работает'; fi
    if [ -f "$lock/worker.pid" ]; then
        previous_worker=$(cat "$lock/worker.pid")
        case "$previous_worker" in ''|*[!0-9]*) fail 'повреждён pid worker';; esac
        if kill -0 "$previous_worker" 2>/dev/null; then fail 'worker транзакции ещё работает'; fi
    fi
    mkdir "$lock/recovering" 2>/dev/null || fail 'восстановление транзакции уже выполняется'
    if ! (
        ZIFY_TRANSACTION=$lock
        export ZIFY_TRANSACTION
        if [ -f "$lock/ready" ]; then reset_all || exit 1; fi
        rm -rf -- "$lock"
    ); then
        rmdir "$lock/recovering" 2>/dev/null || :
        fail "не удалось восстановить $lock"
    fi
    mkdir "$lock" 2>/dev/null || fail "занято: $lock"
}

case "$action" in
transaction|call)
    require_root
    mkdir -p "$root/tmp"
    acquire_lock
    trap finish 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf '%s\n' "$$" > "$lock/pid"
    if [ "$action" = transaction ] && config_unchanged "$@"; then exit 0; fi
    if [ -x "$init" ] && "$init" running >/dev/null 2>&1; then : > "$lock/running"; fi
    if [ -x "$init" ]; then
        if "$init" enabled >/dev/null 2>&1; then : > "$lock/enabled"; else : > "$lock/disabled"; fi
    fi
    snapshot
    : > "$lock/changed"
    : > "$lock/ready"
    ZIFY_TRANSACTION=$lock
    export ZIFY_TRANSACTION
    # Keep the supervisor alive so it can roll back a failed or interrupted worker.
    exec 3<&0
    child=''
    supervisor_pid=$$
    trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi; exit 130' INT
    trap 'if [ -n "$child" ]; then kill -TERM "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi; exit 143' TERM HUP
    (
        trap - 0 INT TERM HUP
        # Record worker ownership before it can mutate. A dead supervisor cannot
        # release an unrecorded worker into a newly recovered transaction.
        while :; do
            kill -0 "$supervisor_pid" 2>/dev/null || exit 1
            [ ! -f "$lock/worker.ready" ] || break
            sleep 0
        done
        if [ -n "${ZIFY_BOOTSTRAP:-}" ]; then
            exec ucode -S -e "$ZIFY_BOOTSTRAP zify_run('exit(worker_main(ARGV));');" -- "$action" "$@"
        else
            exec ucode -S -L "$ZIFY_HOME/src/lib" -- "$ZIFY_HOME/src/worker.uc" "$action" "$@"
        fi
    ) <&3 &
    child=$!
    printf '%s\n' "$child" > "$lock/worker.pid"
    : > "$lock/worker.ready"
    wait "$child"
    ;;
snapshot-uninstall)
    require_root
    [ "${ZIFY_TRANSACTION:-}" = "$lock" ] && [ -f "$lock/ready" ] || fail 'нет активной транзакции'
    case "$1" in manager|all) mode=$1;; *) fail 'неверный режим снимка удаления';; esac
    for tree in state zapret; do
        [ "$tree" != zapret ] || [ "$mode" = all ] || continue
        if [ "$tree" = state ]; then path=$root/etc/zify; else path=$base; fi
        [ ! -L "$path" ] || fail "отказ удалять символическую ссылку: $path"
        if [ -d "$path" ]; then cp -pR "$path" "$lock/uninstall-$tree"
        else : > "$lock/uninstall-$tree.absent"; fi
    done
    : > "$lock/uninstall.ready"
    ;;
snapshot-path)
    require_root
    [ "${ZIFY_TRANSACTION:-}" = "$lock" ] && [ -f "$lock/ready" ] || fail 'нет активной транзакции'
    path=$1
    if [ "$path" = "$root/etc/crontabs/root" ]; then
        if [ ! -f "$lock/cron.before" ] && [ ! -f "$lock/cron.absent" ]; then
            if [ -f "$path" ]; then cp -p "$path" "$lock/cron.before"; else : > "$lock/cron.absent"; fi
        fi
        exit 0
    fi
    # Fixed entries were captured before the worker started. Snapshot other managed
    # files once, including previously absent managed files.
    for idx in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
        managed_path "$idx"
        [ "$path" != "$managed_file" ] || exit 0
    done
    case "$path" in "$root/etc/zify/"*|"$base/"*|"$root/tmp/"*) ;; *) fail 'путь вне разрешённых каталогов';; esac
    case "$path" in *"/../"*|*"/./"*) fail 'неверный путь снимка';; esac
    if [ -f "$lock/native.paths" ] && grep -Fxq -- "$path" "$lock/native.paths"; then exit 0; fi
    index=0
    if [ -f "$lock/native.paths" ]; then index=$(wc -l < "$lock/native.paths"); fi
    if [ -f "$path" ]; then cp -p "$path" "$lock/native.$index"
    else : > "$lock/native.$index.absent"; fi
    printf '%s\n' "$path" >> "$lock/native.paths"
    ;;
*) fail 'неизвестная операция транзакции';;
esac
