#!/bin/sh
set -eu
# Upgrading removes only the retired manager cron job and rolls back on cron failure.
mkdir -p "$ZIFY_TEST_ROOT/etc/crontabs"
printf '7 1 * * * /root/other-zapret-job\n' > "$ZIFY_TEST_ROOT/etc/crontabs/root"
cp "$ZIFY_TEST_ROOT/etc/crontabs/root" "$work/cron.unrelated"
printf '0 3 * * * /usr/bin/zify --yes auto-best /tmp/urls /tmp/catalog # zify:zapret\n' >> "$ZIFY_TEST_ROOT/etc/crontabs/root"
cp "$ZIFY_TEST_ROOT/etc/crontabs/root" "$work/cron.legacy"
cp "$ZIFY_TEST_ROOT/usr/bin/zify" "$work/manager.before-migration"
touch "$ZIFY_TEST_ROOT/fail-cron"
bad cli manager-install
equal_file "$ZIFY_TEST_ROOT/etc/crontabs/root" "$work/cron.legacy"
equal_file "$ZIFY_TEST_ROOT/usr/bin/zify" "$work/manager.before-migration"
cli manager-install
equal_file "$ZIFY_TEST_ROOT/etc/crontabs/root" "$work/cron.unrelated"
# The next mutation recovers an abandoned snapshot before checking for a no-op.
lock=$ZIFY_TEST_ROOT/tmp/zify.zapret.lock
cp "$conf" "$work/recovery.before"
cp "$hosts" "$work/hosts.before"
ipv6=$(cli config get DISABLE_IPV6)
mkdir "$lock"
printf '2147483647\n' > "$lock/pid"
cp "$conf" "$lock/0"
cp "$hosts" "$lock/1"
cp "$ZIFY_TEST_ROOT/opt/zapret/ipset/zapret-hosts-user-exclude.txt" "$lock/2"
cp "$ZIFY_TEST_ROOT/opt/zapret/ipset/zapret-hosts-google.txt" "$lock/3"
touch "$lock/ready" "$lock/running"
printf 'corrupted\n' > "$conf"
printf 'corrupted\n' > "$hosts"
cli config set DISABLE_IPV6 "$ipv6"
equal_file "$conf" "$work/recovery.before"
equal_file "$hosts" "$work/hosts.before"
cli status | grep -q running
[ ! -d "$lock" ]
# A live transaction or an ongoing recovery must never be stolen.
mkdir "$lock"
printf '%s\n' "$$" > "$lock/pid"
bad cli config set DISABLE_IPV6 "$ipv6"
equal_file "$conf" "$work/recovery.before"
printf '2147483647\n' > "$lock/pid"
printf '%s\n' "$$" > "$lock/worker.pid"
bad cli config set DISABLE_IPV6 "$ipv6"
equal_file "$conf" "$work/recovery.before"
rm "$lock/worker.pid"
mkdir "$lock/recovering"
bad cli config set DISABLE_IPV6 "$ipv6"
equal_file "$conf" "$work/recovery.before"
rmdir "$lock/recovering"
rm "$lock/pid"
rmdir "$lock"
# Interrupt a real setting change while sync_config is running; rollback waits for it.
cp "$conf" "$work/signal.before"
cp "$statefile" "$work/signal-state.before"
cat > "$ZIFY_TEST_ROOT/opt/zapret/sync_config.sh" <<'EOF'
#!/bin/sh
set -eu
if [ -f "$ZIFY_TEST_ROOT/pause-sync" ]; then
    touch "$ZIFY_TEST_ROOT/sync-entered"
    while [ -f "$ZIFY_TEST_ROOT/pause-sync" ]; do sleep 0.01; done
fi
EOF
touch "$ZIFY_TEST_ROOT/pause-sync"
cli config set DISABLE_IPV6 "$((1 - ipv6))" > "$work/signal.log" 2>&1 &
job=$!
attempt=0
while [ ! -f "$ZIFY_TEST_ROOT/sync-entered" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
done
[ -f "$ZIFY_TEST_ROOT/sync-entered" ]
kill -TERM "$(cat "$lock/pid")"
rm -f "$ZIFY_TEST_ROOT/pause-sync"
if wait "$job"; then printf '%s\n' 'interrupted setting change succeeded unexpectedly' >&2; exit 1; fi
equal_file "$conf" "$work/signal.before"
equal_file "$statefile" "$work/signal-state.before"
cli status | grep -q running
[ ! -d "$lock" ]
rm "$ZIFY_TEST_ROOT/opt/zapret/sync_config.sh"
printf '%s\n' 'transactions: legacy cron migration, abandoned snapshots, contention and interrupted setting rollback OK'
