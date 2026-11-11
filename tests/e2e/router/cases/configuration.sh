#!/bin/sh
set -eu
public_contract() {
    reject /usr/bin/zify < /dev/null > "$root/no-tty" 2>&1
    grep -q TTY "$root/no-tty"
    printf 'q\n' | terminal_command /usr/bin/zify > "$root/menu" || { cat "$root/menu"; return 1; }
    grep -q zify "$root/menu"
    reject grep -q Blockcheck "$root/menu"
    grep -q 'base_general' "$root/menu"
    /usr/bin/zify status | grep -q running
    reject /usr/bin/zify --internal
    reject /usr/bin/zify backend-operation
    zify version
    for command in blockcheck hosts backup test benchmark auto-best targets schedule doctor recover install update remove; do
        reject zify "$command"
    done
    reject zify config show
}
packages_luci() {
    for package in zapret luci-app-zapret; do
        if command -v apk >/dev/null 2>&1; then apk info -e "$package"
        else opkg status "$package" | grep -q 'Status: .* installed'; fi
    done
    ucode -S -e '
        import * as fs from "fs";
        import { sha256 } from "digest";
        let manifest=json(fs.readfile("/etc/zify/assets/manifest.json"));
        for (let fake in manifest.fakes) {
            assert(fake.source == "flowseal" && fake.path == "/opt/zapret/fakes/" + fake.name, "isolated Flowseal path");
            let entry=filter(manifest.files, (entry) => entry.target == "fake" && entry.name == fake.name)[0];
            let payload=fs.readfile(fake.path);
            assert(payload != null && sha256(payload) == entry.sha256, "package installation must preserve Flowseal bytes: " + fake.name);
        }
    '
    test -s /usr/share/luci/menu.d/luci-app-zapret.json
    test -s /www/luci-static/resources/view/zapret/settings.js
    curl --fail --max-time 10 http://127.0.0.1/luci-static/resources/view/zapret/settings.js > "$root/luci.js"
    test -s "$root/luci.js"
}
live_status() { zify status; health; }
noop_preserves_process() {
    cp "$conf" "$root/before"
    nfqws_pids > "$root/noop-pids.before"
    ipv6=$(zify config get DISABLE_IPV6)
    zify config set DISABLE_IPV6 "$ipv6"
    zify source apply flowseal base_general
    unchanged
    nfqws_pids > "$root/noop-pids.after"
    cmp "$root/noop-pids.before" "$root/noop-pids.after"
}
preset_label() {
    zify config get NFQWS_OPT > "$root/opts"
    [ "$(grep -c '^#base_general$' "$root/opts")" -eq 1 ]
    [ "$(grep -c '^#' "$root/opts")" -eq 1 ]
    [ "$(zify source show flowseal base_general)" = "$(zify config get NFQWS_OPT)" ]
    health
}
modified_label() {
    zify source show flowseal base_general > "$root/original.opts"
    sed 's/^--filter-tcp=80,443$/--filter-tcp=80,444/' "$root/original.opts" > "$root/modified.opts"
    reject cmp -s "$root/original.opts" "$root/modified.opts"
    uci set "zapret.@main[0].NFQWS_OPT=$(cat "$root/modified.opts")"
    uci commit zapret
    printf 'q\n' | terminal_command /usr/bin/zify > "$root/menu" || { cat "$root/menu"; return 1; }
    grep -q 'base_general (изменена пользователем)' "$root/menu" || { cat "$root/menu"; return 1; }
    health
}
invalid_ports() {
    nfqws_pids > "$root/reject-pids.before"
    cp "$conf" "$root/before"
    printf '%s\n' '--filter-tcp=999999' '--dpi-desync=fake' > "$root/invalid-ports.txt"
    reject zify strategy import "$root/invalid-ports.txt"
    unchanged
    printf '%s\n' '--filter-udp=500-10' '--dpi-desync=fake' > "$root/invalid-ports.txt"
    reject zify strategy import "$root/invalid-ports.txt"
    nfqws_pids > "$root/reject-pids.after"
    cmp "$root/reject-pids.before" "$root/reject-pids.after"
    unchanged
}
invalid_strategy() {
    cp "$conf" "$root/before"
    reject zify source apply flowseal missing-e2e-preset
    # This substitution must stay literal so the strategy validator can reject it.
    # shellcheck disable=SC2016
    printf '%s\n' '--filter-tcp=443' '--x=$(touch /tmp/zify-e2e/injected)' > "$root/bad.txt"
    reject zify strategy import "$root/bad.txt"
    [ ! -e "$root/injected" ]
    unchanged
}
service_cycle() {
    zify service stop
    reject nfqws_pids
    zify status | grep -q stopped
    zify service start
    health
    zify service restart
    health
}
autostart() {
    zify service disable
    reject /etc/init.d/zapret enabled
    zify service enable
    /etc/init.d/zapret enabled
}
settings() {
    zify config set DISABLE_IPV6 1
    [ "$(zify config get DISABLE_IPV6)" = 1 ]
    zify config set DISABLE_IPV6 0
    [ "$(zify config get DISABLE_IPV6)" = 0 ]
    health
}
