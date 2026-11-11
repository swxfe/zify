import * as fs from 'fs';

let console_log = null;

// Only interactive actions capture output; CLI stdout/stderr keep their contract.
export function capture_output(path) { console_log = path; };

export function report(text, error) {
    let target = console_log ? fs.open(console_log, 'a') : (error ? fs.stderr : fs.stdout);
    if (target == null) die('не удалось открыть журнал действия');
    target.write(text); target.flush();
    if (console_log) target.close();
};

export function execute(args) {
    if (!console_log) return system(args);
    // Preserve a visible channel for interactive confirmations in transaction workers.
    return system(['/bin/sh', '-c',
        'log=$1; shift; exec 9>&2; ZIFY_MENU_PROMPT_FD=9; export ZIFY_MENU_PROMPT_FD; exec "$@" >>"$log" 2>&1',
        'zify-action', console_log, ...args]);
};
