# Compile definitions in memory; entry functions are selected by trusted source files.
# shellcheck disable=SC2089
ZIFY_BOOTSTRAP='let source = ""; for (let i = 1; i <= +getenv("ZIFY_PARTS"); i++) source += getenv("ZIFY_UCODE_" + i) + "\n"; function zify_run(entry) { loadstring(source + "\n" + entry, { strict_declarations: true })(); }'
ZIFY_HOME=${ZIFY_HOME:-/}
# shellcheck disable=SC2090
export ZIFY_BOOTSTRAP ZIFY_HOME
exec ucode -S -e "$ZIFY_BOOTSTRAP zify_run('exit(cli_main(ARGV));');" -- "$@"
