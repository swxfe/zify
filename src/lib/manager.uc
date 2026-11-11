import { report, execute } from 'console';
import * as fs from 'fs';
import { sha256 } from 'digest';
import { http_request } from 'http';
import { cached } from 'cache';
import { check, read, run, send, output, transact } from 'common';
import { embedded_header, embedded_footer, VERSION, UPDATE_REPO, UPDATE_BRANCH, UPDATE_PATH } from 'resources';
import { default_settings, settings_text } from 'settings';
import { install_assets } from 'assets';

export function newer_version(candidate, current) {
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

export function render_bundle(ctx) {
    if (embedded_header() == null) {
        check(execute(['/bin/sh', ctx.home + '/tools/bundle.sh']) == 0, 'не удалось собрать zify');
        return read(ctx.home + '/dist/zify.sh', ctx.max_file_bytes);
    }
    let body = embedded_header() + shell_value('ZIFY_BACKEND', getenv('ZIFY_BACKEND'));
    let count = +getenv('ZIFY_PARTS');
    for (let i = 1; i <= count; i++) body += shell_value('ZIFY_UCODE_' + i, getenv('ZIFY_UCODE_' + i));
    return body + 'ZIFY_PARTS=' + count + '\nexport ZIFY_PARTS\n' + embedded_footer();
};

export function install_manager(ctx, archive) {
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

export function update_status(ctx) {
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

export function check_update(ctx) {
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

export function cache_update(ctx, data) {
    check(getenv('ZIFY_TRANSACTION') && type(data) == 'object' && data.origin == update_origin() &&
        type(data.revision) == 'string' && match(data.revision, /^[a-f0-9]{40}$/) &&
        type(data.checked) == 'int' && data.checked > 0, 'неверный кэш обновления');
    newer_version(data.version, VERSION);
    if (getenv('ZIFY_BACKGROUND_UPDATE') == '1' && fs.stat(ctx.root + '/usr/bin/zify') == null) return;
    send(ctx, 'state-write', ['update.json'], sprintf('%J\n', data));
};

export function apply_update(ctx) {
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
