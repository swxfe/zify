#!/bin/sh
# Test functions are selected by the validated --case dispatcher below.
# shellcheck disable=SC2329
set -eu
umask 077
zify() { /usr/bin/zify --yes "$@"; }
# Test-only util-linux PTY: the CLI must still reject real pipes without a TTY.
terminal_command() { TERM=xterm-256color script -q -e -c "$1" /dev/null; }
root=/tmp/zify-e2e
conf=/etc/config/zapret
lock=/tmp/zify.zapret.lock
[ "${ZIFY_E2E_GUEST:-}" = 1 ] && [ -f "$root/guard" ] && [ -f /etc/openwrt_release ] || exit 2
reject() { if "$@"; then printf 'unexpected success: %s\n' "$*" >&2; return 1; fi; }
nfqws_pids() {
    # BusyBox -x matches argv[0] (the full path), unlike procps on the host.
    pgrep -f '^/opt/zapret/nfq/nfqws([[:space:]]|$)'
}
health() {
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        if /etc/init.d/zapret running && nfqws_pids > "$root/pids"; then
            nft list table inet zapret > "$root/rules"
            grep -q 'chain ' "$root/rules"
            /etc/init.d/zapret enabled || { printf '%s\n' 'health: Zapret не включён в автозагрузку' >&2; return 1; }
            return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    printf '%s\n' 'health: procd или процесс nfqws не готов за 20 секунд' >&2
    return 1
}
unchanged() { cmp "$root/before" "$conf"; health; [ ! -d "$lock" ]; }
baseline_files() {
    mode=$1
    index=0
    set -- "$conf" /opt/zapret/ipset/zapret-hosts-user.txt \
        /opt/zapret/ipset/zapret-hosts-user-exclude.txt /opt/zapret/ipset/zapret-hosts-google.txt \
        /etc/zify/state.json /etc/zify/devices.txt \
        /opt/zapret/init.d/openwrt/custom.d/20-zify-exclude.sh
    for path do
        [ "$mode" = restore ] || { [ -f "$path" ] && [ ! -L "$path" ]; } || return 1
        if [ "$mode" = save ]; then cp -p "$path" "$root/baseline-files/$index" || return 1
        elif [ "$mode" = restore ]; then
            mkdir -p "$(dirname "$path")" || return 1
            cp -p "$root/baseline-files/$index" "$path.e2e.tmp" || return 1
            mv -f "$path.e2e.tmp" "$path" || return 1
        else cmp -s "$path" "$root/baseline-files/$index" || return 1; fi
        index=$((index + 1))
    done
    # Copy-on-write may change mtimes; compare permissions and ownership in addition to bytes.
    LC_ALL=C ls -ldn "$@" > "$root/baseline-metadata.raw" || return 1
    if [ "$mode" = save ]; then awk '{print $1, $3, $4}' "$root/baseline-metadata.raw" > "$root/baseline-files/metadata"
    else
        awk '{print $1, $3, $4}' "$root/baseline-metadata.raw" > "$root/baseline-current-metadata" || return 1
        cmp -s "$root/baseline-current-metadata" "$root/baseline-files/metadata"
    fi
}
baseline_running() {
    /etc/init.d/zapret running || return 1
    nfqws_pids > "$root/pids" || return 1
    nft list table inet zapret > "$root/rules" || return 1
    grep -q 'chain ' "$root/rules"
}
reset() {
    # A killed fault-injection worker must not affect the next independent case.
    if [ -f "$root/sync.original" ]; then cp -p "$root/sync.original" /opt/zapret/sync_config.sh; fi
    rm -f "$root/fail-sync" "$root/probe-entered"
    if [ -d "$lock" ]; then zify service restart; fi
    if ! cmp -s "$root/firewall" /etc/config/firewall; then
        cp -p "$root/firewall" /etc/config/firewall
        /etc/init.d/firewall restart
    fi
    if [ -f "$root/cron.absent" ]; then
        if [ -f /etc/crontabs/root ]; then rm /etc/crontabs/root; /etc/init.d/cron restart; fi
    elif ! cmp -s "$root/cron" /etc/crontabs/root; then
        cp -p "$root/cron" /etc/crontabs/root
        /etc/init.d/cron restart
    fi
    rm -f /etc/zify/offload.previous
    # Test-only snapshots isolate cases without exposing a user backup command.
    if ! baseline_files check; then baseline_files restore; zify service restart; fi
    if ! baseline_running; then zify service restart; fi
    if ! /etc/init.d/zapret enabled; then zify service enable; fi
    health
}
