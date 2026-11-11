#!/bin/sh
# shellcheck source=src/shell/common.sh
. "$(dirname "$0")/common.sh"

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
