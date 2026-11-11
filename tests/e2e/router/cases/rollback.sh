#!/bin/sh
set -eu
busy_lock() {
    cp "$conf" "$root/before"
    mkdir "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    trap 'rm -f "$lock/pid"; rmdir "$lock"' 0
    reject zify config set DISABLE_IPV6 1
    cmp "$root/before" "$conf"
    health
}
failed_download() {
    cp /etc/zify/assets/catalogs/flowseal.json "$root/cache-before"
    cp "$conf" "$root/before"
    mkdir -p "$root/fail-bin"
    printf 'function request(url, options) { die("HTTP transport failure"); }; return {request};\n' > "$root/fail-http.uc"
    printf '#!/bin/sh\nexit 22\n' > "$root/fail-bin/curl"
    chmod 755 "$root/fail-bin/curl"
    reject env ZIFY_HTTP_PROVIDER="$root/fail-http.uc" PATH="$root/fail-bin:$PATH" /usr/bin/zify --yes assets-install "$root/nonexistent-assets.tar.gz"
    cmp "$root/cache-before" /etc/zify/assets/catalogs/flowseal.json
    unchanged
}
github_rate_limit() {
    cp /etc/zify/assets/catalogs/flowseal.json "$root/cache-before"
    cp "$conf" "$root/before"
    mkdir -p "$root/rate-bin"
    cat > "$root/rate-bin/curl" <<'EOF'
#!/bin/sh
set -eu
out='' headers=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2;;
        --dump-header) headers=$2; shift 2;;
        *) shift;;
    esac
done
[ -n "$out" ] && [ -n "$headers" ]
printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\n\r\n' > "$headers"
printf '{"message":"API rate limit exceeded for IP"}' > "$out"
printf '403'
EOF
    printf '%s\n' 'function request(url, options) { return {status:403,headers:{"x-ratelimit-remaining":"0"},body:"API rate limit exceeded for IP"}; }; return {request};' > "$root/rate-http.uc"
    chmod 755 "$root/rate-bin/curl"
    set -- install-upstream
    reject env ZIFY_HTTP_PROVIDER="$root/rate-http.uc" PATH="$root/rate-bin:$PATH" /usr/bin/zify --yes "$@" > "$root/api-error" 2>&1
        grep -Fq 'Превышен лимит запросов GitHub API (60/час на ваш IP)' "$root/api-error"
        cmp "$root/cache-before" /etc/zify/assets/catalogs/flowseal.json
    unchanged
    env ZIFY_HTTP_PROVIDER="$root/rate-http.uc" /usr/bin/zify source list flowseal > "$root/local-catalog"
    test -s "$root/local-catalog"
}
rollback_after_write() {
    cp "$conf" "$root/before"
    cp -p /opt/zapret/sync_config.sh "$root/sync.original"
    trap 'cp -p "$root/sync.original" /opt/zapret/sync_config.sh; rm -f "$root/fail-sync"' 0
    {
        printf '#!/bin/sh\n'
        printf 'if [ -f /tmp/zify-e2e/fail-sync ]; then\n'
        printf '  uci get "zapret.@main[0].DISABLE_IPV6" > /tmp/zify-e2e/observed-write\n'
        printf '  rm /tmp/zify-e2e/fail-sync\n  exit 97\nfi\n'
        cat "$root/sync.original"
    } > "$root/sync.injected"
    cp "$root/sync.injected" /opt/zapret/sync_config.sh
    old=$(zify config get DISABLE_IPV6)
    changed=$((1 - old))
    touch "$root/fail-sync"
    reject zify config set DISABLE_IPV6 "$changed"
    [ "$(cat "$root/observed-write")" = "$changed" ]
    unchanged
}
interrupted_transaction() {
    cp "$conf" "$root/before"
    cp -p /opt/zapret/sync_config.sh "$root/sync.original"
    trap 'cp -p "$root/sync.original" /opt/zapret/sync_config.sh; rm -f "$root/pause-sync"' 0
    {
        printf '#!/bin/sh\n'
        printf 'if [ -f /tmp/zify-e2e/pause-sync ]; then\n'
        printf '  touch /tmp/zify-e2e/sync-entered\n'
        printf '  sleep 3\n'
        printf 'fi\n'
        cat "$root/sync.original"
    } > "$root/sync.injected"
    cp "$root/sync.injected" /opt/zapret/sync_config.sh
    old=$(zify config get DISABLE_IPV6)
    touch "$root/pause-sync"
    /usr/bin/zify --yes config set DISABLE_IPV6 "$((1 - old))" &
    job=$!
    attempts=0
    while [ ! -f "$root/sync-entered" ] && [ "$attempts" -lt 60 ]; do sleep 1; attempts=$((attempts + 1)); done
    test -f "$root/sync-entered"
    kill -TERM "$(cat "$lock/pid")"
    rm "$root/pause-sync"
    reject wait "$job"
    unchanged
}
