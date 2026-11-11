#!/bin/sh
# ZIFY_VERSION=1.0
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
ZIFY_BACKEND=$(cat <<'__ZIFY_ZIFY_BACKEND__'
set -eu
if [ ! -t 0 ]; then exec </dev/null; fi
umask 077

fail() { printf 'zify: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "не найдена команда: $1"; }
[ "$#" -ge 3 ] || fail 'неверный вызов backend'
# Shared dispatcher state is consumed by the scripts sourcing this file.
# shellcheck disable=SC2034
action=$1 root=$2 profile=$3
shift 3
case "$profile" in zapret) ;; *) fail 'неверный профиль';; esac
case "$root" in ''|/*) ;; *) fail 'root должен быть абсолютным';; esac
case "/$root/" in */../*|*/./*) fail 'root содержит . или ..';; esac
base=$root/opt/$profile
confdir=$root/etc/config
config=$confdir/$profile
init=$root/etc/init.d/$profile
# shellcheck disable=SC2034
lock=$root/tmp/zify.$profile.lock
# shellcheck disable=SC2034
section='@main[0]'
require_root() { [ "$(id -u)" -eq 0 ] || fail 'команда требует root'; }
require_config() { [ -f "$config" ] || fail "не найден конфиг: $config"; need uci; }
uci_cmd() { uci -c "$confdir" -t "${ZIFY_TRANSACTION:-$root/tmp}/delta" "$@"; }
# All sizes and df values are in KiB. Unknown capacity is a hard failure.
check_space() (
    case "${1:-}" in ''|*[!0-9]*) fail 'check_space: нужен размер в KB';; esac
    [ "${#1}" -le 7 ] && [ "$1" -le 1048576 ] || fail 'check_space: слишком большой размер'
    space_target=$root/overlay
    [ -d "$space_target" ] || space_target=${root:-/}
    space_report=$(df -Pk "$space_target" 2>/dev/null) || fail "не удалось проверить свободное место: $space_target"
    space_free=''
    {
        read -r _space_header || fail "df не вернул заголовок: $space_target"
        read -r _space_fs _space_total _space_used space_free _space_rest || fail "df не вернул доступное место: $space_target"
    } <<EOF
$space_report
EOF
    case "$space_free" in ''|*[!0-9]*) fail "df не вернул доступное место: $space_target";; esac
    space_required=$(( $1 * 2 + 5120 ))
    [ "$space_free" -ge "$space_required" ] || fail "недостаточно места на $space_target: доступно $space_free KB, требуется $space_required KB (запас 5120 KB)"
)
file_kb() { file_bytes=$(wc -c < "$1") || return 1; printf '%s\n' "$(( (file_bytes + 1023) / 1024 ))"; }
mark_changed() {
    if [ "${ZIFY_ROLLBACK:-0}" != 1 ] && [ "${ZIFY_TRANSACTION:-}" = "$lock" ]; then
        printf '%s\n' "$1" >> "$lock/changed"
    fi
}
service() {
    [ -x "$init" ] || fail "не найден init-скрипт: $init"
    case "$1" in start|stop|restart)
        if [ "${ZIFY_ROLLBACK:-0}" != 1 ] && [ "${ZIFY_TRANSACTION:-}" = "$lock" ]; then
            : > "$lock/service.touched"
            mark_changed "$config"
            mark_changed "$base/config"
        fi;;
    esac
    if [ "$1" = restart ] || [ "$1" = start ]; then
        if [ "$profile" = zapret ] && [ -f "$base/sync_config.sh" ]; then
            /bin/sh "$base/sync_config.sh" || fail 'ошибка sync_config.sh'
        fi
    fi
    "$init" "$1" || fail "сервис $profile: ошибка $1"
}
host_path() {
    case "$1:$profile" in
        user:zapret) host_file=$base/ipset/zapret-hosts-user.txt;;
        exclude:zapret) host_file=$base/ipset/zapret-hosts-user-exclude.txt;;
        google:zapret) host_file=$base/ipset/zapret-hosts-google.txt;;
        *) fail 'неизвестный список доменов';;
    esac
}
# The caller consumes managed_file without a command-substitution subprocess.
# shellcheck disable=SC2034
managed_path() {
    case "$1" in
        0) managed_file=$config;;
        1) host_path user; managed_file=$host_file;;
        2) host_path exclude; managed_file=$host_file;;
        3) host_path google; managed_file=$host_file;;
        4) managed_file=$root/etc/zify/assets/manifest.json;;
        5) managed_file=$root/etc/zify/assets/catalogs/flowseal.json;;
        6) managed_file=$root/etc/zify/devices.txt;;
        7) managed_file=$base/init.d/openwrt/custom.d/20-zify-exclude.sh;;
        8) managed_file=$root/etc/config/firewall;;
        9) managed_file=$root/etc/zify/offload.previous;;
        10) managed_file=$base/init.d/openwrt/custom.d/20-script.sh;;
        11) managed_file=$root/etc/zify/legacy-exclusion-hook.sh;;
        12) managed_file=$root/etc/zify/state.json;;
        13) managed_file=$root/usr/bin/zify;;
        14) managed_file=$root/usr/bin/zify.previous;;
        15) managed_file=$root/etc/config/zify;;
        16) managed_file=$root/etc/zify/update.json;;
        17) managed_file=$base/config;;
    esac
}
atomic_copy() (
    src=$1 dest=$2
    # Rollback must restore metadata even if only chmod/chown changed.
    if [ "${ZIFY_ROLLBACK:-0}" != 1 ] && [ "$#" -eq 2 ] && [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest"; then
        exit 0
    fi
    dir=${dest%/*}
    [ -n "$dir" ] || dir=/
    mkdir -p "$dir" || exit 1
    if [ "${ZIFY_ROLLBACK:-0}" != 1 ]; then check_space "$(file_kb "$src")" || exit 1; fi
    # BusyBox requires the six X characters at the end of the template.
    case "$dest" in */etc/zify/update.json) tmp=$(mktemp "$dir/.update-XXXXXX") || exit 1;;
        *) tmp=$(mktemp "$dir/.zify-XXXXXX") || exit 1;; esac
    trap 'rm -f "$tmp"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    # POSIX cp -p preserves metadata without requiring the optional stat applet.
    if [ "${ZIFY_ROLLBACK:-0}" = 1 ]; then
        cp -p "$src" "$tmp" || exit 1
    else
        if [ -f "$dest" ]; then cp -p "$dest" "$tmp" || exit 1; fi
        cat "$src" > "$tmp" || exit 1
    fi
    if [ "$#" -ge 3 ]; then chmod "$3" "$tmp" || exit 1; fi
    mark_changed "$dest"
    mv -f "$tmp" "$dest"
)


zify_transaction() {

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

}

zify_packages() {

package_manager() {
    if command -v apk >/dev/null 2>&1; then manager=apk
    elif command -v opkg >/dev/null 2>&1; then manager=opkg
    else fail 'не найден opkg или apk'
    fi
}
package_present() {
    if [ "$manager" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" | awk '$1=="Status:" && $NF=="installed" {found=1} END {exit !found}'
    fi
}
install_files() {
    install_kb=0
    for install_file do install_kb=$((install_kb + $(file_kb "$install_file"))); done
    check_space "$install_kb"
    if [ "$manager" = opkg ]; then opkg install "$@"
    else
        printf '%s\n' 'Локальные APK: используется --allow-untrusted для сборки Zapret и LuCI.'
        apk add --allow-untrusted "$@"
    fi
    check_space 0
}
luci_ready() {
    if [ -x "$root/etc/init.d/rpcd" ]; then "$root/etc/init.d/rpcd" restart; fi
    printf '%s\n' 'LuCI Zapret установлен. Обновите страницу LuCI: Сервисы → Zapret.'
}

case "$action" in
release-install)
    require_root
    [ -z "${ZIFY_TRANSACTION:-}" ] || fail 'пакеты нельзя устанавливать внутри транзакции конфигов'
    [ -z "$root" ] || fail 'установка релиза возможна только на роутере'
    need curl
    package_manager
    components=$5
    case "$components" in both|luci) ;; *) fail 'неверный набор пакетов';; esac
    check_space "${6:-16384}"
    need unzip
    stage=$(mktemp -d /tmp/zify-release-XXXXXX)
    trap 'rm -rf -- "$stage"' 0
    curl --fail --location --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout "$3" --max-time "$4" --max-filesize 16777216 --output "$stage/release.zip" "$1"
    if [ -n "$2" ]; then
        need sha256sum
        printf '%s  %s\n' "$2" "$stage/release.zip" | sha256sum -c - || fail 'SHA256 архива не совпал'
    fi
    unzip -l "$stage/release.zip" > "$stage/members"
    set --
    # Validate and extract every selected package before invoking the package manager.
    for name in zapret luci-app-zapret; do
        [ "$components:$name" != luci:zapret ] || continue
        if [ "$manager" = opkg ]; then pattern="^${name}_[A-Za-z0-9_.+-]+[.]ipk$"
        else pattern="^apk/${name}-[A-Za-z0-9_.+-]+[.]apk$"
        fi
        member=$(awk -v pattern="$pattern" '$4 ~ pattern && $1+0>0 && $1+0<=16777216 {print $4}' "$stage/members")
        [ "$(printf '%s\n' "$member" | wc -l)" -eq 1 ] && [ -n "$member" ] || fail "в релизе не найден единственный пакет $name"
        package=$stage/$(basename "$member")
        unzip -p "$stage/release.zip" "$member" > "$package"
        [ -s "$package" ] && [ "$(wc -c < "$package")" -le 16777216 ] || fail "неверный размер пакета $name"
        set -- "$@" "$package"
    done
    install_files "$@"
    luci_ready
    ;;
package)
    require_root
    [ -z "${ZIFY_TRANSACTION:-}" ] || fail 'пакеты нельзя изменять внутри транзакции конфигов'
    [ -z "$root" ] || fail 'установка пакетов возможна только при root="/"'
    [ "$1" = remove ] || fail 'доступно только удаление пакетов'
    shift
    package_manager
    for pkg do case "$pkg" in zapret|luci-app-zapret) ;; *) fail "неверный компонент: $pkg";; esac; done
        [ "$#" -gt 0 ] || set -- luci-app-zapret zapret
        remove_core=0; remove_luci=0
        for name do
            case "$name" in zapret) remove_core=1;; luci-app-zapret) remove_luci=1;; esac
        done
        if [ "$remove_core" = 1 ]; then
            if [ "$remove_luci" = 0 ] && package_present luci-app-zapret; then
                fail 'LuCI Zapret зависит от Zapret; выберите оба компонента'
            fi
            if [ -x "$init" ]; then service stop; service disable; fi
        fi
        requested="$*"
        set --
        for name in $requested; do if package_present "$name"; then set -- "$@" "$name"; fi; done
        if [ "$#" -gt 0 ]; then
            if [ "$manager" = opkg ]; then opkg remove "$@"; else apk del "$@"; fi
        fi
    ;;
*) fail 'неизвестная операция пакета';;
esac

}

# ---- system operation dispatcher ----

case "$action" in
transaction|call|snapshot-path|snapshot-uninstall)
    zify_transaction "$@"
    ;;
package|release-install)
    zify_packages "$@"
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
__ZIFY_ZIFY_BACKEND__
)
export ZIFY_BACKEND

ZIFY_UCODE_1=$(cat <<'__ZIFY_ZIFY_UCODE_1__'
import * as fs from 'fs';
import * as uci from 'uci';
import * as ubus from 'ubus';
import { sha256 } from 'digest';
import * as uclient from 'uclient';
import * as uloop from 'uloop';
const EMBEDDED_HEADER = "#!/bin/sh\n# ZIFY_VERSION=1.0\n# ZIFY_FORMAT=2\n# SPDX-License-Identifier: AGPL-3.0-only\n# Source and license: https://github.com/swxfe/zify\n# Generated from src/. This file contains readable shell and ucode source.\nset -eu\nZIFY_PID=$$\nexport ZIFY_PID\ncommand -v ucode >/dev/null 2>&1 || {\n    printf '%s\\n' 'zify: требуется ucode и пакет ucode-mod-fs' >&2\n    exit 127\n}\n";
const EMBEDDED_FOOTER = "# Compile definitions in memory; entry functions are selected by trusted source files.\n# shellcheck disable=SC2089\nZIFY_BOOTSTRAP='let source = \"\"; for (let i = 1; i <= +getenv(\"ZIFY_PARTS\"); i++) source += getenv(\"ZIFY_UCODE_\" + i) + \"\\n\"; function zify_run(entry) { loadstring(source + \"\\n\" + entry, { strict_declarations: true })(); }'\nZIFY_HOME=${ZIFY_HOME:-/}\n# shellcheck disable=SC2090\nexport ZIFY_BOOTSTRAP ZIFY_HOME\nexec ucode -S -e \"$ZIFY_BOOTSTRAP zify_run('exit(cli_main(ARGV));');\" -- \"$@\"\n";

// ---- src/lib/console.uc ----

let console_log = null;

// Only interactive actions capture output; CLI stdout/stderr keep their contract.
function capture_output(path) { console_log = path; };

function report(text, error) {
    let target = console_log ? fs.open(console_log, 'a') : (error ? fs.stderr : fs.stdout);
    if (target == null) die('не удалось открыть журнал действия');
    target.write(text); target.flush();
    if (console_log) target.close();
};

function execute(args) {
    if (!console_log) return system(args);
    // Preserve a visible channel for interactive confirmations in transaction workers.
    return system(['/bin/sh', '-c',
        'log=$1; shift; exec 9>&2; ZIFY_MENU_PROMPT_FD=9; export ZIFY_MENU_PROMPT_FD; exec "$@" >>"$log" 2>&1',
        'zify-action', console_log, ...args]);
};

// ---- src/lib/resources.uc ----

let resource_cache = {};
const VERSION = '1.0';
const UPDATE_REPO = 'swxfe/zify';
const UPDATE_BRANCH = 'main';
const UPDATE_PATH = 'dist/zify.sh';
const INSTALLER_REPO = 'remittor/zapret-openwrt';

function embedded_header() { return EMBEDDED_HEADER; };
function embedded_footer() { return EMBEDDED_FOOTER; };

function resource(directory, name) {
    if (!match(name, /^[A-Za-z0-9_.-]+$/)) die('неверное имя ресурса');
    let path = directory + '/' + name;
    if (exists(resource_cache, path)) return resource_cache[path];
    let st = fs.stat(path);
    if (st?.type != 'file' || st.size > 2097152) die('ассет не установлен или слишком большой: ' + name);
    let body = fs.readfile(path, st.size + 1);
    if (body == null || length(body) != st.size) die('не удалось прочитать ассет: ' + name);
    if (length(resource_cache) >= 16) resource_cache = {};
    resource_cache[path] = body;
    return body;
};

// ---- src/lib/cache.uc ----
// Only an interactive session owns this cache; transaction workers read fresh state.
function session_cache(ctx) {
    ctx.cache = {};
};

function cached(ctx, key, obtain) {
    if (ctx.cache == null) return obtain();
    if (exists(ctx.cache, key)) return ctx.cache[key];
    // User-selected catalogs and paths must not grow the session without a bound.
    if (length(ctx.cache) >= 64) ctx.cache = {};
    let value = obtain();
    ctx.cache[key] = value;
    return value;
};

function invalidate(ctx) {
    if (ctx.cache != null) ctx.cache = {};
};

// ---- src/lib/platform.uc ----

function config_cursor(ctx, writeable) {
    // Ignore shared CLI deltas and runtime overrides; workers use their private delta directory.
    let delta = writeable ? getenv('ZIFY_TRANSACTION') + '/delta' : '/dev/null';
    let handle = uci.cursor(ctx.root + '/etc/config', delta, '', { strict: true, print_errors: false });
    if (handle == null) die('не удалось создать UCI cursor: ' + uci.error());
    return handle;
};

function config_values(ctx, package, section, optional) {
    return cached(ctx, 'uci:' + package + ':' + section + (optional ? ':optional' : ''), () => {
        let st = fs.stat(ctx.root + '/etc/config/' + package);
        if (st?.type != 'file' || st.size > ctx.max_file_bytes) die('неверный размер UCI: ' + package);
        let handle = cached(ctx, 'uci-package:' + package, () => {
            let cursor = config_cursor(ctx, false);
            if (!cursor.load(package)) die('не удалось прочитать UCI ' + package + ': ' + uci.error());
            return cursor;
        });
        let values = handle.get_all(package, section);
        if (values == null && optional) return {};
        if (values == null) die('основная секция конфига не найдена: ' + package);
        return values;
    });
};

function config_option(ctx, key, optional) {
    if (!match(key, /^[A-Za-z][A-Za-z0-9_]*$/)) die('неверное имя опции');
    let value = config_values(ctx, 'zapret', '@main[0]')[key];
    if (value == null) {
        if (!optional) die('опция UCI не найдена: ' + key);
        return '';
    }
    if (type(value) == 'array') value = join(' ', value);
    if (type(value) != 'string' || length(value) > ctx.max_file_bytes || index(value, '\x00') != -1)
        die('неверное значение UCI: ' + key);
    return value + '\n';
};

function host_path(ctx, kind) {
    let names = { user: 'zapret-hosts-user.txt', exclude: 'zapret-hosts-user-exclude.txt', google: 'zapret-hosts-google.txt' };
    if (!exists(names, kind)) die('неизвестный список доменов');
    return ctx.base + '/ipset/' + names[kind];
};

function native_running(ctx) {
    // Off-root fixtures use their own bus, with precisely the same native RPC path.
    let socket = ctx.root == '' ? null : ctx.root + '/tmp/ubus.sock';
    let connection = ubus.connect(socket, 1);
    if (connection == null) return null;
    let reply;
    try { reply = connection.call('service', 'list', { name: 'zapret' }); }
    catch (e) { connection.disconnect(); return null; }
    connection.disconnect();
    return reply;
};

// ---- src/lib/http.uc ----

let http_provider = null, http_provider_path = null;

function http_valid_url(url, allow_http) {
    return type(url) == 'string' && length(url) <= 4096 &&
        match(url, allow_http ? /^https?:\/\/[^[:space:]]+$/ : /^https:\/\/[^[:space:]]+$/);
}

// The explicit provider is for the offline fault-injection harness. It is never
// read from manager.json, remote catalogs or responses.
function http_request(ctx, url, limit, allow_http, discard, destination) {
    if (!http_valid_url(url, allow_http)) die('неверный URL HTTP');
    let provider = getenv('ZIFY_HTTP_PROVIDER');
    if (provider != null) {
        if (http_provider == null || http_provider_path != provider) {
            http_provider = loadfile(provider, { strict_declarations: true })();
            http_provider_path = provider;
        }
        let reply = http_provider.request(url, { limit, allow_http,
            connect_timeout: ctx.connect_timeout, request_timeout: ctx.request_timeout });
        if (type(reply) != 'object' || type(reply.body) != 'string' || length(reply.body) > limit ||
            type(reply.status) != 'int' || reply.status < 100 || reply.status > 599 || type(reply.headers) != 'object')
            die('неверный ответ HTTP provider');
        if (destination != null && reply.status >= 200 && reply.status < 300) {
            if (fs.writefile(destination, reply.body) != length(reply.body)) die('ошибка записи HTTP');
            reply.body = '';
        }
        return reply;
    }
    uloop.init();
    let client = null, deadline = null, redirects = 0, total = 0;
    let file = destination != null ? fs.open(destination, 'wx', 0600) : null;
    if (destination != null && file == null) die('не удалось создать файл загрузки');
    let current = url, headers = {}, status = 0, chunks = [], problem = '', complete = false;
    function stop(message) { problem = message; uloop.end(); }
    function consume() {
        // The oldest supported uclient uses a fixed 4096-byte C read buffer.
        for (let chunk = client.read(4096); chunk != null && length(chunk); chunk = client.read(4096)) {
            total += length(chunk);
            if (total > limit) { stop('ответ HTTP превышает лимит размера'); return; }
            if (file != null) {
                if (file.write(chunk) != length(chunk)) { stop('ошибка записи HTTP'); return; }
            }
            else if (!discard) push(chunks, chunk);
        }
    }
    try {
        client = uclient.new(url, null, {
            header_done: () => {
                let info = client.status();
                status = info.status; headers = {};
                for (let name, value in client.get_headers()) headers[lc(name)] = value;
                if (!info.redirect) {
                    let size = headers['content-length'];
                    if (size != null && (!match(size, /^[0-9]+$/) || +size > limit)) stop('ответ HTTP превышает лимит размера');
                    return;
                }
                let location = headers.location;
                if (type(location) != 'string' || ++redirects > 3) { stop('слишком много перенаправлений HTTP'); return; }
                if (substr(location, 0, 2) == '//') location = split(current, ':')[0] + ':' + location;
                else if (substr(location, 0, 1) == '/') {
                    let origin = match(current, /^(https?:\/\/[^/]+)/);
                    location = origin[1] + location;
                }
                else if (!match(location, /^https?:\/\//)) {
                    let origin = match(current, /^(https?:\/\/[^/]+)(\/.*)?$/);
                    let path = split(origin[2] || '/', '?')[0];
                    location = origin[1] + fs.dirname(path) + '/' + location;
                }
                if (!http_valid_url(location, allow_http) || (substr(current, 0, 6) == 'https:' && substr(location, 0, 6) != 'https:')) {
                    stop('небезопасное перенаправление HTTP'); return;
                }
                current = location; chunks = []; total = 0;
                if (file != null) { file.close(); file = fs.open(destination, 'w', 0600); if (file == null) { stop('ошибка файла HTTP'); return; } }
                if (!client.set_url(location) || !client.connect() ||
                    !client.request('GET', { headers: { 'User-Agent': 'zify', Accept: '*/*' } }))
                    stop('ошибка перенаправления HTTP');
            },
            data_read: consume,
            data_eof: () => { consume(); complete = client.status().data_eof == true; uloop.end(); },
            error: (handle, code) => stop('ошибка HTTP transport: ' + code)
        });
        if (client == null) die('не удалось создать HTTP client');
        let ca = getenv('SSL_CERT_FILE') || '/etc/ssl/certs/ca-certificates.crt';
        if (!client.ssl_init({ verify: true, ca_files: [ca] }))
            die('не удалось включить проверку сертификата HTTPS');
        if (!client.set_timeout(ctx.connect_timeout * 1000)) die('не удалось задать таймаут HTTP');
        deadline = uloop.timer(ctx.request_timeout * 1000, () => stop('истёк таймаут HTTP'));
        if (!client.connect() || !client.request('GET', { headers: { 'User-Agent': 'zify', Accept: '*/*' } }))
            die('не удалось подключиться к HTTP server');
        uloop.run();
        deadline.cancel();
        client.disconnect(); client.free(); client = null;
        if (length(problem)) die(problem);
        if (!complete || status < 100 || status > 599) die('неполный ответ HTTP');
        if (file != null) { file.close(); file = null; }
        return { status, headers, body: join('', chunks) };
    }
    catch (e) {
        if (file != null) file.close();
        if (destination != null) fs.unlink(destination);
        if (deadline != null) deadline.cancel();
        if (client != null) { client.disconnect(); client.free(); }
        die(e.message);
    }
};

// ---- src/lib/mutations.uc ----

function tx_check(ok, message) { if (!ok) die(message); }

function tx_lock(ctx) {
    let path = ctx.root + '/tmp/zify.zapret.lock';
    tx_check(getenv('ZIFY_TRANSACTION') == path && fs.stat(path + '/ready')?.type == 'file', 'нет активной транзакции');
    return path;
}

function tx_write(path, text) {
    tx_check(fs.writefile(path, text) == length(text), 'ошибка записи: ' + path);
}

function tx_marker(ctx, name) { tx_write(tx_lock(ctx) + '/' + name, '1\n'); }

function tx_append(path, text) {
    let previous = fs.stat(path)?.size || 0;
    let journal = fs.open(path, 'a');
    tx_check(journal != null, 'не удалось открыть журнал: ' + path);
    let count = journal.write(text);
    journal.close();
    tx_check(count == length(text) && fs.stat(path)?.size == previous + length(text), 'ошибка записи журнала: ' + path);
}

function tx_changed(ctx, path) {
    tx_append(tx_lock(ctx) + '/changed', path + '\n');
    invalidate(ctx);
}

function tx_directory(path, mode) {
    let st = fs.lstat(path);
    if (st != null) { tx_check(st.type == 'directory', 'каталог заменён ссылкой или файлом: ' + path); return; }
    tx_directory(fs.dirname(path), mode);
    tx_check(fs.mkdir(path, mode ?? 0700), 'не удалось создать каталог: ' + path);
    if (mode != null) tx_check(fs.chmod(path, mode), 'не удалось задать права каталога: ' + path);
}

function tx_token() {
    let token = trim(fs.readfile('/proc/sys/kernel/random/uuid', 64) || '');
    tx_check(match(token, /^[a-f0-9-]{36}$/), 'не удалось получить случайное имя');
    return token;
}

function tx_allowed(ctx, path) {
    let prefix = ctx.state + '/', base = ctx.base + '/';
    return (substr(path, 0, length(prefix)) == prefix && !match(substr(path, length(prefix)), /(^|\/)\.\.?(\/|$)/)) ||
        path == ctx.root + '/etc/config/zify' || path == ctx.config || path == ctx.base + '/config' ||
        path == ctx.root + '/etc/config/firewall' || path == ctx.root + '/etc/crontabs/root' ||
        path == ctx.root + '/usr/bin/zify' || path == ctx.root + '/usr/bin/zify.previous' ||
        substr(path, 0, length(base)) == base || substr(path, 0, length(ctx.root + '/tmp/')) == ctx.root + '/tmp/';
}

function tx_same(path, body) {
    let st = fs.lstat(path);
    return st?.type == 'file' && st.size == length(body) && fs.readfile(path, st.size + 1) == body;
}

// Configuration payloads stay in this process. Only safety primitives absent from
// stable fs (statvfs, link, timestamp-preserving snapshot) go to the supervisor.
function tx_put(ctx, path, body, mode, safety) {
    tx_lock(ctx);
    tx_check(tx_allowed(ctx, path) && index(path, '\x00') == -1 && !match(path, /[\r\n]|(^|\/)\.\.?(\/|$)/), 'запись вне разрешённых путей');
    let old = fs.lstat(path), permissions = mode != null ? mode : (old?.type == 'file' ? old.mode & 0777 : 0600);
    if (tx_same(path, body) && (old.mode & 0777) == permissions) return false;
    safety(ctx, 'check-space', [int((length(body) + 1023) / 1024)]);
    tx_directory(fs.dirname(path));
    // Refuse parent-directory links: rename must publish inside the managed tree.
    let parent = fs.dirname(path);
    tx_check(fs.realpath(parent) == parent, 'каталог записи выходит за разрешённый путь: ' + parent);
    let temporary = parent + '/.zify-' + tx_token();
    safety(ctx, 'snapshot-path', [path]);
    tx_append(tx_lock(ctx) + '/staged.paths', temporary + '\n');
    let file = fs.open(temporary, 'wx', 0600);
    tx_check(file != null, 'не удалось создать временный файл: ' + temporary);
    try {
        let count = file.write(body);
        file.close(); file = null;
        tx_check(count == length(body) && fs.stat(temporary)?.size == length(body), 'ошибка записи: ' + temporary);
        if (old?.type == 'file') tx_check(fs.chown(temporary, old.uid, old.gid), 'не удалось сохранить владельца: ' + path);
        tx_check(fs.chmod(temporary, permissions), 'не удалось сохранить права: ' + path);
        tx_changed(ctx, path);
        tx_check(fs.rename(temporary, path), 'не удалось атомарно заменить: ' + path);
    }
    catch (e) { if (file != null) file.close(); fs.unlink(temporary); die(e.message); }
    return true;
}

function tx_remove(ctx, path, safety) {
    tx_check(tx_allowed(ctx, path), 'удаление вне разрешённых путей');
    if (fs.lstat(path) == null) return false;
    safety(ctx, 'snapshot-path', [path]);
    tx_changed(ctx, path);
    tx_check(fs.unlink(path), 'не удалось удалить: ' + path);
    return true;
}

function tx_service(ctx, action) {
    tx_check(index(['start', 'stop', 'restart', 'enable', 'disable'], action) != -1, 'неверное действие сервиса');
    let init = ctx.root + '/etc/init.d/zapret';
    tx_check(fs.access(init, 'x'), 'не найден init-скрипт: ' + init);
    tx_lock(ctx);
    if (index(['start', 'stop', 'restart'], action) != -1) {
        tx_marker(ctx, 'service.touched');
        tx_changed(ctx, ctx.config);
        tx_changed(ctx, ctx.base + '/config');
    }
    else tx_marker(ctx, 'service.touched');
    let sync = ctx.base + '/sync_config.sh';
    if ((action == 'start' || action == 'restart') && fs.stat(sync))
        tx_check(execute(['/bin/sh', sync]) == 0, 'ошибка sync_config.sh');
    // These scripts belong to Zapret/procd; the manager adds no shell dispatcher.
    tx_check(execute([init, action]) == 0, 'сервис zapret: ошибка ' + action);
    invalidate(ctx);
}

function tx_config(ctx, args, safety) {
    tx_lock(ctx);
    tx_check(length(args) > 0 && length(args) % 2 == 0, 'нужны пары опция/значение');
    for (let i = 0; i < length(args); i += 2)
        tx_check(match(args[i], /^[A-Za-z][A-Za-z0-9_]*$/), 'неверное имя опции');
    let handle = config_cursor(ctx, true);
    tx_check(handle.load('zapret') && handle.get('zapret', '@main[0]') == 'main', 'основная секция конфига не найдена');
    let changed = false;
    for (let i = 0; i < length(args); i += 2) {
        if (handle.get('zapret', '@main[0]', args[i]) == args[i + 1]) continue;
        tx_check(handle.set('zapret', '@main[0]', args[i], args[i + 1]), 'ошибка UCI set: ' + uci.error());
        changed = true;
    }
    if (!changed) return;
    safety(ctx, 'check-space', [int(((fs.stat(ctx.config)?.size || 0) + length(join('', args)) + 1023) / 1024)]);
    tx_changed(ctx, ctx.config);
    tx_check(handle.commit('zapret'), 'ошибка UCI commit: ' + uci.error());
}

function tx_flow(ctx, mode, safety) {
    tx_check(index(['disable', 'none', 'software', 'hardware', 'donttouch', 'restore'], mode) != -1, 'неверный режим FLOWOFFLOAD');
    tx_lock(ctx);
    if (mode == 'disable') mode = 'none';
    let values = config_values(ctx, 'firewall', '@defaults[0]');
    let installed = fs.stat(ctx.config) != null;
    tx_check(installed || mode == 'restore', 'Zapret не установлен');
    let zapret = installed ? config_values(ctx, 'zapret', '@main[0]') : {};
    let original_mode = zapret.FLOWOFFLOAD ?? 'x';
    tx_check(index(['x', '', 'donttouch', 'none', 'software', 'hardware'], original_mode) != -1, 'неверный FLOWOFFLOAD Zapret');
    let before = [values.flow_offloading ?? 'x', values.flow_offloading_hw ?? 'x', original_mode == '' ? 'empty' : original_mode];
    for (let value in slice(before, 0, 2)) tx_check(index(['0', '1', 'x'], value) != -1, 'неверный системный offload');
    let next = mode == 'donttouch' ? [before[0], before[1], mode] : ['0', '0', mode];
    let saved = ctx.state + '/offload.previous';
    if (mode == 'restore') {
        let body = fs.readfile(saved, 64), parts = body == null ? [] : split(trim(body), '\n');
        tx_check(length(parts) == 2 || length(parts) == 3, 'нет сохранённых настроек Flow Offloading');
        for (let value in slice(parts, 0, 2)) tx_check(index(['0', '1', 'x'], value) != -1, 'повреждены сохранённые настройки');
        if (length(parts) == 2) push(parts, before[2]);
        tx_check(index(['x', 'empty', 'donttouch', 'none', 'software', 'hardware'], parts[2]) != -1, 'повреждён сохранённый FLOWOFFLOAD');
        next = parts;
    }
    if (mode == 'software' || mode == 'hardware') {
        let sync = fs.readfile(ctx.base + '/sync_config.sh', 65536) || '';
        let nft = fs.readfile(ctx.base + '/common/nft.sh', 262144) || '';
        tx_check(match(sync, /(^|\n)[ \t]*sync_param FLOWOFFLOAD([ \t]|\r?\n|$)/) && index(nft, 'nft_apply_flow_offloading') != -1,
            'установленный Zapret не поддерживает штатное выборочное ускорение; обновите пакет');
    }
    let system_changed = before[0] != next[0] || before[1] != next[1];
    let zapret_changed = installed && before[2] != next[2];
    if (!system_changed && !zapret_changed) {
        if (mode == 'restore') tx_remove(ctx, saved, safety);
        return;
    }
    let reply = native_running(ctx), running = false;
    tx_check(type(reply) == 'object' && (reply.zapret == null || type(reply.zapret.instances) == 'object'), 'не удалось проверить сервис Zapret');
    if (reply.zapret != null) for (let name, instance in reply.zapret.instances) if (instance.running == true) running = true;
    if (mode != 'restore' && fs.lstat(saved) == null) tx_put(ctx, saved, join('\n', before) + '\n', null, safety);
    if (zapret_changed) {
        if (next[2] == 'x') {
            let handle = config_cursor(ctx, true);
            tx_check(handle.load('zapret') && handle.delete('zapret', '@main[0]', 'FLOWOFFLOAD'), 'не удалось восстановить FLOWOFFLOAD');
            safety(ctx, 'check-space', [int(((fs.stat(ctx.config)?.size || 0) + 1023) / 1024)]);
            tx_changed(ctx, ctx.config);
            tx_check(handle.commit('zapret'), 'не удалось сохранить Zapret');
        }
        else tx_config(ctx, ['FLOWOFFLOAD', next[2] == 'empty' ? '' : next[2]], safety);
    }
    if (system_changed) {
        let handle = config_cursor(ctx, true);
        tx_check(handle.load('firewall'), 'firewall OpenWrt не найден');
        for (let i = 0; i < 2; i++) {
            let key = i == 0 ? 'flow_offloading' : 'flow_offloading_hw';
            if (next[i] == 'x') {
                if (handle.get('firewall', '@defaults[0]', key) != null)
                    tx_check(handle.delete('firewall', '@defaults[0]', key), 'ошибка восстановления offload');
            }
            else tx_check(handle.set('firewall', '@defaults[0]', key, next[i]), 'ошибка настройки offload');
        }
        safety(ctx, 'check-space', [int(((fs.stat(ctx.root + '/etc/config/firewall')?.size || 0) + 4095) / 1024)]);
        tx_marker(ctx, 'firewall.touched'); tx_marker(ctx, 'firewall.restart');
__ZIFY_ZIFY_UCODE_1__
)
export ZIFY_UCODE_1

ZIFY_UCODE_2=$(cat <<'__ZIFY_ZIFY_UCODE_2__'
tx_changed(ctx, ctx.root + '/etc/config/firewall');
        tx_check(handle.commit('firewall'), 'ошибка UCI commit firewall');
        tx_check(execute([ctx.root + '/etc/init.d/firewall', 'restart']) == 0, 'ошибка перезапуска firewall');
    }
    // Zapret's init/sync scripts build their own exemptions and flowtable.
    if (running) tx_service(ctx, 'restart');
    if (mode == 'restore') tx_remove(ctx, saved, safety);
    invalidate(ctx);
}

function tx_firewall(ctx, args, safety) {
    if (args[0] == 'status') {
        let state = cached(ctx, 'firewall-status', () => {
            let handle = config_cursor(ctx, false);
            tx_check(handle.load('firewall'), 'firewall OpenWrt не найден');
            let values = handle.get_all('firewall', '@defaults[0]');
            tx_check(values != null, 'не найдена основная секция firewall');
            return { values, blocked: handle.get('firewall', 'zify_quic', 'name') == 'ZIFY_Block_QUIC' };
        });
        report(sprintf('Программный Flow Offloading: %s\nАппаратный Flow Offloading: %s\nQUIC: %s\n',
            state.values.flow_offloading || '0', state.values.flow_offloading_hw || '0',
            state.blocked ? 'заблокирован zify' : 'zify не блокирует'));
        return;
    }
    if (args[0] == 'offload') { tx_flow(ctx, args[1], safety); return; }
    let handle = config_cursor(ctx, true);
    tx_check(handle.load('firewall'), 'firewall OpenWrt не найден');
    tx_lock(ctx);
    {
        tx_check(args[0] == 'quic' && index(['on', 'off'], args[1]) != -1, 'неверная настройка совместимости');
        let existing = handle.get('firewall', 'zify_quic', 'name');
        tx_check(existing == null || existing == 'ZIFY_Block_QUIC', 'имя правила zify_quic уже занято');
        if (args[1] == 'off') { if (handle.get('firewall', 'zify_quic') != null)
            tx_check(handle.delete('firewall', 'zify_quic'), 'ошибка удаления правила QUIC'); }
        else {
            tx_check(handle.set('firewall', 'zify_quic', 'rule'), 'ошибка создания правила QUIC');
            for (let key, value in { name: 'ZIFY_Block_QUIC', src: 'lan', dest: 'wan', proto: 'udp', dest_port: '80 443', target: 'REJECT', family: 'any' })
                tx_check(handle.set('firewall', 'zify_quic', key, value), 'ошибка записи правила QUIC');
        }
    }
    safety(ctx, 'check-space', [int(((fs.stat(ctx.root + '/etc/config/firewall')?.size || 0) + 4095) / 1024)]);
    tx_marker(ctx, 'firewall.touched');
    tx_changed(ctx, ctx.root + '/etc/config/firewall');
    tx_check(handle.commit('firewall'), 'ошибка UCI commit firewall');
    tx_check(execute([ctx.root + '/etc/init.d/firewall', 'reload']) == 0, 'ошибка применения firewall');
}

function tx_remove_legacy_cron(ctx, safety) {
    let file = ctx.root + '/etc/crontabs/root', tag = '# zify:zapret';
    let original = fs.stat(file) ? fs.readfile(file, 65537) : '';
    tx_check(original != null && length(original) <= 65536 && index(original, '\x00') == -1, 'неверный crontab');
    let lines = split(original, '\n');
    if (lines[-1] == '') pop(lines);
    lines = filter(lines, (line) => substr(line, -length(tag)) != tag);
    let text = length(lines) ? join('\n', lines) + '\n' : '';
    if (text == original) return;
    tx_check(fs.access(ctx.root + '/etc/init.d/cron', 'x'), 'не найден cron');
    tx_put(ctx, file, text, null, safety);
    tx_check(execute([ctx.root + '/etc/init.d/cron', 'restart']) == 0, 'cron: ошибка перезапуска');
}

function tx_remove_tree(path, depth) {
    tx_check(depth < 32, 'слишком глубокий каталог удаления');
    let st = fs.lstat(path);
    if (st == null) return;
    if (st.type != 'directory') { tx_check(fs.unlink(path), 'не удалось удалить: ' + path); return; }
    let names = fs.lsdir(path);
    tx_check(names != null && length(names) <= 50000, 'не удалось прочитать каталог удаления: ' + path);
    for (let name in names) tx_remove_tree(path + '/' + name, depth + 1);
    tx_check(fs.rmdir(path), 'не удалось удалить каталог: ' + path);
}

function tx_uninstall(ctx, args, safety) {
    let mode = args[0];
    tx_check(index(['manager', 'all', 'components'], mode) != -1, 'неверный режим удаления');
    let selected = mode == 'components' ? slice(args, 1) : ['manager', 'config'];
    if (mode == 'all') push(selected, 'zapret', 'luci', 'files');
    let manager = index(selected, 'manager') != -1, files = index(selected, 'files') != -1;
    let config = index(selected, 'config') != -1, zapret = index(selected, 'zapret') != -1;
    if (!manager && !zapret) return;
    tx_lock(ctx);
    safety(ctx, 'snapshot-uninstall', [files ? 'all' : 'manager']);
    if (fs.stat(ctx.state + '/offload.previous')) tx_firewall(ctx, ['offload', 'restore'], safety);
    if (fs.stat(ctx.root + '/etc/config/firewall')) {
        let handle = config_cursor(ctx, false);
        if (handle.get('firewall', 'zify_quic', 'name') == 'ZIFY_Block_QUIC') tx_firewall(ctx, ['quic', 'off'], safety);
    }
    tx_remove_legacy_cron(ctx, safety);
    let hook = ctx.base + '/init.d/openwrt/custom.d/20-zify-exclude.sh';
    if (!files) {
        if (manager && tx_remove(ctx, hook, safety)) {
            let saved = ctx.state + '/legacy-exclusion-hook.sh', legacy = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
            if (fs.stat(saved)) {
                tx_check(fs.lstat(legacy) == null, 'старый хук уже существует; удаление отменено');
                tx_put(ctx, legacy, fs.readfile(saved), null, safety);
            }
            if (fs.access(ctx.root + '/etc/init.d/zapret', 'x')) {
                let reply = native_running(ctx), running = false;
                tx_check(type(reply) == 'object' && (reply.zapret == null || type(reply.zapret.instances) == 'object'),
                    'не удалось проверить сервис перед удалением');
                if (reply.zapret != null)
                    for (let name, instance in reply.zapret.instances) if (instance.running == true) running = true;
                if (running) tx_service(ctx, 'restart');
            }
        }
    }
    else {
        tx_remove(ctx, ctx.config, safety);
        if (fs.lstat(ctx.base)) { tx_changed(ctx, ctx.base); tx_remove_tree(ctx.base, 0); }
    }
    if (manager) {
        tx_remove(ctx, ctx.root + '/usr/bin/zify', safety);
        tx_remove(ctx, ctx.root + '/usr/bin/zify.previous', safety);
    }
    if (config) {
        tx_remove(ctx, ctx.root + '/etc/config/zify', safety);
        if (fs.lstat(ctx.state)) { tx_changed(ctx, ctx.state); tx_remove_tree(ctx.state, 0); }
    }
}

function native_send(ctx, action, args, text, safety) {
    let path;
    switch (action) {
    case 'hosts-write': path = host_path(ctx, args[0]); break;
    case 'state-write':
        tx_check(match(args[0], /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/), 'неверное имя файла');
        path = ctx.state + '/' + args[0]; break;
    case 'device-hook-write': {
        let legacy = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
        let saved = ctx.state + '/legacy-exclusion-hook.sh';
        if (args[0] == 'migrate') {
            if (fs.lstat(saved) == null) tx_put(ctx, saved, fs.readfile(legacy), null, safety);
            tx_remove(ctx, legacy, safety);
        }
        tx_put(ctx, ctx.base + '/init.d/openwrt/custom.d/20-zify-exclude.sh', text, 0755, safety);
        return true;
    }
    case 'manager-install': {
        let destination = args[0];
        tx_check(destination == ctx.root, 'путь установки не совпадает с транзакцией');
        // Validation executes the bundle's own version entry; no live files are touched yet.
        let lock = tx_lock(ctx), temporary = lock + '/manager-candidate';
        tx_write(temporary, text);
        safety(ctx, 'manager-validate', [temporary]);
        tx_remove_legacy_cron(ctx, safety);
        let target = ctx.root + '/usr/bin/zify';
        if (fs.stat(target)) tx_put(ctx, target + '.previous', fs.readfile(target), 0755, safety);
        tx_put(ctx, target, text, 0755, safety);
        fs.unlink(temporary);
        return true;
    }
    case 'manager-config-init':
        tx_check(args[0] == ctx.root, 'путь установки не совпадает с транзакцией');
        path = ctx.root + '/etc/config/zify';
        if (fs.lstat(path)) return true;
        break;
    case 'state-assets-manifest': path = ctx.assets + '/manifest.json'; break;
    default: return false;
    }
    tx_put(ctx, path, text, null, safety);
    return true;
};

function native_action(ctx, action, args, safety) {
    switch (action) {
    case 'config-set': tx_config(ctx, args, safety); return true;
    case 'service': tx_service(ctx, args[0]); return true;
    case 'network': tx_firewall(ctx, args, safety); return true;
    case 'asset-file': {
        tx_check(length(args) == 2, 'неверная запись ассета');
        let target = args[1], asset_prefix = ctx.assets + '/';
        tx_check((substr(target, 0, length(asset_prefix)) == asset_prefix && !match(target, /(^|\/)\.\.?(\/|$)/)) ||
            (target == ctx.base + '/fakes/' + fs.basename(target) &&
             match(fs.basename(target), /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/)), 'путь вне ассетов');
        let st = fs.stat(args[0]);
        tx_check(st?.type == 'file' && st.size <= ctx.max_file_bytes, 'неверный размер ассета');
        let body = fs.readfile(args[0], ctx.max_file_bytes + 1);
        tx_check(body != null && length(body) == st.size, 'ошибка чтения ассета');
        if (substr(target, 0, length(ctx.base + '/fakes/')) == ctx.base + '/fakes/')
            tx_directory(fs.dirname(target), 0755);
        tx_put(ctx, target, body, 0644, safety);
        return true;
    }
    case 'manager-install': {
        let text = fs.readfile(args[0], ctx.max_file_bytes + 1);
        tx_check(text != null && length(text) <= ctx.max_file_bytes, 'не удалось прочитать обновление');
        return native_send(ctx, action, [args[1]], text, safety);
    }
    case 'uninstall-cleanup': tx_uninstall(ctx, args, safety); return true;
    case 'manager-uninstall':
        tx_remove(ctx, ctx.root + '/usr/bin/zify', safety);
        tx_remove(ctx, ctx.root + '/usr/bin/zify.previous', safety);
        return true;
    }
    return false;
};

// ---- src/lib/common.uc ----

function check(condition, message) {
    if (!condition) die(message);
};

function approve(ctx, question) {
    if (ctx.assume_yes) return true;
    check(fs.stdin.isatty(), 'требуется подтверждение: используйте -y/--yes без TTY');
    let channel = getenv('ZIFY_MENU_PROMPT_FD') == '9' ? fs.open('/proc/self/fd/9', 'w') : null;
    let target = channel || fs.stderr;
    target.write(question + '? [y/N] '); target.flush();
    if (channel) channel.close();
    let answer = '';
    while (true) {
        let c = fs.stdin.read(1);
        if (c == null || !length(c)) return false;
        if (c == '\n') break;
        if (c != '\r') answer += c;
        check(length(answer) <= 4096, 'слишком длинное подтверждение');
    }
    return lc(trim(answer)) == 'y';
};

function tempdir() {
    // mkdir is the exclusive allocation primitive available on every supported ucode.
    for (let attempt = 0; attempt < 8; attempt++) {
        let token = trim(fs.readfile('/proc/sys/kernel/random/uuid', 64) || '');
        check(match(token, /^[a-f0-9-]{36}$/), 'не удалось получить случайное имя');
        let path = '/tmp/zify-io-' + token;
        if (fs.mkdir(path, 0700)) return path;
        check(fs.lstat(path) != null, 'невозможно создать временный каталог: ' + fs.error());
    }
    die('невозможно создать уникальный временный каталог');
};

function read(path, limit) {
    let st = fs.stat(path);
    check(st != null && st.type == 'file', 'не найден обычный файл: ' + path);
    check(st.size <= limit, 'слишком большой файл: ' + path);
    let value = fs.readfile(path, limit + 1);
    check(value != null && length(value) <= limit, 'ошибка чтения: ' + path);
    check(index(value, '\x00') == -1, 'NUL в текстовом файле: ' + path);
    return value;
};

function backend_command(ctx, action, args) {
    let cmd = getenv('ZIFY_BACKEND') ? ['/bin/sh', '-c', getenv('ZIFY_BACKEND'), 'zify-backend', action, ctx.root, ctx.profile] :
        ['/bin/sh', ctx.home + '/src/shell/backend.sh', action, ctx.root, ctx.profile];
    for (let arg in (args || [])) push(cmd, '' + arg);
    return cmd;
}

function safety_operation(ctx, action, args) {
    let rc = execute(backend_command(ctx, action, args));
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
}

function backend(ctx, action, args) {
    args = args || [];
    if (native_action(ctx, action, args, safety_operation)) return 0;
    if (action == 'status') {
        if (!fs.stat(ctx.root + '/etc/init.d/zapret')) report('zapret: not installed\n');
        else {
            let reply = native_running(ctx), running = false;
            check(type(reply) == 'object', 'не удалось проверить состояние сервиса');
            if (reply.zapret != null) {
                check(type(reply.zapret.instances) == 'object', 'неверный ответ procd');
                for (let name, instance in reply.zapret.instances) if (instance.running == true) running = true;
            }
            report(running ? 'zapret: running\n' : 'zapret: stopped\n');
        }
        return 0;
    }
    if (action == 'transaction' || action == 'call') {
        let rc = execute(['env', 'ZIFY_REPORT_CHANGE=1', ...backend_command(ctx, action, args)]);
        if (rc == 10) { invalidate(ctx); return 0; }
        // An incomplete rollback is not the state represented by the old cache.
        if (rc != 0 && fs.stat(ctx.root + '/tmp/zify.zapret.lock/ready')) invalidate(ctx);
        return rc;
    }
    return execute(backend_command(ctx, action, args));
};

function transact(ctx, operation, args) {
    return backend(ctx, 'call', [operation, fs.stat(ctx.file) ? ctx.file : '', ...(args || [])]);
};

function run(ctx, action, args) {
    let rc = backend(ctx, action, args);
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
};

function output(ctx, action, args) {
    if (action == 'config-get' || action == 'config-get-optional')
        return config_option(ctx, args[0], action == 'config-get-optional');
    if (action == 'architecture') {
        let body = read(ctx.root + '/etc/openwrt_release', 65536);
        let arch = match(body, /(^|\n)DISTRIB_ARCH='([A-Za-z0-9_-]+)'(\n|$)/);
        check(arch != null, 'не удалось определить архитектуру OpenWrt');
        return arch[2] + '\n';
    }
    if (action == 'download' || action == 'github-download') {
        let reply;
        try { reply = http_request(ctx, args[3], +args[2], false); }
        catch (e) { die(action + ': код завершения 28: ' + e.message); }
        if (action == 'github-download')
            return reply.status + '\n' + (reply.headers['x-ratelimit-remaining'] || '') + '\n' + reply.body;
        check(reply.status >= 200 && reply.status < 300, 'ошибка HTTP ' + reply.status);
        return reply.body;
    }
    die('неизвестная операция чтения: ' + action);
};

function send(ctx, action, args, text) {
    check(native_send(ctx, action, args || [], text, safety_operation), 'неизвестная операция записи: ' + action);
};

function invoke(ctx, args) {
    return backend(ctx, 'transaction', [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]);
};

// ---- src/lib/settings.uc ----


function default_settings() {
    return { root: '/', connect_timeout: 4, request_timeout: 10,
        max_file_bytes: 2097152, max_strategies: 256 };
};

const SETTING_GROUPS = { main: ['root', 'connect_timeout', 'request_timeout', 'max_file_bytes', 'max_strategies'] };
const RETIRED_SETTINGS = ['settle_seconds', 'max_domains', 'max_urls'];

function settings_text(c) {
    let body = '';
    for (let section, options in SETTING_GROUPS) {
        let values = section == 'main' ? c : c[section];
        if (values == null) continue;
        body += "config " + (section == 'main' ? 'zify' : section) + " '" + section + "'\n";
        for (let option in options) {
            if (values[option] == null) continue;
            let value = '' + values[option];
            check(index(value, '\n') == -1 && index(value, '\r') == -1 && index(value, '\x00') == -1 && index(value, "'") == -1, 'неверное значение настройки: ' + option);
            body += "\toption " + option + " '" + value + "'\n";
        }
        body += '\n';
    }
    return body;
};

function read_settings(file) {
    let name = fs.basename(file);
    check(match(name, /^[A-Za-z0-9_-]+$/), 'имя UCI-файла: только буквы, цифры, _ и -');
    read(file, 65536);
    let handle = uci.cursor(fs.dirname(file), '/dev/null', '', { strict: true, print_errors: false });
    check(handle && handle.load(name), 'неверный UCI-конфиг zify: ' + file);
    let c = default_settings(), seen = {};
    check(handle.foreach(name, null, (section) => {
        let id = section['.name'];
        // Previous releases exposed repository settings; they no longer affect endpoints.
        if ((id == 'updater' || id == 'sources' || id == 'hostlist_urls') && section['.type'] == id) return;
        let options = SETTING_GROUPS[id];
        check(options != null && section['.type'] == (id == 'main' ? 'zify' : id) && !seen[id], 'неизвестная секция UCI: ' + id);
        seen[id] = true;
        let target = id == 'main' ? c : {};
        for (let key, value in section) {
            if (substr(key, 0, 1) == '.') continue;
            if (id == 'main' && index(RETIRED_SETTINGS, key) != -1) {
                check(type(value) == 'string' && match(value, /^[0-9]+$/), 'неверная устаревшая настройка: ' + key);
                continue;
            }
            check(index(options, key) != -1 && type(value) == 'string', 'неизвестная или списочная настройка: ' + key);
            if (id == 'main' && key != 'root') {
                check(match(value, /^[0-9]+$/) && length(value) <= 8, 'настройка должна быть числом: ' + key);
                value = +value;
            }
            target[key] = value;
        }
        if (id != 'main') c[id] = target;
    }), 'не удалось прочитать настройки UCI');
    check(seen.main, 'нет секции config zify main');
    handle.unload(name);
    return c;
};

function settings(home, file) {
    file = file || (fs.stat('/etc/config/zify') ? '/etc/config/zify' : null);
    let c = file ? read_settings(file) : default_settings();
    c.profile = 'zapret';
    check(type(c.root) == 'string' && match(c.root, /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/) &&
          !match(c.root, /(^|\/)\.\.?(\/|$)/), 'root: нужен абсолютный путь без . и ..');
    c.root = c.root == '/' ? '' : replace(c.root, /\/$/, '');
    for (let key in ['connect_timeout', 'request_timeout', 'max_file_bytes', 'max_strategies']) {
        check(type(c[key]) == 'int' && c[key] >= 1 &&
              c[key] <= (key == 'max_file_bytes' ? 8388608 : 50000), 'некорректная настройка: ' + key);
    }
    check(c.connect_timeout <= c.request_timeout && c.request_timeout <= 300 &&
          c.max_strategies <= 1024,
          'таймауты или лимиты превышены');
    c.home = home;
    c.file = file || c.root + '/etc/config/zify';
    c.config = c.root + '/etc/config/' + c.profile;
    c.base = c.root + '/opt/' + c.profile;
    c.state = c.root + '/etc/zify';
    c.assets = c.state + '/assets';
    c.resources = fs.stat(c.assets + '/resources') ? c.assets + '/resources' :
        (home != '/' ? home + '/data' : c.assets + '/resources');
    return c;
};

// ---- src/lib/strategies.uc ----

let general_cleanup = null, general_edges = null;

function strategy_key(name) {
    if (lc(substr(name || '', 0, 7)) != 'general') return name;
    let separator = substr(name, 7, 1);
    if (length(separator) && index('_.-', separator) == -1) return name;
    if (general_cleanup == null) { general_cleanup = /[^a-z0-9]+/g; general_edges = /^_|_$/g; }
    return replace(replace(lc(name), general_cleanup, '_'), general_edges, '');
};

function strategy_group(name) {
    let flow = match(name || '', /^(base|youtube|discord|games)_general(_|$)/);
    if (flow) return flow[1];
    if (match(name || '', /^v[0-9]+$/)) return 'base';
    if (match(name || '', /^Yv[0-9]+$/)) return 'youtube';
    if (match(name || '', /^Dv[0-9]+$/)) return 'discord';
    if (match(name || '', /^Gv[0-9]+$/)) return 'games';
    return null;
};

function strategy_title(name) {
    let key = strategy_key(name);
    if (key == 'general') return 'general (базовый)';
    let alt = match(key || '', /^general_alt([0-9]+)(.*)$/);
    return alt ? 'general (ALT' + alt[1] + replace(alt[2], /_/g, ' ') + ')' : key;
};

function strategy_order(left, right) {
    let a = strategy_key(left.name), b = strategy_key(right.name);
    if (a == b) return 0;
    if (a == 'general') return -1;
    if (b == 'general') return 1;
    let x = match(a, /^([^0-9]*)([0-9]+)(.*)$/), y = match(b, /^([^0-9]*)([0-9]+)(.*)$/);
    if (x && y && x[1] == y[1] && +x[2] != +y[2]) return +x[2] < +y[2] ? -1 : 1;
    return a < b ? -1 : 1;
};

function profile_group(block, include_voice) {
    if (index(block, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1) return 'youtube';
    if (index(block, '--hostlist-domains=discord.media') != -1 || (include_voice && index(block, '--filter-l7=discord,stun') != -1)) return 'discord';
    if (index(block, '--dpi-desync-any-protocol=1') != -1) return 'games';
    if (match(block, /^--filter-tcp=(80,)?443(\n|,)/)) return 'base';
    return null;
};

function validate_body(body) {
    check(length(body) > 0 && length(body) <= 32768, 'пустая или слишком большая стратегия');
    let lines = [], option_pattern = /^--[A-Za-z0-9][A-Za-z0-9_-]*(=[A-Za-z0-9_.,:\/+=@%{}!~-]+)?$/;
    for (let raw in split(body, '\n')) {
        let line = trim(raw);
        if (!length(line) || substr(line, 0, 1) == '#') continue;
        // Upstream expands NFQWS_OPT as shell words. Reject substitutions and quoting.
        check(match(line, option_pattern),
              'недопустимая строка стратегии: ' + line);
        push(lines, line);
    }
    check(length(lines) > 0 && lines[0] != '--new' && lines[-1] != '--new',
          'пустой блок стратегии');
    for (let i = 1; i < length(lines); i++)
        check(lines[i] != '--new' || lines[i - 1] != '--new', 'соседние --new');
    return join('\n', lines) + '\n';
};

function strategy_sections(body) {
    let sections = [], label = null, words = [];
__ZIFY_ZIFY_UCODE_2__
)
export ZIFY_UCODE_2

ZIFY_UCODE_3=$(cat <<'__ZIFY_ZIFY_UCODE_3__'
let marker_pattern = /^#([A-Za-z0-9][A-Za-z0-9_.-]*)$/, separators = /[[:space:]]+/;
    for (let raw in split(body || '', '\n')) {
        let line = trim(raw), marker = match(line, marker_pattern);
        if (marker && length(marker[1]) > 64) marker = null;
        if (marker) {
            if (label != null || length(words)) {
                // A delimiter immediately before the next heading joins presets.
                // All other --new tokens remain inside their original preset.
                let separated = words[-1] == '--new';
                if (separated) pop(words);
                push(sections, { label, body: length(words) ? join('\n', words) + '\n' : '', boundary_missing: !separated });
            }
            label = marker[1]; words = [];
            continue;
        }
        line = trim(split(line, '#')[0]);
        if (length(line)) for (let word in split(line, separators)) push(words, word);
    }
    if (label != null || length(words))
        push(sections, { label, body: length(words) ? join('\n', words) + '\n' : '', boundary_missing: false });
    return sections;
};

function preserve_body(body) {
    let sections = strategy_sections(body), result = [];
    check(length(sections), 'пустая стратегия');
    for (let section in sections) {
        check(!section.boundary_missing, 'между стратегиями требуется --new');
        let normalized = validate_body(section.body);
        push(result, (section.label != null ? '#' + section.label + '\n' : '') + normalized);
    }
    let value = join('--new\n', result);
    check(length(value) <= 32768, 'слишком большая стратегия с метками');
    return value;
};

function label_strategy(name, body) {
    check(type(name) == 'string' && length(name) <= 64 && match(name, /^[A-Za-z0-9][A-Za-z0-9_.-]*$/), 'неверное имя стратегии');
    return preserve_body('#' + strategy_key(name) + '\n' + validate_body(body));
};

function parse_catalog(ctx, text, wanted) {
    check(type(text) == 'string' && index(text, '\x00') == -1, 'неверный текст каталога');
    let sections = split('\n' + text, /\n[ \t\r]*#/), result = [], seen = {}, wanted_index = {};
    for (let name in (wanted || [])) wanted_index[name] = true;
    let name_pattern = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
    check(!length(trim(sections[0])), 'стрратегия без заголовка #имя');
    check(length(sections) > 1 && length(sections) - 1 <= ctx.max_strategies, 'лимит числа стратегий');
    // Native splitting visits only preset headers; inactive bodies need no interpreted line scan.
    for (let i = 1; i < length(sections); i++) {
        let section = sections[i], end = index(section, '\n');
        let name = trim(end == -1 ? section : substr(section, 0, end));
        check(length(name) <= 64 && match(name, name_pattern), 'неверное имя стратегии: ' + name);
        check(!seen[name], 'повтор стратегии: ' + name);
        seen[name] = true;
        if (wanted == null || wanted_index[strategy_key(name)] == true)
            push(result, { name, body: validate_body(end == -1 ? '' : substr(section, end + 1)) });
    }
    return result;
};

function catalog(ctx, file, wanted) {
    return cached(ctx, 'catalog:' + sprintf('%J', [file, wanted]), () => {
        let text = file ? read(file, ctx.max_file_bytes) : resource(ctx.resources, 'strategies.txt');
        return parse_catalog(ctx, text, wanted);
    });
};

function compose_bodies(bodies) {
    // nfqws selects the first matching profile: Google must precede broad TCP/443.
    let google = (body) => index(body, '--hostlist=/opt/zapret/ipset/zapret-hosts-google.txt') != -1;
    return preserve_body(join('--new\n', [...filter(bodies, google), ...filter(bodies, (body) => !google(body))]));
};

function compose(ctx, names, file) {
    check(length(names) > 0, 'укажите имена стратегий');
    let seen = {};
    for (let name in names) { check(!seen[name], 'повтор стратегии: ' + name); seen[name] = true; }
    let list = catalog(ctx, file, map(names, strategy_key)), by_name = {};
    for (let strategy in list) by_name[strategy.name] = strategy;
    return compose_bodies(map(names, (name) => {
        check(exists(by_name, name), 'стратегия не найдена: ' + name);
        return label_strategy(name, by_name[name].body);
    }));
};

function replace_group(current, replacement, group) {
    check(index(['base', 'youtube', 'discord', 'games'], group) != -1, 'неизвестная группа стратегии');
    let keep = [];
    for (let section in strategy_sections(current)) {
        let family = strategy_group(section.label);
        if (family == group) continue;
        if (family != null) {
            push(keep, '#' + section.label + '\n' + validate_body(section.body));
            continue;
        }
        let blocks = [];
        for (let block in split(validate_body(section.body), '--new\n')) {
            let voice = index(block, '--filter-l7=discord,stun') != -1;
            if (profile_group(block, match(replacement, /^#discord_general/)) == group || (!length(replacement) && group == 'discord' && voice)) continue;
            push(blocks, block);
        }
        if (length(blocks)) push(keep, (section.label != null ? '#' + section.label + '\n' : '') + join('--new\n', blocks));
    }
    if (length(replacement)) {
        if (group == 'youtube') keep = [preserve_body(replacement), ...keep];
        else push(keep, preserve_body(replacement));
    }
    return length(keep) ? preserve_body(join('--new\n', keep)) : '';
};

function remove_flowseal(current) {
    let keep = filter(strategy_sections(current), (s) => !match(strategy_key(s.label) || '', /^general(_|$)/));
    return length(keep) ? preserve_body(join('--new\n', map(keep,
        (s) => (s.label != null ? '#' + s.label + '\n' : '') + s.body))) : '';
};

// ---- src/lib/lists.uc ----

function validate_list_asset(text, limit, max_bytes) {
    // Assets preserve upstream's IP/CIDR, suffixes, Unicode and comments verbatim.
    // This is data copied to a fixed list path, never shell source or CLI arguments.
    check(type(text) == 'string' && length(text) <= max_bytes, 'слишком большой список в ассетов');
    check(index(text, '\x00') == -1 && !match(text, /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/),
        'управляющие байты в списке ассетов');
    // Search bounded byte windows in native code instead of interpreting every byte.
    // This preserves the byte limit for UTF-8 and never allocates a list of lines.
    let count = 0, size = length(text), nonblank = /[^ \t\r]/;
    for (let offset = 0; offset < size;) {
        let window = substr(text, offset, 1025), end = index(window, '\n');
        check(end != -1 || length(window) <= 1024, 'слишком длинная строка списка ассетов');
        let line = end == -1 ? window : substr(window, 0, end);
        if (match(line, nonblank)) count++;
        check(count <= limit, 'превышен лимит строк списка ассетов');
        offset += end == -1 ? length(window) : end + 1;
    }
    return true;
};

// ---- src/lib/devices.uc ----

function ipv4(value) {
    check(type(value) == 'string' && match(value, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/), 'неверный IPv4 адрес');
    let octets = split(value, '.');
    for (let part in octets) check(+part <= 255, 'октет IPv4 вне диапазона');
    return join('.', map(octets, (part) => '' + (+part)));
};

function legacy_addresses(body) {
    body = trim(replace(body, /\\\r?\n/g, ' '));
    if (!length(body)) return [];
    let lines = split(body, '\n');
    if (length(lines) != 2) return null;
    let m = match(lines[0], /^EXCEPT_SRC='\{ ([0-9., ]+) \}'$/);
    if (!m || replace(trim(lines[1]), /[[:space:]]+/g, ' ') !=
        'nft insert rule inet zapret postrouting_hook index 0 ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000') return null;
    let values = map(split(m[1], ','), (part) => ipv4(trim(part)));
    check(length(values) <= 256, 'слишком много старых исключений устройств');
    return values;
};

function compute_legacy_exclusions(ctx) {
    let path = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
    return fs.stat(path) ? legacy_addresses(read(path, 16384)) : null;
};

function legacy_exclusions(ctx) { return cached(ctx, 'legacy-devices', () => compute_legacy_exclusions(ctx)); };

function compute_excluded(ctx) {
    let path = ctx.state + '/devices.txt', result = [...(legacy_exclusions(ctx) || [])], seen = {};
    for (let ip in result) seen[ip] = true;
    let body = fs.stat(path) ? read(path, 16384) : '';
    for (let line in split(body, '\n')) {
        line = trim(line);
        if (length(line)) {
            let ip = ipv4(line);
            if (!seen[ip]) { seen[ip] = true; push(result, ip); }
        }
    }
    check(length(result) <= 256, 'слишком много исключённых устройств');
    return result;
};

function excluded(ctx) { return cached(ctx, 'devices', () => compute_excluded(ctx)); };

function compute_device_list(ctx) {
    let items = {}, path = ctx.root + '/tmp/dhcp.leases';
    if (fs.stat(path)) {
        for (let line in split(read(path, ctx.max_file_bytes), '\n')) {
            let fields = split(trim(line), /[[:space:]]+/);
            if (length(fields) < 4) continue;
            try {
                let ip = ipv4(fields[2]);
                items[ip] = { ip, name: fields[3] == '*' ? 'устройство' : replace(fields[3], /[^A-Za-z0-9_.:-]/g, '_') };
            }
            catch (e) { /* Incomplete DHCP rows do not become firewall rules. */ }
        }
    }
    for (let ip in excluded(ctx)) if (!exists(items, ip)) items[ip] = { ip, name: 'вне DHCP / offline' };
    return map(sort(keys(items)), (ip) => items[ip]);
};

function device_list(ctx) { return cached(ctx, 'device-list', () => compute_device_list(ctx)); };

function exclusion_hook(ctx, addresses) {
    let cfg = json(resource(ctx.resources, 'network.json'));
    for (let key in ['family', 'table', 'chain'])
        check(match(cfg[key], /^[A-Za-z_][A-Za-z0-9_]*$/), 'неверный параметр nft: ' + key);
    check(match(cfg.mark, /^0x[a-fA-F0-9]{1,8}$/), 'неверная метка nft');
    check(length(addresses) <= 256, 'слишком много исключений');
    addresses = map(addresses, (value) => ipv4(value));
    let rule = !length(addresses) ? '    exit 0\n' :
        '    zify_chain=$(nft -a list chain ' + cfg.family + ' ' + cfg.table + ' ' + cfg.chain + ') || exit 1\n' +
        '    case "$zify_chain" in *\'comment "zify_devices"\'*) exit 0;; esac\n' +
        '    nft insert rule ' + cfg.family + ' ' + cfg.table + ' ' + cfg.chain +
        " index 0 ip saddr '{ " + join(', ', addresses) + " }' meta mark set meta mark \\| " + cfg.mark +
        ' comment \'"zify_devices"\'\n';
    // custom_runner sources each file for daemon, firewall and flush callbacks.
    // Define the nft callback only; restore the caller's shell options after sourcing.
    return '#!/bin/sh\n# shellcheck disable=SC2329\nzify_exclusion_flags=$-\nset -eu\n' +
        'zapret_custom_firewall_nft() (\n    set -eu\n' + rule + ')\n' +
        'case "$zify_exclusion_flags" in *e*) :;; *) set +e;; esac\n' +
        'case "$zify_exclusion_flags" in *u*) :;; *) set +u;; esac\n' +
        'unset zify_exclusion_flags\n';
};

// ---- src/lib/applied.uc ----

// Exact text keys keep manual edits visible; bound the cache to four 64 KiB inputs.
let digest_cache = [];

function normalize_options(body) {
    let words = [], separators = /[[:space:]]+/;
    for (let raw in split(body || '', '\n')) {
        let line = trim(split(raw, '#')[0]);
        if (length(line)) for (let word in split(line, separators)) push(words, word);
    }
    return length(words) ? join('\n', words) + '\n' : '';
};

function sha256_text(text) {
    check(type(text) == 'string' && length(text) <= 65536 && index(text, '\x00') == -1, 'неверные данные для SHA256');
    for (let entry in digest_cache) if (entry.text == text) return entry.digest;
    let digest = sha256(text);
    check(type(digest) == 'string' && length(digest) == 64, 'не удалось вычислить SHA256');
    if (length(digest_cache) == 4) shift(digest_cache);
    push(digest_cache, { text, digest });
    return digest;
};

function strategy_hash(body) {
    return sha256_text(normalize_options(body));
};

function validate_applied(state) {
    check(type(state) == 'object' && type(state.name) == 'string' && length(state.name) > 0 &&
        length(state.name) <= 4096 && index(state.name, '\x00') == -1 && !match(state.name, /[\x01-\x1f\x7f]/) &&
        type(state.applied_hash) == 'string' && length(state.applied_hash) == 64 && match(state.applied_hash, /^[a-f0-9]+$/) &&
        type(state.applied_at) == 'int' && state.applied_at >= 0, 'повреждён state.json');
    if (state.sections != null) {
        let name_pattern = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/;
        check(type(state.sections) == 'array' && length(state.sections) <= 1024, 'неверный состав state.json');
        for (let section in state.sections) {
            check(type(section) == 'object' && (section.name == null || (type(section.name) == 'string' &&
                length(section.name) <= 64 && match(section.name, name_pattern))) &&
                type(section.omit) == 'array' && length(section.omit) <= 5, 'неверная секция state.json');
            for (let group in section.omit) check(index(['base', 'youtube', 'discord', 'games', 'voice'], group) != -1,
                'неверная группа state.json');
        }
    }
    return state;
};

function read_applied(ctx) {
    let path = ctx.state + '/state.json';
    return cached(ctx, 'applied', () => fs.stat(path) ? validate_applied(json(read(path, 65536))) : null);
};

function applied_names(state) {
    if (state == null) return [];
    return state.sections != null ? map(state.sections, (s) => strategy_key(s.name)) :
        map(split(state.name, /[ \t]*\+[ \t]*/), (name) => strategy_key(name));
};

function reference_index(list) {
    let result = {};
    for (let item in list) {
        let name = strategy_key(item.name);
        if (result[name] == null) result[name] = normalize_options(item.body);
    }
    return result;
}

function applied_profile_kind(block) {
    return profile_group(block) || (index(block, '--filter-l7=discord,stun') != -1 ? 'voice' : null);
}

function create_applied(body, sections, list, applied_at) {
    let refs = reference_index(list), recipe = [], names = [];
    for (let section in sections) {
        let name = strategy_key(section.name), omit = [];
        if (name != null && refs[name] != null && match(name, /^general(_|$)/)) {
            let current = map(split(normalize_options(section.body), '--new\n'), applied_profile_kind);
            let original = map(split(refs[name], '--new\n'), applied_profile_kind);
            for (let group in ['base', 'youtube', 'discord', 'games', 'voice'])
                if (index(original, group) != -1 && index(current, group) == -1) push(omit, group);
        }
        push(recipe, { name, omit });
        push(names, name || 'кастомный блок');
    }
    let name = length(filter(recipe, (s) => s.name != null)) ? join(' + ', names) : 'кастомная';
    if (!length(normalize_options(body))) name = 'не выбрана';
    return validate_applied({ name, applied_hash: strategy_hash(body), applied_at, sections: recipe });
};

function applied_catalog_hash(state, list) {
    if (state == null) return null;
    validate_applied(state);
    let refs = reference_index(list), bodies = [];
    let recipe = state.sections != null ? state.sections : map(applied_names(state), (name) => ({ name, omit: [] }));
    for (let section in recipe) {
        let ref = refs[strategy_key(section.name)];
        if (section.name == null || ref == null) return null;
        let blocks = filter(split(ref, '--new\n'), (block) => index(section.omit, applied_profile_kind(block)) == -1);
        if (length(blocks)) push(bodies, join('--new\n', blocks));
    }
    return strategy_hash(join('--new\n', bodies));
};

function applied_status(current_hash, state, catalog_hash, empty) {
    if (empty) return 'не выбрана';
    if (state == null || catalog_hash == null) return 'кастомная';
    validate_applied(state);
    let changed = current_hash != state.applied_hash, update = state.applied_hash != catalog_hash;
    if (changed && update) return state.name + ' (изменена вами, есть обновление)';
    if (changed) return state.name + ' (изменена пользователем)';
    return state.name + (update ? ' (доступно обновление)' : '');
};

// ---- src/lib/status.uc ----

function parse_packages(body, format) {
    let result = {};
    for (let record in split(replace(body, /\r/g, '') + '\n\n', /\n\n+/)) {
        if (index(record, 'zapret') == -1) continue;
        let package = match(record, format == 'apk' ? /(^|\n)P:([^\n]+)/ : /(^|\n)Package: *([^\n]+)/);
        if (!package || (package[2] != 'zapret' && package[2] != 'luci-app-zapret')) continue;
        let fields = {};
        for (let line in split(record, '\n')) {
            let m = match(line, /^([^:]+):[ \t]*(.*)$/);
            if (m) fields[m[1]] = m[2];
        }
        let name = fields[format == 'apk' ? 'P' : 'Package'];
        let version = fields[format == 'apk' ? 'V' : 'Version'];
        if (name != 'zapret' && name != 'luci-app-zapret') continue;
        if (format != 'apk' && !match(fields.Status || '', /(^| )installed$/)) continue;
        if (type(version) == 'string' && length(version) <= 100 && match(version, /^[A-Za-z0-9_.+~-]+$/)) result[name] = version;
    }
    return result;
};

function package_versions(ctx) {
    return cached(ctx, 'packages', () => {
        for (let item in [['/lib/apk/db/installed', 'apk'], ['/usr/lib/opkg/status', 'opkg']]) {
            let path = ctx.root + item[0], st = fs.stat(path);
            if (st == null) continue;
            check(st.type == 'file' && st.size <= 8388608, 'слишком большая пакетная база');
            let input = fs.open(path, 'r');
            check(input != null, 'не удалось открыть пакетную базу');
            let pending = '', result = {}, bytes = 0;
            try {
                for (let chunk = input.read(32768); chunk != null && length(chunk); chunk = input.read(32768)) {
                    bytes += length(chunk);
                    check(bytes <= 8388608, 'слишком большая пакетная база');
                    let records = split(pending + replace(chunk, /\r/g, ''), /\n\n+/);
                    pending = pop(records);
                    check(length(pending) <= 65536, 'слишком большая запись пакетной базы');
                    // Native chunk splitting skips descriptions without a per-line VM loop.
                    for (let name, version in parse_packages(join('\n\n', records), item[1])) result[name] = version;
                }
                check(bytes == st.size, 'ошибка чтения пакетной базы');
                for (let name, version in parse_packages(pending, item[1])) result[name] = version;
            }
            catch (e) { input.close(); die(e.message); }
            input.close();
            return result;
        }
        return {};
    });
};

function configured_strategy(ctx) {
    return cached(ctx, 'configured-strategy', () => {
        if (!fs.stat(ctx.config)) return '';
        let body = config_option(ctx, 'NFQWS_OPT', true);
        check(length(body) <= 65536, 'слишком большая стратегия UCI');
        return body;
    });
};

function normalized_strategy(body) {
    return join('--new\n', map(strategy_sections(body), (section) => section.body));
};

function inspect_strategy(body, list) {
    let sections = strategy_sections(body), references = [], by_name = {}, overrides = {};
    let wanted = {};
    for (let section in sections) wanted[strategy_key(section.label)] = true;
    let voice_override = false;
    let labelled = length(filter(sections, (s) => s.label == null)) == 0;
    for (let candidate in list) {
        let name = strategy_key(candidate.name);
        if (by_name[name] || (labelled && !wanted[name])) continue;
        let normalized = normalized_strategy(candidate.body);
        let ref = { name, body: normalized, parts: split(normalized, '--new\n') };
        by_name[name] = ref; push(references, ref);
    }
    // A named replacement accounts for precisely the profiles removed by the editor.
    // Arbitrary changes to the remaining Flowseal parameters still fail comparison.
    for (let section in sections) {
        let name = strategy_key(section.label), ref = by_name[name], group = strategy_group(name);
        if (group && ref && ref.body == section.body && !section.boundary_missing) {
            overrides[group] = true;
            if (match(name, /^discord_general/)) voice_override = true;
        }
    }
    let result = [];
    for (let section in sections) {
        if (section.label != null) {
            let name = strategy_key(section.label), ref = by_name[name];
            let exact = ref && ref.body == section.body;
            if (!exact && ref && match(name, /^general(_|$)/)) {
                let remaining = filter(split(ref.body, '--new\n'), (block) => !overrides[profile_group(block, voice_override)]);
                exact = join('--new\n', remaining) == section.body;
            }
            push(result, { name, body: section.body, changed: !exact || section.boundary_missing });
            continue;
        }
        // Legacy configs: match complete consecutive presets, preferring the longest.
        let blocks = split(section.body, '--new\n');
        for (let i = 0; i < length(blocks);) {
            let found = null, count = 0;
            for (let ref in references) {
                let parts = ref.parts;
                if (!length(ref.body) || length(parts) <= count || i + length(parts) > length(blocks)) continue;
                if (join('--new\n', slice(blocks, i, i + length(parts))) == ref.body) { found = ref; count = length(parts); }
            }
            push(result, { name: found ? found.name : null,
                body: join('--new\n', slice(blocks, i, i + (found ? count : 1))), changed: false });
            i += found ? count : 1;
        }
    }
    return result;
};

function identify_strategy(body, list, state) {
    if (!length(normalize_options(body))) return 'не выбрана';
    if (state == null) return 'кастомная';
    return applied_status(strategy_hash(body), state, applied_catalog_hash(state, list), false);
};

function reference_catalog(ctx, wanted) {
    let list = [];
    for (let kind in ['flowseal', 'manager']) {
        let path = ctx.assets + '/catalogs/' + kind + '.json';
        if (!fs.stat(path)) continue;
        try { list = [...list, ...parse_catalog(ctx, cached(ctx, 'source-document:' + path, () => json(read(path, ctx.max_file_bytes))).catalog, wanted)]; }
        catch (e) { /* Invalid cached presets cannot hide the actual configuration. */ }
    }
    return [...list, ...catalog(ctx, null, wanted)];
};

function compute_strategy_state(ctx, summary_only) {
    let body = configured_strategy(ctx), state = null;
__ZIFY_ZIFY_UCODE_3__
)
export ZIFY_UCODE_3

ZIFY_UCODE_4=$(cat <<'__ZIFY_ZIFY_UCODE_4__'
if (!length(normalize_options(body))) return { summary: 'не выбрана', sections: [] };
    try { state = read_applied(ctx); } catch (e) { /* An invalid baseline cannot establish provenance. */ }
    if (summary_only) {
        let names = applied_names(state);
        let list = length(filter(names, (name) => name != null)) ? reference_catalog(ctx, names) : [];
        return { summary: identify_strategy(body, list, state), sections: [] };
    }
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null :
        [...map(raw, (s) => strategy_key(s.label)), ...applied_names(state)];
    let list = reference_catalog(ctx, wanted);
    return { summary: identify_strategy(body, list, state), sections: inspect_strategy(body, list) };
};

function strategy_state(ctx, summary_only) {
    return cached(ctx, summary_only ? 'strategy-summary' : 'strategy-sections',
        () => compute_strategy_state(ctx, summary_only));
};

function procd_running(reply) {
    check(type(reply) == 'object', 'неверный ответ procd');
    if (reply.zapret == null) return false;
    check(type(reply.zapret.instances) == 'object', 'procd не вернул экземпляры Zapret');
    for (let key, instance in reply.zapret.instances) if (instance.running == true) return true;
    return false;
};

function service_running(ctx) {
    return cached(ctx, 'service-running', () => {
        try { return procd_running(native_running(ctx)); }
        catch (e) { return null; }
    });
};

function zapret_status(ctx) {
    let versions = package_versions(ctx), init = ctx.root + '/etc/init.d/zapret';
    let installed = versions.zapret != null || (fs.stat(init) != null && fs.stat(ctx.config) != null);
    let running = installed ? service_running(ctx) : false;
    let strategy = 'не выбрана';
    if (installed) {
        try { strategy = strategy_state(ctx, true).summary; }
        catch (e) { strategy = 'не удалось прочитать: ' + e.message; }
    }
    return { installed, running, version: versions.zapret || (installed ? 'неизвестна (без записи пакета)' : '—'),
        luci: versions['luci-app-zapret'] || null, strategy };
};

function release_compare(a, b) {
    let left = match(a, /^v?([0-9]+(\.[0-9]+)*)(-r[0-9]+)?$/);
    let right = match(b, /^v?([0-9]+(\.[0-9]+)*)(-r[0-9]+)?$/);
    check(left && right, 'не удалось сравнить версии Zapret; автоматическая переустановка отменена');
    left = split(left[1], '.'); right = split(right[1], '.');
    for (let i = 0; i < length(left) || i < length(right); i++) {
        let x = +(left[i] || 0), y = +(right[i] || 0);
        if (x != y) return x > y ? 1 : -1;
    }
    return 0;
};

function release_plan(versions, latest) {
    let core = versions.zapret, luci = versions['luci-app-zapret'];
    if (!core || release_compare(core, latest) < 0) return 'both';
    if (!luci || release_compare(luci, latest) < 0) {
        check(release_compare(core, latest) == 0, 'установлен более новый Zapret; подходящий LuCI отсутствует в этом релизе');
        return 'luci';
    }
    return 'none';
};

function flow_status(ctx) {
    return cached(ctx, 'flow-status', () => {
        let firewall = config_values(ctx, 'firewall', '@defaults[0]');
        let mode = fs.stat(ctx.config) ? trim(config_option(ctx, 'FLOWOFFLOAD', true)) : '';
        return { mode: mode || 'donttouch', software: firewall.flow_offloading == '1',
            hardware: firewall.flow_offloading_hw == '1', saved: fs.stat(ctx.state + '/offload.previous') != null };
    });
};

function quic_status(ctx) {
    return config_values(ctx, 'firewall', 'zify_quic', true).name == 'ZIFY_Block_QUIC';
};

// ---- src/lib/sources.uc ----

function source_file(ctx, kind) {
    check(kind == 'flowseal' || kind == 'manager', 'неизвестный источник');
    return ctx.assets + '/catalogs/' + kind + '.json';
};

function source_data(ctx, kind, wanted) {
    let file = source_file(ctx, kind);
    check(fs.stat(file) != null, 'каталог ассетов не установлен; переустановите zify с zify-assets.tar.gz');
    let value = cached(ctx, 'source-document:' + file, () => json(read(file, ctx.max_file_bytes)));
    check(value.format == 1 && value.source == kind && type(value.revision) == 'string' &&
          match(value.revision, /^[a-f0-9]{40}$/) && type(value.catalog) == 'string', 'повреждён каталог ассетов');
    let strategies = cached(ctx, 'source-presets:' + kind + ':' + sprintf('%J', wanted), () => parse_catalog(ctx, value.catalog, wanted));
    return { ...value, strategies: map(strategies, (s) => ({ ...s, missing: (value.unavailable || {})[s.name] || [] })) };
};

// ---- src/lib/assets.uc ----

function fake_filename(name) {
    check(type(name) == 'string' && length(name) <= 160 && match(name, /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/), 'неверное имя фейка');
    return name;
};

function installed_assets(ctx) {
    return cached(ctx, 'installed-assets', () => {
        let data = json(read(ctx.assets + '/manifest.json', 1048576));
        check(data.format == 1 && type(data.fakes) == 'array', 'повреждён манифест ассетов');
        return data;
    });
};

function asset_destination(ctx, entry) {
    check(type(entry) == 'object' && type(entry.size) == 'int' && entry.size >= 0 && entry.size <= ctx.max_file_bytes &&
        type(entry.sha256) == 'string' && match(entry.sha256, /^[a-f0-9]{64}$/), 'неверная запись ассета');
    let name = entry.name, expected, destination;
    if (entry.target == 'resource') {
        check(index(['zify', 'network.json', 'google.txt', 'exclude.txt', 'user.txt', 'strategies.txt'], name) != -1,
            'неизвестный ресурс');
        expected = 'resources/' + name; destination = ctx.assets + '/' + expected;
    }
    else if (entry.target == 'legal') {
        check(index(['LICENSE', 'NOTICE', 'Apache-2.0.txt', 'MIT.txt'], name) != -1 && entry.size > 0, 'неверный файл лицензии');
        expected = 'licenses/' + name; destination = ctx.assets + '/' + expected;
    }
    else if (entry.target == 'catalog') {
        check(name == 'flowseal.json' || name == 'manager.json', 'неверный каталог стратегий');
        expected = 'catalogs/' + name; destination = ctx.assets + '/' + expected;
    }
    else {
        fake_filename(name);
        check(entry.size > 0, 'пустой fake-ассет');
        check(entry.target == 'fake' && entry.source == 'flowseal', 'неверный тип или источник ассета');
        expected = 'fakes/' + name;
        destination = ctx.base + '/fakes/' + name;
    }
    check(entry.path == expected, 'путь ассета не совпадает с манифестом');
    return destination;
};

function asset_output(archive, member, destination, bytes) {
    let blocks = int((bytes + 511) / 512) + 1;
    check(execute(['/bin/sh', '-eu', '-c', 'ulimit -f "$4"; exec tar -xOzf "$1" "$2" > "$3"',
        'zify-assets', archive, member, destination, '' + blocks]) == 0, 'не удалось прочитать архив ассетов: ' + member);
}

function asset_snapshot(source, destination) {
    let input = fs.open(source, 'r'), output = fs.open(destination, 'wx', 0600), total = 0;
    check(input != null && output != null, 'не удалось подготовить архив');
    try {
        for (let chunk = input.read(65536); chunk != null && length(chunk); chunk = input.read(65536)) {
            total += length(chunk);
            check(total <= 8388608 && output.write(chunk) == length(chunk), 'архив слишком большой или повреждён');
        }
        input.close(); output.close();
    }
    catch (e) { input.close(); output.close(); die(e.message); }
}

function asset_unpack(archive, stage, sizes) {
    let listing = stage + '/members';
    check(execute(['/bin/sh', '-eu', '-c', 'ulimit -f 2048; exec tar -tvzf "$1" > "$2"',
        'zify-assets', archive, listing]) == 0, 'не удалось проверить содержимое архива');
    let names = {}, lines = split(read(listing, 1048576), '\n');
    for (let line in lines) {
        if (!length(line)) continue;
        let fields = split(trim(line), /[[:space:]]+/);
        // Both BusyBox and GNU tar list USTAR regular files as mode owner size date time path.
        check(length(fields) == 6 && match(fields[0], /^-[rwxStTs-]{9}$/) && match(fields[2], /^[0-9]+$/),
            'ссылки и специальные файлы в архиве запрещены');
        let name = fields[5];
        check(exists(sizes, name) && !exists(names, name) && +fields[2] == sizes[name], 'посторонний или повторный файл в архиве: ' + name);
        names[name] = true;
    }
    check(length(names) == length(sizes), 'архив не содержит все файлы манифеста');
    let unpacked = stage + '/unpacked';
    check(fs.mkdir(unpacked, 0700), 'не удалось создать каталог распаковки');
    // The private archive is immutable here; every name, type and expanded size was checked.
    check(execute(['tar', '-xzf', archive, '-C', unpacked]) == 0, 'ошибка распаковки ассетов');
    return unpacked;
}

function install_assets(ctx, archive, expected_version) {
    let lock = getenv('ZIFY_TRANSACTION');
    check(lock == ctx.root + '/tmp/zify.zapret.lock' && fs.stat(lock + '/ready'), 'нет транзакции установки ассетов');
    let st = fs.lstat(archive);
    check(st?.type == 'file' && st.size > 0 && st.size <= 8388608, 'неверный архив ассетов');
    let stage = lock + '/assets-stage';
    check(fs.mkdir(stage, 0700), 'не удалось создать staging ассетов');
    asset_snapshot(archive, stage + '/archive.tar.gz');
    archive = stage + '/archive.tar.gz';
    asset_output(archive, 'manifest.json', stage + '/manifest.json', 1048576);
    let manifest = json(read(stage + '/manifest.json', 1048576));
    check(manifest.format == 1 && manifest.version == (expected_version || VERSION) && type(manifest.files) == 'array' &&
        length(manifest.files) > 0 && length(manifest.files) <= 2048 && type(manifest.fakes) == 'array', 'несовместимый архив ассетов');
    let seen = {}, targets = {}, prepared = [], total = 0;
    let sizes = { 'manifest.json': fs.stat(stage + '/manifest.json').size };
    for (let entry in manifest.files) {
        let destination = asset_destination(ctx, entry);
        check(!exists(seen, entry.path) && !exists(targets, destination), 'повторный ассет в архиве');
        seen[entry.path] = true; targets[destination] = entry; sizes[entry.path] = entry.size;
        total += entry.size;
        check(total <= 16777216, 'ассеты превышают лимит распаковки 16 MiB');
        push(prepared, { entry, destination });
    }
    for (let name in ['zify', 'network.json', 'google.txt', 'exclude.txt', 'user.txt', 'strategies.txt'])
        check(seen['resources/' + name], 'архив не содержит обязательный ресурс: ' + name);
    for (let kind in ['flowseal', 'manager']) check(seen['catalogs/' + kind + '.json'], 'архив не содержит каталог: ' + kind);
    for (let name in ['LICENSE', 'NOTICE', 'Apache-2.0.txt', 'MIT.txt']) check(seen['licenses/' + name], 'архив не содержит лицензию: ' + name);
    let fake_ids = {};
    for (let fake in manifest.fakes) {
        check(type(fake) == 'object' && type(fake.path) == 'string', 'неверный fake в манифесте');
        let entry = targets[ctx.root + fake.path];
        check(entry?.target == 'fake' && entry.source == fake.source && entry.name == fake.name, 'фейк отсутствует в архиве');
        let id = fake.source + '/' + fake.name;
        check(!exists(fake_ids, id), 'повторный фейк в манифесте'); fake_ids[id] = true;
    }
    run(ctx, 'check-space', [int((total + 1023) / 1024)]);
    let unpacked = asset_unpack(archive, stage, sizes);
    // Validate all bytes before publishing the first managed file.
    for (let item in prepared) {
        item.file = unpacked + '/' + item.entry.path;
        let body = fs.readfile(item.file, ctx.max_file_bytes + 1);
        check(body != null && length(body) == item.entry.size && sha256(body) == item.entry.sha256,
            'контрольная сумма ассета не совпала: ' + item.entry.path);
        let entry = item.entry;
        if (entry.target == 'catalog') {
            let doc = json(body);
            check(doc.format == 1 && doc.source + '.json' == entry.name && type(doc.revision) == 'string' &&
                match(doc.revision, /^[a-f0-9]{40}$/) && type(doc.catalog) == 'string', 'неверный каталог ассетов');
            parse_catalog(ctx, doc.catalog);
        }
        if (entry.target == 'resource') {
            if (entry.name == 'zify') settings(ctx.home, item.file);
            else if (entry.name == 'network.json') {
                let cfg = json(body);
                for (let key in ['family', 'table', 'chain'])
                    check(type(cfg[key]) == 'string' && match(cfg[key], /^[A-Za-z_][A-Za-z0-9_]*$/), 'неверная конфигурация nft в ассетах');
                check(type(cfg.mark) == 'string' && match(cfg.mark, /^0x[a-fA-F0-9]{1,8}$/), 'неверная метка nft в ассетах');
            }
            else if (entry.name == 'strategies.txt') parse_catalog(ctx, body);
            else validate_list_asset(body, 50000, ctx.max_file_bytes);
        }
    }
    for (let item in prepared) {
        run(ctx, 'asset-file', [item.file, item.destination]);
    }
    send(ctx, 'state-assets-manifest', [], sprintf('%J\n', manifest));
    report(sprintf('Ассеты %s установлены: %d файлов.\n', manifest.version, length(prepared)));
};

// ---- src/lib/fakes.uc ----

function fake_catalog(ctx, kind) {
    check(kind == 'flowseal', 'неизвестный источник');
    return sort(map(filter(installed_assets(ctx).fakes, (entry) => entry.source == kind &&
        fs.stat(ctx.root + entry.path)?.type == 'file'), (entry) => entry.name));
};

// Canonicalizing first also handles UCI configurations written on one line.
function fake_slots(body) {
    if (!length(trim(body || ''))) return [];
    let slots = [], section = 'своя стратегия', profile = 1, global_profile = 1;
    let lines = split(preserve_body(body), '\n');
    for (let i = 0; i < length(lines); i++) {
        let line = lines[i];
        if (substr(line, 0, 1) == '#') { section = substr(line, 1); profile = 1; }
        if (line == '--new') { profile++; global_profile++; }
        let m = match(line, /^(--dpi-desync-[A-Za-z0-9_-]+)=(\/opt\/zapret\/(fakes|files\/fake)\/([A-Za-z0-9_][A-Za-z0-9_.-]*\.bin))$/);
        if (m && match(m[1], /^--dpi-desync-(fake-[A-Za-z0-9_-]+|[A-Za-z0-9_-]+-pattern)$/)) push(slots, { line: i, option: m[1], path: m[2], name: m[4], section, profile, global_profile });
    }
    return slots;
};

function current_fakes(ctx) {
    let entries = [];
    try { entries = installed_assets(ctx).fakes; } catch (e) { /* Unmanaged files remain visible. */ }
    let by_path = {};
    for (let entry in entries) by_path[entry.path] = entry;
    return map(fake_slots(configured_strategy(ctx)), (slot) => {
        let entry = by_path[slot.path], st = fs.stat(ctx.root + slot.path);
        return { ...slot, present: st?.type == 'file' && st.size > 0,
            source: entry?.source || 'не указан', filename: entry?.name || slot.name };
    });
};

// Group by full path: equal basenames in different directories are distinct files.
function group_fakes(slots) {
    let groups = [], by_path = {};
    for (let slot in slots) {
        if (by_path[slot.path] == null) {
            by_path[slot.path] = length(groups);
            push(groups, { path: slot.path, filename: slot.filename || slot.name,
                present: slot.present, source: slot.source, sections: [], slots: [] });
        }
        let group = groups[by_path[slot.path]];
        push(group.slots, slot);
        if (index(group.sections, slot.section) == -1) push(group.sections, slot.section);
    }
    return groups;
};

function replace_fake(body, line, expected, path) {
    check(type(line) == 'string' && match(line, /^[0-9]+$/), 'неверный номер фейка');
    let slot = filter(fake_slots(body), (s) => s.line == +line && s.path == expected)[0];
    check(slot != null, 'фейк уже изменён; откройте меню заново');
    check(match(path, /^\/opt\/zapret\/(fakes|files\/fake)\/[A-Za-z0-9_][A-Za-z0-9_.-]*\.bin$/), 'неверный путь фейка');
    let lines = split(preserve_body(body), '\n');
    lines[slot.line] = slot.option + '=' + path;
    return preserve_body(join('\n', lines));
};

function prepare_fake_replacement(ctx, line, expected, kind, name) {
    check(kind == 'flowseal', 'неизвестный источник');
    let body = configured_strategy(ctx);
    replace_fake(body, line, expected, expected);
    fake_filename(name);
    let selected = filter(installed_assets(ctx).fakes, (entry) => entry.source == kind && entry.name == name);
    check(length(selected) == 1, 'фейк отсутствует в установленных ассетах');
    let target = selected[0].path, st = fs.stat(ctx.root + target);
    check(st?.type == 'file' && st.size > 0, 'файл ассета отсутствует; переустановите архив ассетов');
    return replace_fake(body, line, expected, target);
};

// ---- src/lib/releases.uc ----

function github_response(response) {
    let first = index(response, '\n'), tail = substr(response, first + 1), next = index(tail, '\n');
    check(first == 3 && next != -1, 'неверный ответ HTTP от GitHub API');
    let second = first + 1 + next;
    let status = substr(response, 0, first), remaining = substr(response, first + 1, second - first - 1);
    let body = substr(response, second + 1);
    check(match(status, /^[1-5][0-9]{2}$/), 'неверный статус HTTP от GitHub API');
    check(!(status == '429' || (status == '403' && (remaining == '0' ||
        match(lc(body), /rate limit exceeded|secondary rate limit/)))),
        'Превышен лимит запросов GitHub API (60/час на ваш IP). Попробуйте позже или используйте встроенные стратегии');
    check(substr(status, 0, 1) == '2', 'GitHub API: ошибка HTTP ' + status);
    return body;
};

function remote(ctx, url) {
    if (substr(url, 0, 23) == 'https://api.github.com/')
        return github_response(output(ctx, 'github-download', [ctx.connect_timeout,
            ctx.request_timeout, ctx.max_file_bytes - 64, url]));
    return output(ctx, 'download', [ctx.connect_timeout, ctx.request_timeout, ctx.max_file_bytes, url]);
};

function release_install(ctx) {
    let release = json(remote(ctx, 'https://api.github.com/repos/' + INSTALLER_REPO + '/releases/latest'));
    check(type(release.tag_name) == 'string' && match(release.tag_name, /^v[0-9.]+$/) &&
          type(release.assets) == 'array', 'неверные данные релиза Zapret');
    let versions = package_versions(ctx);
    check(versions.zapret || !fs.stat(ctx.root + '/etc/init.d/zapret'),
        'Zapret найден без записи версии пакета; автоматическая переустановка отменена');
    let plan = release_plan(versions, release.tag_name);
    if (plan == 'none') { report('Zapret и LuCI актуальны. Новых версий нет, переустановка не требуется.\n'); return 'none'; }
    let arch = trim(output(ctx, 'architecture'));
    check(match(arch, /^[A-Za-z0-9_-]+$/), 'не удалось определить архитектуру OpenWrt');
    let name = 'zapret_' + release.tag_name + '_' + arch + '.zip';
    let selected = filter(release.assets, (a) => a.name == name);
    check(length(selected) == 1, 'нет сборки Zapret для архитектуры ' + arch);
    let url = 'https://github.com/' + INSTALLER_REPO + '/releases/download/' + release.tag_name + '/' + name;
    check(selected[0].browser_download_url == url && type(selected[0].size) == 'int' &&
        selected[0].size > 0 && selected[0].size <= 16777216, 'неверный файл релиза');
    let digest = selected[0].digest || '';
    check(digest == '' || match(digest, /^sha256:[a-f0-9]{64}$/), 'неверный SHA256 релиза');
    report(sprintf('Релиз Zapret: %s\n%s\n', release.tag_name, plan == 'luci' ?
        'Устанавливается недостающий LuCI-пакет для этой версии Zapret.' : 'Устанавливаются Zapret и luci-app-zapret.'));
    run(ctx, 'release-install', [url, substr(digest, 7), ctx.connect_timeout, ctx.request_timeout, plan, int((selected[0].size + 1023) / 1024)]);
    return plan;
};

// ---- src/lib/manager.uc ----

function newer_version(candidate, current) {
    check(type(candidate) == 'string' && match(candidate, /^[0-9]+\.[0-9]+(\.[0-9]+)?$/), 'неверная версия менеджера');
    let a = split(candidate, '.'), b = split(current, '.');
    for (let i = 0; i < 3; i++) {
        if (+(a[i] || 0) != +(b[i] || 0)) return +(a[i] || 0) > +(b[i] || 0);
    }
    return false;
};

function shell_value(name, body) {
    let marker = '__ZIFY_' + name + '__';
    return name + "=$(cat <<'" + marker + "'\n" + trim(body) + '\n' + marker + '\n)\nexport ' + name + '\n\n';
}

function render_bundle(ctx) {
    if (embedded_header() == null) {
        check(execute(['/bin/sh', ctx.home + '/tools/bundle.sh']) == 0, 'не удалось собрать zify');
        return read(ctx.home + '/dist/zify.sh', ctx.max_file_bytes);
    }
    let body = embedded_header() + shell_value('ZIFY_BACKEND', getenv('ZIFY_BACKEND'));
    let count = +getenv('ZIFY_PARTS');
    for (let i = 1; i <= count; i++) body += shell_value('ZIFY_UCODE_' + i, getenv('ZIFY_UCODE_' + i));
    return body + 'ZIFY_PARTS=' + count + '\nexport ZIFY_PARTS\n' + embedded_footer();
};

function install_manager(ctx, archive) {
    if (!getenv('ZIFY_TRANSACTION')) { check(transact(ctx, 'install', archive ? [archive] : []) == 0, 'не удалось установить менеджер'); return; }
    let destination = getenv('DESTDIR') || ctx.root;
    check(destination == '' || (match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/)), 'неверный DESTDIR');
    if (archive != null) install_assets(ctx, archive);
    send(ctx, 'manager-install', [destination], render_bundle(ctx));
    send(ctx, 'manager-config-init', [destination], settings_text(default_settings()));
    report(sprintf('Установлено: %s/usr/bin/zify\nКонфигурация: %s/etc/config/zify\n', destination, destination));
};

function update_origin() {
    return UPDATE_REPO + '/' + UPDATE_BRANCH + '/' + UPDATE_PATH;
}

function update_remote(ctx, url) {
    check(match(url, /^https:\/\/[A-Za-z0-9_.\/-]+$/), 'неверный URL обновления');
    let body = output(ctx, 'download', [ctx.connect_timeout, ctx.request_timeout, ctx.max_file_bytes, url]);
__ZIFY_ZIFY_UCODE_4__
)
export ZIFY_UCODE_4

ZIFY_UCODE_5=$(cat <<'__ZIFY_ZIFY_UCODE_5__'
check(length(body), 'не удалось получить обновление');
    return body;
}

function compute_update_status(ctx) {
    let path = ctx.state + '/update.json';
    try {
        let data = json(read(path, 65536));
        check(data.origin == update_origin() && match(data.revision, /^[a-f0-9]{40}$/), 'неверный кэш обновления');
        data.available = newer_version(data.version, VERSION);
        return data;
    }
    catch (e) { return { available: false }; }
};

function update_status(ctx) {
    return cached(ctx, 'update-status', () => compute_update_status(ctx));
};

function release_metadata(data) {
    check(data.format == 1 && data.bundle_format == 2, 'несовместимый формат релиза');
    newer_version(data.version, VERSION);
    for (let kind in ['code', 'assets']) {
        let entry = data[kind], path = kind == 'code' ? UPDATE_PATH : 'dist/zify-assets.tar.gz';
        let limit = kind == 'code' ? 2097152 : 8388608;
        check(type(entry) == 'object' && entry.path == path && type(entry.size) == 'int' &&
            entry.size > 0 && entry.size <= limit && type(entry.sha256) == 'string' &&
            match(entry.sha256, /^[a-f0-9]{64}$/), 'неверный файл релиза: ' + kind);
    }
}

function check_update(ctx) {
    let base = 'https://api.github.com/repos/' + UPDATE_REPO;
    let ref = json(update_remote(ctx, base + '/git/ref/heads/' + UPDATE_BRANCH));
    let revision = ref.object?.sha;
    check(ref.ref == 'refs/heads/' + UPDATE_BRANCH && ref.object?.type == 'commit' &&
        type(revision) == 'string' && match(revision, /^[a-f0-9]{40}$/), 'неверная ревизия обновления');
    let release = json(update_remote(ctx, 'https://raw.githubusercontent.com/' + UPDATE_REPO + '/' + revision + '/dist/release.json'));
    release_metadata(release);
    let data = { ...release, origin: update_origin(), revision, checked: time() };
    if (getenv('ZIFY_TRANSACTION')) cache_update(ctx, data);
    else check(transact(ctx, 'cache', [sprintf('%J', data)]) == 0, 'не удалось сохранить проверку обновления');
    return update_status(ctx);
};

function cache_update(ctx, data) {
    check(getenv('ZIFY_TRANSACTION') && type(data) == 'object' && data.origin == update_origin() &&
        type(data.revision) == 'string' && match(data.revision, /^[a-f0-9]{40}$/) &&
        type(data.checked) == 'int' && data.checked > 0, 'неверный кэш обновления');
    newer_version(data.version, VERSION);
    if (getenv('ZIFY_BACKGROUND_UPDATE') == '1' && fs.stat(ctx.root + '/usr/bin/zify') == null) return;
    send(ctx, 'state-write', ['update.json'], sprintf('%J\n', data));
};

function apply_update(ctx) {
    if (!getenv('ZIFY_TRANSACTION')) { check(transact(ctx, 'self-update', []) == 0, 'не удалось обновить менеджер'); return; }
    let lock = getenv('ZIFY_TRANSACTION');
    check(lock == ctx.root + '/tmp/zify.zapret.lock' && fs.stat(lock + '/ready')?.type == 'file', 'нет транзакции обновления');
    let info = update_status(ctx);
    check(info.available, 'новой версии нет; сначала проверьте обновления');
    release_metadata(info);
    run(ctx, 'check-space', [int((info.code.size + info.assets.size + 1023) / 1024)]);
    let base = 'https://raw.githubusercontent.com/' + UPDATE_REPO + '/' + info.revision + '/';
    let body = update_remote(ctx, base + info.code.path);
    check(length(body) == info.code.size && sha256(body) == info.code.sha256, 'контрольная сумма кода не совпала');
    check(index(body, '\n# ZIFY_VERSION=' + info.version + '\n') != -1 && match(body, /(^|\n)# ZIFY_FORMAT=2(\n|$)/), 'версия загруженного файла не совпала');
    let archive = lock + '/manager-assets.tar.gz';
    let reply = http_request(ctx, base + info.assets.path, info.assets.size, false, false, archive);
    check(reply.status >= 200 && reply.status < 300 && fs.stat(archive)?.size == info.assets.size, 'не удалось загрузить ресурсы релиза');
    let sums = lock + '/manager-assets.sha256';
    check(fs.writefile(sums, info.assets.sha256 + '  ' + archive + '\n') > 0, 'не удалось записать контрольную сумму');
    check(execute(['sha256sum', '-c', sums]) == 0, 'контрольная сумма ресурсов не совпала');
    // The existing supervisor snapshots code, resources and fakes as one transaction.
    // Format 2 updates retain asset format 1; incompatible future formats fail safely.
    install_assets(ctx, archive, info.version);
    send(ctx, 'manager-install', [ctx.root], body);
    report(sprintf('zify и ресурсы обновлены до %s. Предыдущая сборка: /usr/bin/zify.previous\nЗапустите zify заново.\n', info.version));
};

// ---- src/lib/terminal.uc ----

let tty = { raw: false, screen: false, saved: null, width: 90, height: 30, frame: '', winch: null, resize: false, interrupted: false };
let terminal_handlers = [];
const PALETTE = { white: '97', silver: '38;5;251', steel: '38;5;146', gray: '90', dim: '38;5;244',
    green: '38;5;82', red: '38;5;203', yellow: '38;5;214', lavender: '38;5;183', text: '38;5;254' };
let color = false;

function tone(name, text, bold) {
    return color ? '\x1b[' + (bold ? '1;' : '') + (PALETTE[name] || name) + 'm' + text + '\x1b[0m' : text;
};

// All UI labels use single-cell Latin/Cyrillic characters; preserve UTF-8 and ANSI sequences.
function terminal_clip(line, width) {
    if (width < 1) return '';
    let out = '', visible = 0, i = 0, clipped = false;
    while (i < length(line)) {
        if (substr(line, i, 2) == '\x1b[') {
            let end = index(substr(line, i), 'm');
            if (end != -1) { out += substr(line, i, end + 1); i += end + 1; continue; }
        }
        let c = ord(line, i), bytes = c >= 240 ? 4 : (c >= 224 ? 3 : (c >= 192 ? 2 : 1));
        if (c >= 32) {
            if (visible >= width) { clipped = true; break; }
            out += substr(line, i, bytes); visible++;
        }
        i += bytes;
    }
    if (clipped) out = terminal_clip(out, width - 1) + tone('dim', '…');
    return out + (color ? '\x1b[0m' : '');
};

function dimensions(value) {
    let m = match(trim(value || ''), /^([0-9]+) ([0-9]+)$/);
    if (m && +m[1] > 0 && +m[2] > 0) { tty.height = +m[1]; tty.width = +m[2]; }
}

function resize_terminal() {
    tty.resize = false;
    let process = fs.popen('stty size 2>/dev/null', 'r');
    if (process) { dimensions(process.read('all')); process.close(); }
}

function clear_terminal_signals() {
    for (let handler in terminal_handlers) handler.delete();
    terminal_handlers = [];
}

function terminal_signals() {
    clear_terminal_signals();
    for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP']) signal(name, () => { tty.interrupted = true; die('операция прервана'); });
    if (tty.raw) {
        uloop.init();
        for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP', tty.winch]) {
            let handler = uloop.signal(name, name == tty.winch ? () => {
                tty.resize = true; uloop.end();
            } : () => { tty.interrupted = true; uloop.end(); });
            check(handler != null, 'не удалось подключить сигналы терминала');
            push(terminal_handlers, handler);
        }
    }
};

function terminal_raw() { return tty.raw; };
function terminal_interrupted() { return tty.interrupted; };

function terminal_resume() {
    if (!tty.raw) {
        check(system(['stty', '-echo', '-icanon', 'min', '1', 'time', '0']) == 0, 'не удалось настроить терминал');
        tty.raw = true;
        if (!tty.screen) fs.stdout.write('\x1b[?1049h');
        tty.screen = true;
        fs.stdout.write('\x1b[?25l'); fs.stdout.flush();
    }
    tty.frame = '';
    terminal_signals();
};

// Return canonical input to foreground helpers without leaving the UI screen.
function terminal_cooked() {
    clear_terminal_signals();
    if (tty.raw) {
        tty.raw = false;
        system(['stty', tty.saved]);
        fs.stdout.write('\x1b[0m\x1b[?25h'); fs.stdout.flush();
    }
};

function terminal_suspend() {
    terminal_cooked();
    if (tty.screen) {
        tty.screen = false;
        fs.stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l'); fs.stdout.flush();
    }
};

function terminal_close() {
    terminal_suspend();
    tty.saved = null;
};

function terminal_open() {
    check(fs.stdin.isatty() && fs.stdout.isatty(), 'меню требует TTY: подключитесь по SSH с терминалом');
    check(length(getenv('TERM') || '') && getenv('TERM') != 'dumb', 'меню требует ANSI-терминал: задайте TERM=xterm-256color');
    color = getenv('ZIFY_COLOR') == 'always' || getenv('NO_COLOR') == null;
    tty.interrupted = false;
    // All supported OpenWrt architectures use POSIX stty, provided by BusyBox.
    let process = fs.popen('stty -g 2>/dev/null && stty size 2>/dev/null && (kill -l WINCH 2>/dev/null || /bin/kill -l WINCH)', 'r');
    let result = process ? process.read('all') : '', status = process ? process.close() : 1;
    let lines = split(trim(result || ''), '\n');
    check(status == 0 && length(lines) == 3 && length(lines[0]) && match(lines[2], /^[0-9]+$/),
        'для меню требуется рабочий stty; запустите установщик zify для проверки зависимостей');
    tty.saved = lines[0]; dimensions(lines[1]); tty.winch = +lines[2];
    terminal_resume();
};

function row_menu(options, index) {
    return options.kinds?.[index] != null ? options.kinds[index] == 'menu' : options.menu == true;
}

// ucode sprintf width counts UTF-8 bytes, whereas terminal columns count characters.
function terminal_pad(text, width) {
    let cells = 0;
    for (let i = 0; i < length(text); i++) if ((ord(text, i) & 0xc0) != 0x80) cells++;
    while (cells++ < width) text += ' ';
    return text;
};

function terminal_frame(title, labels, options) {
    options = options || {};
    if (tty.resize) resize_terminal();
    let selected = options.selected || 0, lines = ['', '    ' + tone('white', 'zify', true) +
        (title ? tone('dim', ' > ') + tone('white', title) : ' ' + tone('steel', options.version || '')) +
        (options.root ? tone('dim', ' · ') + tone('steel', 'https://github.com/swxfe/zify') : '')];
    for (let line in (options.header || [])) push(lines, '    ' + line);
    push(lines, '');
    let window = min(options.page_size || 10, max(1, tty.height - length(lines) - 6));
    let top = max(0, min(selected - int(window / 2), length(labels) - window));
    if (options.page_size) top = int(selected / window) * window;
    let bottom = min(length(labels), top + window);
    for (let i = top; i < bottom; i++) {
        let row = labels[i], text = type(row) == 'object' ? row.label : row;
        let marker = i == selected ? tone('lavender', '>') + ' ' : '  ';
        let box = type(row) == 'object' && row.checked != null ? tone(row.checked ? 'red' : 'dim', row.checked ? '[x] ' : '[ ] ') : '';
        let child = type(row) == 'object' && row.child ? tone('dim', '└─ ') : '';
        let drill = row_menu(options, i) ? tone('dim', '  ›') : '';
        push(lines, '  ' + marker + child + box + tone(i == selected ? 'white' : 'text', sprintf('%-3s', i + 1) + text, i == selected) + drill);
    }
    for (let line in (options.body || [])) push(lines, '    ' + line);
    if (bottom < length(labels)) push(lines, '    ' + tone('lavender', '↓') + tone('dim', ' ещё ' + (length(labels) - bottom) + ' ниже…'));
    else if (top > 0) push(lines, '    ' + tone('dim', '· конец списка'));
    push(lines, '');
    for (let hint in (options.footer || ['↑↓ / номер — выбор · ' + (row_menu(options, selected) ? 'Enter / → — открыть' : 'Enter — выполнить'), options.back_hint || (options.root ? 'Q — выход' : 'Q / ← — назад')])) push(lines, '    ' + tone('silver', hint));
    push(lines, options.notice ? '    ' + tone(options.warning ? 'yellow' : 'steel', options.notice) : '');
    if (tty.width < 49 || tty.height < 15) lines = ['', '  zify', '  Увеличьте окно до 49 × 15', '  Q — выход'];
    let width = max(1, tty.width - 3), height = max(1, tty.height - 1);
    let frame = join('\n', map(slice(lines, 0, height), (line) => terminal_clip(line, width) + '\x1b[K'));
    frame = '\x1b[H' + frame + '\x1b[J';
    if (frame != tty.frame) { fs.stdout.write(frame); fs.stdout.flush(); tty.frame = frame; }
};

// Wait in OpenWrt's native event loop, then read exactly one byte without stdio
// read-ahead. Older ucode fs.stdin keeps EOF set after a termios timeout.
function read_byte() {
    uloop.init();
    let value = '', handle = uloop.handle(fs.stdin, () => {
        value = fs.readfile('/proc/self/fd/0', 1);
        uloop.end();
    }, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
    check(handle != null, 'не удалось подключить ввод терминала');
    let timer = uloop.timer(100, () => uloop.end());
    try { uloop.run(); }
    catch (e) { handle.delete(); timer.cancel(); die(e.message); }
    handle.delete(); timer.cancel();
    return value;
}

// Resize notifications can interrupt a multi-byte key without ending its sequence.
function sequence_byte() {
    for (let i = 0; i < 3 && !tty.interrupted; i++) {
        let value = read_byte();
        if (value != '') return value;
    }
    return '';
}

function read_key() {
    let c = read_byte();
    if (c == null) return 'EOF';
    if (c == '') return 'TICK';
    if (c == '\x04') return 'EOF';
    if (c == '\n' || c == '\r') return 'ENTER';
    if (c == '\x1b') {
        let sequence = sequence_byte();
        if (sequence != '[' && sequence != 'O') return 'TICK';
        let next = sequence_byte();
        if (next == 'A') return 'UP'; if (next == 'B') return 'DOWN';
        if (next == 'C') return 'RIGHT'; if (next == 'D') return 'BACK';
        if (next == 'H') return 'HOME'; if (next == 'F') return 'END';
        if (next == '5' || next == '6') { sequence_byte(); return 'TICK'; }
        return 'TICK';
    }
    return c;
}

function terminal_input(label, fallback) {
    check(tty.raw, 'терминал меню не открыт');
    fs.stdout.write('    ' + tone('silver', label) + (fallback != null ? ' [' + fallback + ']' : '') + ': '); fs.stdout.flush();
    let line = '';
    while (true) {
        let key = read_key();
        if (key == null || key == 'EOF') return null;
        if (key == 'TICK') continue;
        if (key == 'ENTER' || key == '\n' || key == '\r') break;
        if (key == '\x7f' || key == '\b') {
            if (length(line)) {
                let i = length(line) - 1;
                while (i > 0 && (ord(line, i) & 0xc0) == 0x80) i--;
                line = substr(line, 0, i);
                fs.stdout.write('\b \b');
            }
        }
        else if (length(key) == 1 && ord(key) >= 32) { line += key; fs.stdout.write(key); }
        check(length(line) <= 4096, 'слишком длинный ввод');
        fs.stdout.flush();
    }
    fs.stdout.write('\n'); fs.stdout.flush();
    line = trim(line);
    return line == '' && fallback != null ? '' + fallback : line;
};

function terminal_select(title, labels, options) {
    options = options || {};
    if (!length(labels)) return 0;
    let selected = options.selected ?? 0;
    selected = max(0, min(selected, length(labels) - 1));
    let digits = '', ticks = 0;
    while (!tty.interrupted) {
        terminal_frame(title, labels, { ...options, selected });
        let key = read_key();
        if (key == null || key == 'EOF') return null;
        if (tty.width < 49 || tty.height < 15) { if (key == 'q' || key == 'Q' || key == 'EOF') return 0; continue; }
        if (key == 'TICK') {
            if (!length(digits) || ++ticks < 3) continue;
            key = 'ENTER';
        }
        if (match(key, /^[0-9]$/)) {
            if (key == '0' && digits == '') continue;
            digits += key; ticks = 0;
            if (+digits < 1 || +digits > length(labels)) { options.notice = 'Нет пункта ' + digits; digits = ''; continue; }
            selected = +digits - 1;
            if (+digits * 10 <= length(labels)) continue;
            key = 'ENTER';
        }
        if (key == 'BACK' && options.root) continue;
        if (key == 'q' || key == 'Q' || key == 'BACK') return 0;
        if (key == 'UP') selected = (selected + length(labels) - 1) % length(labels);
        if (key == 'DOWN') selected = (selected + 1) % length(labels);
        if (key == 'HOME') selected = 0;
        if (key == 'END') selected = length(labels) - 1;
        if (key == 'n' || key == 'N') selected = min(length(labels) - 1, selected + min(options.page_size || 10, max(1, tty.height - length(options.header || []) - 9)));
        if (key == 'p' || key == 'P') selected = max(0, selected - min(options.page_size || 10, max(1, tty.height - length(options.header || []) - 9)));
        if (options.extra && index(options.extra, lc(key)) != -1) return lc(key);
        if (key == ' ' && options.checkboxes) return { toggle: selected };
        if (key == 'ENTER' || (key == 'RIGHT' && row_menu(options, selected))) {
            return options.checkboxes ? { apply: true } : selected + 1;
        }
        digits = ''; ticks = 0;
    }
    return 0;
};

// A review belongs to the current action: Enter, Q and Left all return once.
function terminal_view(title, text, message, failed) {
    let lines = split(replace(text || '', /\r/g, ''), '\n'), top = 0;
    while (!tty.interrupted) {
        if (tty.resize) resize_terminal();
        let page = max(1, tty.height - 10);
        top = max(0, min(top, length(lines) - page));
        terminal_frame(title, [], { body: slice(lines, top, top + page), notice: message, warning: failed,
            footer: ['↑↓ — прокрутка', 'Enter / Q / ← — вернуться в меню'] });
        let key = read_key();
        if (key == 'EOF') return false;
        if (key == 'ENTER' || key == 'q' || key == 'Q' || key == 'BACK') return true;
        if (key == 'UP') top--;
        if (key == 'DOWN') top++;
        if (key == 'HOME') top = 0;
        if (key == 'END') top = length(lines);
    }
    return false;
};

// ---- src/lib/menu.uc ----

let ended = false, assume_yes = false, menu_executor = null, menu_ctx = null, notice = '', action_active = false;

function service_header(ctx, strategy) {
    let state = cached(ctx, 'zapret-status', () => zapret_status(ctx));
    return [tone('white', 'Zapret ') + tone(state.running ? 'green' : 'red', '●') + ' ' +
        tone('white', state.installed ? (state.running == null ? 'состояние неизвестно' : (state.running ? 'активен' : 'остановлен')) : 'не установлен') +
        (state.installed ? tone('dim', ' · ') + tone('steel', state.version) : ''),
        ...(strategy ? [tone('white', 'Стратегия: ') + tone('steel', state.strategy)] : [])];
}

function prompt(label, fallback) {
    let value = terminal_input(label, fallback);
    if (value == null) ended = true;
    return value;
}
function choice(title, labels, options) {
    options = options || {};
    let value = terminal_select(title, labels, { header: menu_ctx ? service_header(menu_ctx) : [],
        notice, menu: false, ...options });
    notice = '';
    if (value == null) { ended = true; return 0; }
    return value;
}

// Each open category owns its cursor; leaving it discards the selection.
function menu_choices() {
    let selected = 0;
    return (title, labels, options) => {
        let value = choice(title, labels, { ...(options || {}), selected });
        if (type(value) == 'int' && value > 0) selected = value - 1;
        else if (type(value) == 'object' && value.toggle != null) selected = value.toggle;
        return value;
    };
}

function command(ctx, args) {
    let cooked = terminal_raw() && action_active, rc;
    if (cooked) terminal_cooked();
    try {
        rc = menu_executor ? menu_executor([...(cached(ctx, 'settings-file-exists', () => fs.stat(ctx.file) != null) ? ['--config', ctx.file] : []), ...args], ctx) : invoke(ctx, args);
    }
    catch (e) { if (cooked) terminal_resume(); die(e.message); }
    if (cooked) terminal_resume();
    terminal_signals();
    check(rc == 0, 'действие не выполнено; причина указана в журнале');
}

function perform(fn, message) {
    let failed = false, folder = tempdir();
    capture_output(folder + '/output'); action_active = true;
    terminal_frame('Применение', [], { header: ['Выполняется действие…'], footer: ['Пожалуйста, подождите'] });
    try { let result = fn(); notice = result == false ? '' : (type(result) == 'string' ? result : (message || 'Готово')); }
    catch (e) { failed = true; notice = 'Ошибка: ' + e.message; }
    capture_output(null); action_active = false;
    let details = fs.readfile(folder + '/output', 65536) || '';
    fs.unlink(folder + '/output'); fs.rmdir(folder);
    if (terminal_interrupted()) ended = true;
    terminal_resume();
    if (!ended && failed && !terminal_view('Ошибка', details, notice, true)) ended = true;
}

function confirm(text) {
    if (assume_yes) return true;
    return choice('Подтверждение', ['Отмена'], { header: [tone('yellow', text)], menu: false,
        extra: ['y'], footer: ['Y — подтвердить · Q / ← — отмена'] }) == 'y';
}
function local_file(label, fallback) {
    let value = prompt(label, fallback); check(value != null && length(value), 'путь не указан'); return value;
}

function explicit_group(ctx, group) {
    let sections = filter(strategy_state(ctx).sections, (s) => strategy_group(s.name) == group);
    return length(sections) ? join(' + ', map(sections, (s) => s.name)) : 'отключено';
}

function choose_strategy(ctx, kind, group) {
    while (!ended) {
        let data;
        try { data = source_data(ctx, kind); }
        catch (e) { notice = e.message; return null; }
        let list = filter(data.strategies, (s) => group != null ? strategy_group(s.name) == group : strategy_group(s.name) == null);
        sort(list, strategy_order);
        if (!length(list)) { notice = 'В каталоге нет стратегий этой группы'; return null; }
        let active = strategy_state(ctx).sections, selected = 0;
        let labels = map(list, (s, i) => {
            let current = length(filter(active, (a) => a.name == strategy_key(s.name) && !a.changed)) > 0;
            if (current) selected = i;
            let label = strategy_title(s.name) + (length(s.missing || []) ? ' · нет фейка: ' + join(', ', s.missing) : '') + (current ? '  (активна)' : '');
            return current ? tone('steel', label) : label;
        });
        let group_name = { base: 'базовый трафик', youtube: 'YouTube', discord: 'Discord', games: 'игры' }[group];
        let title = group == null ? 'стратегии > flowseal' : 'стратегии > ' + (group == 'games' ? 'игры' : 'сборка > ' + group_name);
        let value = choice(title, labels, { selected, menu: false, extra: ['d'], header: [
            tone('white', group == null ? 'Стратегия: ' : 'Сейчас: ') + tone('steel', group == null ? strategy_state(ctx).summary : explicit_group(ctx, group)) +
                tone('dim', ' · ') + 'каталог ' + tone('steel', substr(data.revision, 0, 8))],
__ZIFY_ZIFY_UCODE_5__
)
export ZIFY_UCODE_5

ZIFY_UCODE_6=$(cat <<'__ZIFY_ZIFY_UCODE_6__'
footer: ['↑↓ / номер — выбор · Enter — применить', 'Q / ← — назад · D — отключить'] });
        if (!value) return null;
        if (value == 'd') return { disable: true };
        if (length(list[value - 1].missing || [])) { notice = 'Нет фейков Flowseal: ' + join(', ', list[value - 1].missing); continue; }
        return list[value - 1];
    }
    return null;
}

function edit_group(ctx, group) {
    let selected = choose_strategy(ctx, 'manager', group);
    if (selected) perform(() => {
        command(ctx, selected.disable ? ['source', 'remove', 'manager', group] : ['source', 'select', 'manager', selected.name]);
        let current = explicit_group(ctx, group);
        return selected.disable ? (current == 'отключено' ? 'Группа отключена' : 'Изменение отменено') :
            (current == selected.name ? 'Применено: ' + selected.name : 'Изменение отменено');
    });
}

function compose_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let groups = ['base', 'youtube', 'discord'];
        let labels = ['Базовый трафик', 'YouTube', 'Discord'];
        let value = choose('стратегии > сборка', map(groups, (group, i) => terminal_pad(labels[i], 19) + explicit_group(ctx, group)),
            { menu: true, header: [tone('white', 'Стратегия: ') + tone('steel', strategy_state(ctx).summary)] });
        if (!value) return;
        edit_group(ctx, groups[value - 1]);
    }
}

function fake_purpose(slot) {
    let names = {
        'fake-tls': 'TLS', 'fake-http': 'HTTP', 'fake-quic': 'QUIC',
        'fake-discord': 'Discord', 'fake-stun': 'STUN', 'fake-unknown-udp': 'UDP',
        'fake-unknown': 'Другой трафик', 'fake-syn': 'SYN'
    };
    let key = replace(slot.option, /^--dpi-desync-/, '');
    return names[key] || key;
}

function choose_fake(ctx, slot) {
    let list = fake_catalog(ctx, 'flowseal');
    let value = choice('Фейки > замена', map(list, (name) => name == slot.filename ? tone('steel', name + '  (текущий)') : name),
        { page_size: 12, menu: false, header: [slot.filename + ' → ' + fake_purpose(slot),
            tone('gray', 'Каталог Flowseal · выбирайте файл подходящего формата')],
            footer: ['N — далее · P — назад · ↑↓ / номер / Enter — файл', 'Q / ← — отмена'] });
    return value ? list[value - 1] : null;
}

function edit_fake(ctx, slot) {
    let name = choose_fake(ctx, slot);
    if (name) perform(() => command(ctx, ['fake', 'replace', '' + slot.line, slot.path, 'flowseal', name]), fake_purpose(slot) + ' → ' + name);
}

function fake_targets_menu(ctx, path) {
    let choose = menu_choices();
    while (!ended) {
        let group = filter(group_fakes(current_fakes(ctx)), (g) => g.path == path)[0];
        if (!group) return;
        let target = choose(group.filename + ' > где заменить', map(group.slots, (s) => fake_purpose(s) + ' · ' + s.section + ' · профиль ' + s.profile), { menu: true });
        if (!target) return;
        edit_fake(ctx, group.slots[target - 1]);
    }
}

function fake_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let groups = group_fakes(current_fakes(ctx));
        if (!length(groups)) { notice = 'В текущей стратегии нет .bin файлов для замены'; return; }
        let value = choose('Фейки', map(groups, (g) => join(', ', g.sections) + ' · ' + g.filename), { menu: true, header: ['Файлов в текущей стратегии: ' + length(groups)] });
        if (!value) return;
        let group = groups[value - 1];
        if (length(group.slots) > 1) fake_targets_menu(ctx, group.path);
        else edit_fake(ctx, group.slots[0]);
    }
}

function strategy_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let value = choose('стратегии', ['Стратегии Flowseal', 'Собрать: основная + YouTube + Discord', 'Игры', 'Фейки', 'Очистить стратегию'],
            { kinds: ['menu', 'menu', 'menu', 'menu', 'action'], menu: false,
                header: [tone('white', 'Стратегия: ') + tone('steel', strategy_state(ctx).summary)] });
        if (!value) return;
        if (value == 1) {
            while (!ended) {
                let selected = choose_strategy(ctx, 'flowseal', null);
                if (!selected) break;
                perform(() => command(ctx, selected.disable ? ['source', 'remove', 'flowseal'] : ['source', 'select', 'flowseal', selected.name]),
                    selected.disable ? 'Flowseal отключён' : 'Применено: ' + strategy_title(selected.name));
            }
        }
        if (value == 2) compose_menu(ctx);
        if (value == 3) edit_group(ctx, 'games');
        if (value == 4) fake_menu(ctx);
        if (value == 5 && confirm('Очистить все текущие стратегии и остановить Zapret')) perform(() => {
            command(ctx, ['strategy', 'clear']);
            let message = length(strategy_state(ctx).sections) ? 'Очистка отменена' : 'Стратегия очищена';
            report(message + '\n'); return message;
        });
    }
}

function uninstall_menu(ctx) {
    let choose = menu_choices();
    let selected = { zapret: false, luci: false, manager: false, files: false, config: false };
    while (!ended) {
        let rows = [{ key: 'zapret', label: 'Zapret (ядро и службы)' }];
        if (selected.zapret) push(rows, { key: 'files', label: 'Файлы: стратегии и фейки', child: true });
        push(rows, { key: 'luci', label: 'LuCI (веб-интерфейс)' });
        push(rows, { key: 'manager', label: 'zify (менеджер)' });
        if (selected.manager) push(rows, { key: 'config', label: 'Служебная конфигурация', child: true });
        let value = choose('установка и удаление > удаление', map(rows, (r) => ({ ...r, checked: selected[r.key] })),
            { checkboxes: true, menu: false, header: ['Отметьте компоненты пробелом'],
                footer: ['↑↓ / номер — выбор · Пробел — отметить', 'Enter — удалить · Q / ← — назад'] });
        if (!value) return;
        if (value.toggle != null) {
            let key = rows[value.toggle].key; selected[key] = !selected[key];
            if (!selected.zapret) selected.files = false;
            if (!selected.manager) selected.config = false;
            continue;
        }
        let names = filter(['zapret', 'luci', 'manager', 'files', 'config'], (name) => selected[name]);
        if (!length(names)) { notice = 'Выберите компоненты пробелом'; continue; }
        let labels = { zapret: 'Zapret', luci: 'LuCI', manager: 'zify', files: 'файлы Zapret', config: 'конфигурация zify' };
        if (!confirm('Удалить: ' + join(', ', map(names, (name) => labels[name])))) { notice = 'Удаление отменено'; continue; }
        perform(() => { command(ctx, ['uninstall', 'components', ...names]); if (selected.manager) ended = true; }, 'Выбранные компоненты удалены');
        if (!ended) return;
    }
}

function install_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let state = cached(ctx, 'zapret-status', () => zapret_status(ctx)), update = update_status(ctx);
        let value = choose('установка и удаление', ['Обновить zify' + (update.available ? '  (' + VERSION + ' → ' + update.version + ')' : ''),
            state.installed ? 'Обновить Zapret' : 'Установить Zapret', 'Обновить всё разом', 'Выборочное удаление'],
            { menu: false, kinds: ['action', 'action', 'action', 'menu'], header: ['Управление компонентами'] });
        if (!value) return;
        if (value == 4) { uninstall_menu(ctx); continue; }
        perform(() => {
            if (value == 2 || value == 3) command(ctx, ['install-upstream']);
            if (value == 1 || value == 3) {
                let info = check_update(ctx);
                if (info.available) { apply_update(ctx); report('zify обновлён. Перезапустите менеджер.\n'); ended = true; }
                else report('Установлена последняя версия zify.\n');
            }
        });
    }
}

function service_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let enabled = cached(ctx, 'autostart', () => length(fs.glob(ctx.root + '/etc/rc.d/S??zapret') || []) > 0);
        let value = choose('запуск и автозапуск', ['Запустить', 'Остановить', 'Перезапустить', 'Включить автозапуск', 'Выключить автозапуск'],
            { menu: false, header: [service_header(ctx)[0], tone('white', 'Автозапуск: ') + tone(enabled ? 'steel' : 'gray', enabled ? 'включен' : 'выключен')] });
        if (!value) return;
        perform(() => command(ctx, ['service', ['start', 'stop', 'restart', 'enable', 'disable'][value - 1]]));
    }
}

function devices_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let devices = device_list(ctx), current = excluded(ctx);
        let labels = map(devices, (item) => (index(current, item.ip) == -1 ? '[Zapret] ' : '[Исключён] ') + item.ip + ' · ' + item.name);
        push(labels, 'Ввести IP вручную'); push(labels, 'Очистить исключения');
        let value = choose('настройки > устройства', labels, { menu: false, header: [service_header(ctx)[0],
            'Исключено устройств: ' + length(current)] });
        if (!value) return;
        perform(() => {
            if (value == length(labels)) { if (confirm('Очистить все исключения устройств')) command(ctx, ['devices', 'clear']); return; }
            let ip = value == length(devices) + 1 ? local_file('IPv4 устройства', null) : devices[value - 1].ip;
            command(ctx, ['devices', 'toggle', ip]);
        });
    }
}

function flow_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let state;
        try { state = flow_status(ctx); } catch (e) { notice = e.message; return; }
        let names = { donttouch: 'системный режим', none: 'выключено', software: 'программное', hardware: 'аппаратное' };
        let value = choose('настройки > Flow Offloading', ['Программное ускорение Zapret', 'Аппаратное ускорение Zapret',
            'Отключить ускорение', 'Не управлять ускорением', 'Вернуть настройки до изменений zify'],
            { menu: false, header: ['Zapret: ' + tone('steel', names[state.mode] || state.mode),
                tone('gray', 'Системное: software ' + (state.software ? 'вкл' : 'выкл') + ' · hardware ' + (state.hardware ? 'вкл' : 'выкл'))],
                footer: ['↑↓ / номер — выбор · Enter — применить', 'Q / ← — назад'],
                notice: notice || 'Выборочным offload управляют штатные скрипты Zapret' });
        if (!value) return;
        if (value == 5 && !state.saved) { notice = 'Сохранённых настроек нет'; continue; }
        perform(() => command(ctx, ['network', 'offload', ['software', 'hardware', 'none', 'donttouch', 'restore'][value - 1]]));
    }
}

function config_menu(ctx) {
    let choose = menu_choices();
    if (!fs.stat(ctx.config)) { notice = 'Сначала установите Zapret'; return; }
    while (!ended) {
        let value = choose('Настройки Zapret', ['IPv6', 'Исключить устройства из Zapret', 'Блокировка QUIC (UDP 80/443)', 'Flow Offloading'], { menu: true, header: [service_header(ctx)[0], 'IPv6: ' + (trim(config_option(ctx, 'DISABLE_IPV6', true)) == '1' ? 'выключен' : 'включён') +
                ' · QUIC: ' + (quic_status(ctx) ? 'заблокирован' : 'разрешён')] });
        if (!value) return;
        if (value == 2) { devices_menu(ctx); continue; }
        if (value == 4) { flow_menu(ctx); continue; }
        if (value == 1) {
            let active = trim(config_option(ctx, 'DISABLE_IPV6', true)) != '1';
            let next = choice('настройки > IPv6', ['Включить IPv6 в Zapret', 'Отключить IPv6 в Zapret'], { menu: false,
                header: [service_header(ctx)[0], 'IPv6 в Zapret: ' + tone(active ? 'green' : 'gray', active ? 'включён' : 'выключен')] });
            if (next) perform(() => command(ctx, ['config', 'set', 'DISABLE_IPV6', next == 1 ? '0' : '1']));
        }
        if (value == 3) {
            let blocked = quic_status(ctx);
            let next = choice('настройки > QUIC', ['Включить блокировку QUIC', 'Отключить блокировку QUIC'],
                { menu: false, header: [service_header(ctx)[0], 'Блокировка UDP 80/443: ' +
                    tone(blocked ? 'yellow' : 'gray', blocked ? 'включена' : 'выключена')] });
            if (next) perform(() => command(ctx, ['network', 'quic', next == 1 ? 'on' : 'off']));
        }
    }
}

function menu_session(ctx) {
    let choose = menu_choices();
    while (!ended && !terminal_interrupted()) {
        let info = update_status(ctx);
        let header = service_header(ctx, true);
        if (info.available) unshift(header, tone('yellow', 'доступно zify ' + info.version));
        else if (info.checked) push(header, tone('gray', 'zify актуален'));
        let value = choose('', ['Установка / обновление / удаление', 'Запуск и автозапуск', 'Стратегии', 'Настройки Zapret'],
            { root: true, version: VERSION, header, menu: false, kinds: ['menu', 'menu', 'menu', 'menu'], extra: ['u'], notice });
        if (!value) break;
        if (value == 1) install_menu(ctx);
        if (value == 2) service_menu(ctx);
        if (value == 3) strategy_menu(ctx);
        if (value == 4) config_menu(ctx);
        if (value == 'u') perform(() => {
            let update = check_update(ctx);
            report(update.available ? 'Доступно zify ' + update.version + '\n' : 'Установлена последняя версия zify.\n');
            if (update.available && confirm('Установить обновление zify')) { apply_update(ctx); ended = true; }
        });
    }
}

function menu(initial, executor) {
    ended = false; assume_yes = initial.assume_yes == true;
    session_cache(initial); menu_executor = executor; menu_ctx = initial;
    try {
        terminal_open();
        {
            let folder = tempdir();
            capture_output(folder + '/output');
            terminal_frame('', [], { version: VERSION, header: ['Проверка обновлений…'], footer: ['Пожалуйста, подождите'] });
            try { check_update(initial); } catch (e) { /* Offline startup keeps the last known version. */ }
            capture_output(null); fs.unlink(folder + '/output'); fs.rmdir(folder);
            terminal_signals();
        }
        menu_session(initial);
    }
    catch (e) { terminal_close(); die(e.message); }
    terminal_close();
    check(!terminal_interrupted(), 'операция прервана');
    print('\nДо встречи. Запуск менеджера: zify\n');
};

// ---- src/lib/commands.uc ----

const HELP = 'zify — управление Zapret в OpenWrt\n' +
    '\n' +
    'Использование: zify [параметры] [команда [аргументы]]\n' +
    'Без команды открывается меню.\n' +
    '\n' +
    'Параметры (в любом месте до --):\n' +
    '  -h, --help           Справка\n' +
    '  -V, --version        Версия\n' +
    '  -c, --config ФАЙЛ    Настройки zify (по умолчанию /etc/config/zify)\n' +
    '  -y, --yes           Подтвердить изменения без запроса ввода\n' +
    '  --non-interactive   То же, что --yes\n' +
    '  --                  Конец параметров\n' +
    '\n' +
    'Команды:\n' +
    '  status\n' +
    '  service start|stop|restart|enable|disable\n' +
    '  config get ОПЦИЯ | config set DISABLE_IPV6 0|1\n' +
    '  source list|show|apply|select|compose|group|remove ИСТОЧНИК ...\n' +
    '  strategy list|show|apply|import|validate|clear ...\n' +
    '  fake list|replace ...\n' +
    '  devices list|add|remove|toggle|clear [IP]\n' +
    '  network status|offload none|software|hardware|donttouch|restore|quic on|off\n' +
    '  install-upstream | update-upstream\n' +
    '  manager-install [АРХИВ] | manager-check | manager-update | manager-uninstall\n' +
    '  assets-install АРХИВ | uninstall manager|all|components [zapret luci manager files config]\n' +
    '  help | version\n' +
    '\n' +
    'Примеры: zify status; zify service restart; zify source list flowseal\n';

function arity(args, min, max) {
    check(length(args) >= min && length(args) <= max, 'неверное число аргументов; см. help');
}

function editable(key, value) {
    check(key == 'DISABLE_IPV6', 'изменение этой опции не поддерживается: ' + key);
    check(value == '0' || value == '1', 'ожидается 0 или 1');
}

function validate_ports(ports) {
    for (let range in split(ports, ',')) {
        check(match(range, /^[0-9]{1,5}(-[0-9]{1,5})?$/), 'неверный диапазон портов');
        let pair = split(range, '-');
        check(+pair[0] >= 1 && +pair[0] <= 65535 &&
              (length(pair) == 1 || (+pair[1] >= +pair[0] && +pair[1] <= 65535)), 'порт вне диапазона');
    }
}

function dependencies(ctx, body) {
    // The upstream init script expands arguments; paths must exist before config is changed.
    let path_pattern = /^--[^=]+=(\/[^,]+)$/;
    for (let line in split(body, '\n')) {
        let m = match(line, path_pattern);
        if (m) check(fs.stat(ctx.root + m[1])?.type == 'file', 'не найден файл стратегии: ' + m[1]);
    }
}

function persist_applied(ctx, body) {
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null : map(raw, (s) => strategy_key(s.label));
    let list = reference_catalog(ctx, wanted);
    let state = create_applied(body, inspect_strategy(body, list), list, time());
    send(ctx, 'state-write', ['state.json'], sprintf('%J\n', state));
}

function approve_strategy_change(ctx, clearing) {
    let state = read_applied(ctx);
    if (state == null || strategy_hash(configured_strategy(ctx)) == state.applied_hash) return true;
    return approve(ctx, clearing ? 'Ваши ручные изменения будут удалены. Продолжить' :
        'Ваши ручные изменения будут заменены версией из каталога. Продолжить');
}

function apply(ctx, body) {
    if (!length(trim(body))) {
        run(ctx, 'config-set', ['NFQWS_OPT', '', 'NFQWS_ENABLE', '0']);
        run(ctx, 'service', ['stop']);
        persist_applied(ctx, '');
        return;
    }
    body = preserve_body(body);
    dependencies(ctx, body);
    let updates = [];
    for (let proto in ['TCP', 'UDP']) {
        let option = 'NFQWS_PORTS_' + proto;
        let ports = trim(output(ctx, 'config-get-optional', [option]));
        let previous = ports, seen_ports = {};
        let items = [];
        for (let port in (length(ports) ? split(ports, ',') : []))
            if (!exists(seen_ports, port)) { seen_ports[port] = true; push(items, port); }
        let filter_pattern = regexp('^--filter-' + lc(proto) + '=([0-9,-]+)$');
        for (let line in split(body, '\n')) {
            let m = match(line, filter_pattern);
            if (m) for (let port in split(m[1], ',')) if (!exists(seen_ports, port)) { seen_ports[port] = true; push(items, port); }
        }
        if (length(items)) {
            ports = join(',', items);
            validate_ports(ports);
            if (ports != previous) push(updates, option, ports);
        }
    }
    if (!length(updates) && trim(configured_strategy(ctx)) == trim(body) &&
        replace(output(ctx, 'config-get-optional', ['NFQWS_ENABLE']), /\n$/, '') == '1' && service_running(ctx) == true) {
        persist_applied(ctx, body);
        return;
    }
    run(ctx, 'config-set', [...updates, 'NFQWS_OPT', body, 'NFQWS_ENABLE', '1']);
    run(ctx, 'service', ['restart']);
    persist_applied(ctx, body);
}

function initialize_lists(ctx) {
    for (let kind in ['user', 'exclude', 'google']) {
        let name = kind == 'user' ? 'zapret-hosts-user.txt' :
            (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
        if (fs.stat(ctx.base + '/ipset/' + name)) continue;
        let body = resource(ctx.resources, kind + '.txt');
        send(ctx, 'hosts-write', [kind], body);
    }
}

function dispatch(ctx, command, args) {
    let changes_strategy = (command == 'strategy' && index(['apply', 'import', 'clear'], args[0]) != -1) ||
        (command == 'source' && index(['apply', 'select', 'compose', 'group', 'remove'], args[0]) != -1);
    // Run after acquiring the transaction lock, before downloads or configuration writes.
    if (changes_strategy && !approve_strategy_change(ctx, command == 'strategy' && args[0] == 'clear')) { report('\nДействие отменено.\n'); return; }
    switch (command) {
    case 'uninstall':
        arity(args, 1, 1);
        check(args[0] == 'manager', 'полное удаление выполняется через пакетную фазу');
        run(ctx, 'uninstall-cleanup', args);
        break;
    case 'assets-install':
        arity(args, 1, 1);
        install_assets(ctx, args[0]);
        break;
    case 'manager-install':
        arity(args, 0, 1); install_manager(ctx, args[0]); break;
    case 'manager-uninstall':
        arity(args, 0, 0); run(ctx, 'manager-uninstall'); break;
    case 'manager-update':
        arity(args, 0, 0);
        apply_update(ctx);
        break;
    case 'manager-check':
        arity(args, 0, 0);
        check_update(ctx);
        break;
    case 'network':
        arity(args, 1, 2);
        run(ctx, 'network', args);
        break;
    case 'devices': {
        arity(args, 1, 2);
        let current = excluded(ctx);
        if (args[0] == 'list') {
            for (let item in device_list(ctx)) report(sprintf('%s %s %s\n', index(current, item.ip) == -1 ? 'Zapret' : 'Исключён', item.ip, item.name));
            break;
        }
        if (args[0] == 'clear') { arity(args, 1, 1); current = []; }
        else {
            check(index(['toggle', 'add', 'remove'], args[0]) != -1, 'неверная команда исключений'); arity(args, 2, 2);
            let ip = ipv4(args[1]);
            let present = index(current, ip) != -1;
            if (args[0] == 'add' && present || args[0] == 'remove' && !present) break;
__ZIFY_ZIFY_UCODE_6__
)
export ZIFY_UCODE_6

ZIFY_UCODE_7=$(cat <<'__ZIFY_ZIFY_UCODE_7__'
if (args[0] == 'add' || args[0] == 'toggle' && !present) push(current, ip);
            else current = filter(current, (item) => item != ip);
        }
        check(fs.stat(ctx.config), 'Zapret не установлен');
        send(ctx, 'device-hook-write', legacy_exclusions(ctx) != null ? ['migrate'] : [], exclusion_hook(ctx, current));
        send(ctx, 'state-write', ['devices.txt'], length(current) ? join('\n', sort(current)) + '\n' : '');
        run(ctx, 'config-set', ['DISABLE_CUSTOM', '0']);
        run(ctx, 'service', ['restart']);
        break;
    }
    case 'fake':
        arity(args, 1, 5);
        if (args[0] == 'list') {
            arity(args, 1, 1);
            report(sprintf('%J\n', current_fakes(ctx)));
        }
        else {
            check(args[0] == 'replace', 'неверная команда фейков');
            arity(args, 5, 5);
            let body = prepare_fake_replacement(ctx, args[1], args[2], args[3], args[4]);
            if (trim(body) != trim(configured_strategy(ctx))) apply(ctx, body);
        }
        break;
    case 'source': {
        arity(args, 2, 10);
        let action = args[0], kind = args[1];
        check(kind == 'flowseal' || kind == 'manager', 'неизвестный источник');
        check(index(['list', 'show', 'apply', 'select', 'compose', 'group', 'remove'], action) != -1, 'неизвестное действие источника');
        if (action == 'remove') {
            arity(args, kind == 'manager' ? 3 : 2, 3);
            let current = output(ctx, 'config-get-optional', ['NFQWS_OPT']);
            apply(ctx, length(args) == 3 ? replace_group(current, '', args[2]) : remove_flowseal(current));
            break;
        }
        let wanted = index(['show', 'apply', 'select', 'compose', 'group'], action) != -1 ?
            map(slice(args, action == 'group' ? 3 : 2), strategy_key) : null;
        let data = source_data(ctx, kind, wanted), list = data.strategies;
        if (action == 'list') { for (let s in list) report(sprintf('%s\n', s.name)); break; }
        if (action == 'show' || action == 'apply' || action == 'select' || action == 'compose' || action == 'group') {
            arity(args, action == 'group' ? 4 : 3, action == 'compose' ? 10 : (action == 'group' ? 4 : 3));
            let selected = [], seen = {};
            for (let name in slice(args, action == 'group' ? 3 : 2)) {
                check(!seen[name], 'повтор стратегии: ' + name);
                seen[name] = true;
                let found = filter(list, (s) => strategy_key(s.name) == strategy_key(name));
                check(length(found) == 1, 'стратегия не найдена: ' + name);
                push(selected, label_strategy(name, found[0].body));
            }
            let body = action == 'compose' ? compose_bodies(selected) : join('--new\n', selected);
            if (action == 'select') {
                let current = output(ctx, 'config-get-optional', ['NFQWS_OPT']);
                let sections = strategy_sections(current), group = strategy_group(args[2]);
                let games = filter(sections, (section) => strategy_group(section.label) == 'games');
                let has_flowseal = length(filter(sections, (section) => match(strategy_key(section.label) || '', /^general(_|$)/))) > 0;
                if (kind == 'flowseal') {
                    if (length(games)) body = compose_bodies([body, ...map(games, (section) => label_strategy(section.label, section.body))]);
                }
                else {
                    check(group != null, 'стратегия не относится к группе');
                    if (group != 'games' && has_flowseal)
                        body = compose_bodies([body, ...map(games, (section) => label_strategy(section.label, section.body))]);
                    else body = replace_group(current, body, group);
                }
            }
            if (action == 'group') {
                check(strategy_group(slice(args, 3)[0]) == args[2], 'стратегия не относится к выбранной группе');
                body = replace_group(output(ctx, 'config-get-optional', ['NFQWS_OPT']), body, args[2]);
            }
            if (action == 'show') report(body);
            else {
                check(ctx.profile == 'zapret' && fs.stat(ctx.config), 'сначала установите Zapret');
                initialize_lists(ctx);
                apply(ctx, body);
            }
            break;
        }
        die('неизвестное действие источника');
    }
    case 'status':
        arity(args, 0, 0);
        run(ctx, command);
        break;
    case 'service':
        arity(args, 1, 1);
        check(index(['start', 'stop', 'restart', 'enable', 'disable'], args[0]) != -1, 'неизвестная команда сервиса');
        run(ctx, 'service', args);
        break;
    case 'config':
        arity(args, 1, 3);
        if (args[0] == 'get') {
            arity(args, 2, 2);
            check(match(args[1], /^[A-Za-z][A-Za-z0-9_]*$/), 'неверное имя опции');
            report(output(ctx, 'config-get', [args[1]]));
        }
        else {
            check(args[0] == 'set', 'config: get/set DISABLE_IPV6'); arity(args, 3, 3);
            editable(args[1], args[2]);
            let current = replace(output(ctx, 'config-get-optional', [args[1]]), /\n$/, '');
            if (current == args[2]) break;
            run(ctx, 'config-set', slice(args, 1));
            run(ctx, 'service', ['restart']);
        }
        break;
    case 'strategy':
        check(length(args) > 0, 'strategy: list/show/apply/import/validate/clear');
        if (args[0] == 'clear') {
            arity(args, 1, 1);
            check(fs.stat(ctx.config), 'Zapret не установлен');
            if (length(trim(configured_strategy(ctx))) ||
                trim(output(ctx, 'config-get-optional', ['NFQWS_ENABLE'])) != '0' || service_running(ctx) != false)
                apply(ctx, '');
            else if (read_applied(ctx)?.applied_hash != strategy_hash('')) persist_applied(ctx, '');
        }
        else if (args[0] == 'list') {
            arity(args, 1, 2);
            for (let s in catalog(ctx, args[1])) report(sprintf('%s\n', s.name));
        }
        else if (args[0] == 'validate' || args[0] == 'import') {
            arity(args, 2, 2);
            let body = preserve_body(read(args[1], ctx.max_file_bytes));
            if (args[0] == 'validate') report(body); else apply(ctx, body);
        }
        else {
            check(args[0] == 'show' || args[0] == 'apply', 'неизвестная операция стратегии');
            arity(args, 2, args[0] == 'show' ? 2 : ctx.max_strategies);
            let body = compose(ctx, slice(args, 1));
            if (args[0] == 'show') report(body); else apply(ctx, body);
        }
        break;
    default: die('неизвестная команда: ' + command);
    }
}

function package_phase(ctx, args) {
    check(!getenv('ZIFY_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
    arity(args, 0, 0);
    let plan = release_install({ ...ctx, cache: null });
    if (plan != 'none') invalidate(ctx);
    if (plan != 'both') return 0;
    return transact(ctx, 'configure', []) == 0 ? 0 : 1;
}

// Global options may occur before or after a command. -- preserves literal operands.
function cli_arguments(argv) {
    let args = [], file = null, yes = false, literal = false, special = null;
    for (let i = 0; i < length(argv); i++) {
        let value = argv[i];
        if (literal) { push(args, value); continue; }
        if (value == '--') { literal = true; continue; }
        if (value == '-h' || value == '--help') { special = 'help'; continue; }
        if (value == '-V' || value == '--version') { special = 'version'; continue; }
        if (value == '-y' || value == '--yes' || value == '--non-interactive') { yes = true; continue; }
        if (substr(value, 0, 9) == '--config=') {
            file = substr(value, 9); check(length(file), 'не задано значение --config'); continue;
        }
        if (value == '-c' || value == '--config') {
            check(i + 1 < length(argv) && length(argv[i + 1]) && substr(argv[i + 1], 0, 1) != '-', 'не задано значение ' + value);
            file = argv[++i]; continue;
        }
        check(substr(value, 0, 1) != '-' || value == '-', 'неизвестный параметр: ' + value + '; см. zify --help');
        push(args, value);
    }
    return { command: special || shift(args), args: special ? [] : args, file, yes };
};

function destination_context(ctx) {
    let destination = getenv('DESTDIR');
    if (!destination) return ctx;
    check(match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/), 'неверный DESTDIR');
    ctx.root = destination == '/' ? '' : replace(destination, /\/$/, '');
    ctx.state = ctx.root + '/etc/zify'; ctx.base = ctx.root + '/opt/zapret';
    ctx.config = ctx.root + '/etc/config/zapret'; ctx.assets = ctx.state + '/assets';
    ctx.file = ctx.root + '/etc/config/zify';
    return ctx;
};

function command_main(argv, session) {
try {
    // ucode defers handlers until a synchronous helper has finished. The supervisor
    // waits for that worker before restoring files, so helpers cannot race the rollback.
    for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP'])
        signal(name, () => die('операция прервана'));
    let cli = cli_arguments(argv), args = cli.args, file = cli.file;
    let command = cli.command || 'help';
    if (command == 'help' || command == 'version') {
        arity(args, 0, 0);
        report(command == 'help' ? HELP : VERSION + '\n');
        return 0;
    }
    check(index(['status', 'service', 'config', 'source', 'strategy', 'fake',
        'devices', 'network', 'install-upstream', 'update-upstream',
        'manager-install', 'manager-uninstall', 'manager-check', 'manager-update', 'assets-install', 'uninstall'], command) != -1,
        'неизвестная команда: ' + command + '; см. zify --help');
    let ctx = session && (file == null || file == session.file) ? session : settings(getenv('ZIFY_HOME'), file || getenv('ZIFY_CONFIG'));
    ctx.assume_yes = cli.yes || (session?.assume_yes == true);
    if (index(['manager-install', 'manager-uninstall', 'uninstall'], command) != -1) ctx = destination_context(ctx);
    // Pure input errors need neither a snapshot nor a worker; validate again under the lock.
    if (command == 'config' && args[0] == 'set') {
        arity(args, 3, 3);
        editable(args[1], args[2]);
    }
    let readonly = index(['status', 'manager-check'], command) != -1 ||
        (command == 'network' && args[0] == 'status') ||
        (command == 'devices' && args[0] == 'list') ||
        (command == 'fake' && args[0] == 'list') ||
        (command == 'source' && index(['list', 'show'], args[0]) != -1) ||
        (command == 'strategy' && index(['list', 'show', 'validate'], args[0]) != -1) ||
        (command == 'config' && args[0] == 'get');
    if (!readonly && !getenv('ZIFY_TRANSACTION') && session == null)
        check(approve(ctx, 'Выполнить zify ' + command), 'операция отменена');
    if (index(['install-upstream', 'update-upstream'], command) != -1)
        return package_phase(ctx, args);
    if (command == 'uninstall') {
        arity(args, 1, 6);
        check(index(['manager', 'all', 'components'], args[0]) != -1, 'ожидается manager, all или components');
        if (args[0] != 'manager') {
            let selected = args[0] == 'all' ? ['zapret', 'luci', 'manager', 'files', 'config'] : slice(args, 1);
            check(length(selected), 'не выбраны компоненты');
            let seen = {};
            for (let name in selected) {
                check(index(['zapret', 'luci', 'manager', 'files', 'config'], name) != -1 && !seen[name], 'неверный компонент: ' + name);
                seen[name] = true;
            }
            check(!seen.files || seen.zapret, 'удаление файлов требует выбора Zapret');
            check(!seen.config || seen.manager, 'удаление конфигурации требует выбора zify');
            check(!getenv('ZIFY_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
            check(!fs.stat(ctx.root + '/tmp/zify.zapret.lock'), 'занято: выполняется другая операция');
            let packages = [];
            if (seen.luci) push(packages, 'luci-app-zapret');
            if (seen.zapret) push(packages, 'zapret');
            if (length(packages)) run(ctx, 'package', ['remove', ...packages]);
            check(transact(ctx, 'cleanup', ['components', ...selected]) == 0, 'не удалось очистить конфигурацию');
            return 0;
        }
    }
    if (!readonly && !getenv('ZIFY_TRANSACTION')) {
        // A POSIX supervisor owns the lock, signal handling and rollback for the entire command.
        let rc = backend(ctx, 'transaction', ctx.assume_yes && !cli.yes ? ['--yes', ...argv] : argv);
        return rc == 0 ? 0 : 1;
    }
    dispatch(ctx, command, args);
    return 0;
}
catch (e) {
    report('zify: ' + e.message + '\n', true);
    return 1;
}
};

function configure_installed(ctx) {
    initialize_lists(ctx);
    run(ctx, 'service', ['enable']);
    run(ctx, 'service', ['restart']);
}

function atom_main(argv) {
    try {
        let args = [...argv];
        arity(args, 3, 1024);
        check(args[2] == 'zapret' && type(args[1]) == 'string' &&
            (args[1] == '' || match(args[1], /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/)) &&
            !match(args[1], /(^|\/)\.\.?(\/|$)/), 'неверный корень backend');
        let ctx = settings(getenv('ZIFY_HOME'), null);
        ctx.root = args[1]; ctx.state = ctx.root + '/etc/zify'; ctx.base = ctx.root + '/opt/zapret';
        ctx.config = ctx.root + '/etc/config/zapret'; ctx.assets = ctx.state + '/assets'; ctx.file = ctx.root + '/etc/config/zify';
        let action = args[0], values = slice(args, 3);
        let readonly = index(['status', 'config-read', 'config-read-optional'], action) != -1 ||
            (action == 'network' && values[0] == 'status');
        if (!readonly && !getenv('ZIFY_TRANSACTION')) return transact(ctx, 'atom', args) == 0 ? 0 : 1;
        if (index(['state-write', 'hosts-write', 'device-hook-write', 'manager-config-init'], action) != -1) {
            check(length(values), 'не указан файл операции');
            send(ctx, action, slice(values, 1), read(values[0], ctx.max_file_bytes));
        }
        else if (action == 'config-read' || action == 'config-read-optional')
            report(output(ctx, action == 'config-read' ? 'config-get' : 'config-get-optional', values));
        else {
            check(index(['config-set', 'service', 'network', 'asset-file', 'manager-install', 'manager-uninstall',
                'uninstall-cleanup', 'status'], action) != -1, 'неизвестная нативная операция: ' + action);
            run(ctx, action, values);
        }
        return 0;
    }
    catch (e) { report('zify: ' + e.message + '\n', true); return 1; }
};

function cli_main(argv) {
    try {
        let cli = cli_arguments(argv);
        if (cli.command != null) return command_main(argv);
        check(fs.stdin.isatty(), 'меню требует TTY; укажите команду, см. zify --help');
        let ctx = settings(getenv('ZIFY_HOME'), cli.file || getenv('ZIFY_CONFIG'));
        ctx.assume_yes = cli.yes;
        menu(ctx, command_main);
        return 0;
    }
    catch (e) { report('zify: ' + e.message + '\n', true); return 1; }
};


function worker_main(argv) {
    try {
        let args = [...argv], kind = shift(args);
        if (kind == 'transaction') return command_main(args);
        check(kind == 'call' && getenv('ZIFY_TRANSACTION'), 'нет активного супервизора');
        let operation = shift(args), file = shift(args);
        let ctx = settings(getenv('ZIFY_HOME'), file || null);
        if (index(['install', 'cleanup'], operation) != -1) ctx = destination_context(ctx);
        switch (operation) {
        case 'configure': configure_installed(ctx); break;
        case 'cleanup': run(ctx, 'uninstall-cleanup', args); break;
        case 'install': install_manager(ctx, args[0]); break;
        case 'cache': cache_update(ctx, json(args[0])); break;
        case 'self-update': apply_update(ctx); break;
        case 'atom': return atom_main(args);
        default: die('неизвестная внутренняя функция');
        }
        return 0;
    }
    catch (e) { report('zify: ' + e.message + '\n', true); return 1; }
};
__ZIFY_ZIFY_UCODE_7__
)
export ZIFY_UCODE_7

ZIFY_PARTS=7
export ZIFY_PARTS
# Compile definitions in memory; entry functions are selected by trusted source files.
# shellcheck disable=SC2089
ZIFY_BOOTSTRAP='let source = ""; for (let i = 1; i <= +getenv("ZIFY_PARTS"); i++) source += getenv("ZIFY_UCODE_" + i) + "\n"; function zify_run(entry) { loadstring(source + "\n" + entry, { strict_declarations: true })(); }'
ZIFY_HOME=${ZIFY_HOME:-/}
# shellcheck disable=SC2090
export ZIFY_BOOTSTRAP ZIFY_HOME
exec ucode -S -e "$ZIFY_BOOTSTRAP zify_run('exit(cli_main(ARGV));');" -- "$@"
