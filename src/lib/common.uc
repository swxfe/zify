import { report, execute } from 'console';
import * as fs from 'fs';
import { config_option, native_running } from 'platform';
import { native_send, native_action } from 'mutations';
import { invalidate } from 'cache';
import { http_request } from 'http';

export function check(condition, message) {
    if (!condition) die(message);
};

export function approve(ctx, question) {
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

export function tempdir() {
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

export function read(path, limit) {
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

export function backend(ctx, action, args) {
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

export function transact(ctx, operation, args) {
    return backend(ctx, 'call', [operation, fs.stat(ctx.file) ? ctx.file : '', ...(args || [])]);
};

export function run(ctx, action, args) {
    let rc = backend(ctx, action, args);
    check(rc == 0, sprintf('%s: код завершения %d', action, rc));
};

export function output(ctx, action, args) {
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

export function send(ctx, action, args, text) {
    check(native_send(ctx, action, args || [], text, safety_operation), 'неизвестная операция записи: ' + action);
};

export function invoke(ctx, args) {
    return backend(ctx, 'transaction', [...(fs.stat(ctx.file) ? ['--config', ctx.file] : []), ...args]);
};
