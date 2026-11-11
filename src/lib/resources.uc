import * as fs from 'fs';

let resource_cache = {};
export const VERSION = '1.0';
export const UPDATE_REPO = 'swxfe/zify';
export const UPDATE_BRANCH = 'main';
export const UPDATE_PATH = 'dist/zify.sh';
export const INSTALLER_REPO = 'remittor/zapret-openwrt';

export function embedded_header() { return null; };
export function embedded_footer() { return null; };

export function resource(directory, name) {
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
