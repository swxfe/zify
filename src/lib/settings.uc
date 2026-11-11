import * as fs from 'fs';
import * as uci from 'uci';

import { check, read } from 'common';

export function default_settings() {
    return { root: '/', connect_timeout: 4, request_timeout: 10,
        max_file_bytes: 2097152, max_strategies: 256 };
};

const SETTING_GROUPS = { main: ['root', 'connect_timeout', 'request_timeout', 'max_file_bytes', 'max_strategies'] };
const RETIRED_SETTINGS = ['settle_seconds', 'max_domains', 'max_urls'];

export function settings_text(c) {
    let body = '';
    for (let section, options in SETTING_GROUPS) {
        let values = section == 'main' ? c : c[section];
        if (values == null) continue;
        body += "config " + (section == 'main' ? 'zify' : section) + " '" + section + "'\n";
        for (let option in options) {
            if (values[option] == null) continue;
            let value = '' + values[option];
            check(index(value, '\n') == -1 && index(value, '\r') == -1 && index(value, '\x00') == -1 && index(value, "'") == -1, 'неверное значение настройки: ' + option);
            body += "\toption " + option + " '" + value + "'\n";
        }
        body += '\n';
    }
    return body;
};

export function read_settings(file) {
    let name = fs.basename(file);
    check(match(name, /^[A-Za-z0-9_-]+$/), 'имя UCI-файла: только буквы, цифры, _ и -');
    read(file, 65536);
    let handle = uci.cursor(fs.dirname(file), '/dev/null', '', { strict: true, print_errors: false });
    check(handle && handle.load(name), 'неверный UCI-конфиг zify: ' + file);
    let c = default_settings(), seen = {};
    check(handle.foreach(name, null, (section) => {
        let id = section['.name'];
        // Previous releases exposed repository settings; they no longer affect endpoints.
        if ((id == 'updater' || id == 'sources' || id == 'hostlist_urls') && section['.type'] == id) return;
        let options = SETTING_GROUPS[id];
        check(options != null && section['.type'] == (id == 'main' ? 'zify' : id) && !seen[id], 'неизвестная секция UCI: ' + id);
        seen[id] = true;
        let target = id == 'main' ? c : {};
        for (let key, value in section) {
            if (substr(key, 0, 1) == '.') continue;
            if (id == 'main' && index(RETIRED_SETTINGS, key) != -1) {
                check(type(value) == 'string' && match(value, /^[0-9]+$/), 'неверная устаревшая настройка: ' + key);
                continue;
            }
            check(index(options, key) != -1 && type(value) == 'string', 'неизвестная или списочная настройка: ' + key);
            if (id == 'main' && key != 'root') {
                check(match(value, /^[0-9]+$/) && length(value) <= 8, 'настройка должна быть числом: ' + key);
                value = +value;
            }
            target[key] = value;
        }
        if (id != 'main') c[id] = target;
    }), 'не удалось прочитать настройки UCI');
    check(seen.main, 'нет секции config zify main');
    handle.unload(name);
    return c;
};

export function settings(home, file) {
    file = file || (fs.stat('/etc/config/zify') ? '/etc/config/zify' : null);
    let c = file ? read_settings(file) : default_settings();
    c.profile = 'zapret';
    check(type(c.root) == 'string' && match(c.root, /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/) &&
          !match(c.root, /(^|\/)\.\.?(\/|$)/), 'root: нужен абсолютный путь без . и ..');
    c.root = c.root == '/' ? '' : replace(c.root, /\/$/, '');
    for (let key in ['connect_timeout', 'request_timeout', 'max_file_bytes', 'max_strategies']) {
        check(type(c[key]) == 'int' && c[key] >= 1 &&
              c[key] <= (key == 'max_file_bytes' ? 8388608 : 50000), 'некорректная настройка: ' + key);
    }
    check(c.connect_timeout <= c.request_timeout && c.request_timeout <= 300 &&
          c.max_strategies <= 1024,
          'таймауты или лимиты превышены');
    c.home = home;
    c.file = file || c.root + '/etc/config/zify';
    c.config = c.root + '/etc/config/' + c.profile;
    c.base = c.root + '/opt/' + c.profile;
    c.state = c.root + '/etc/zify';
    c.assets = c.state + '/assets';
    c.resources = fs.stat(c.assets + '/resources') ? c.assets + '/resources' :
        (home != '/' ? home + '/data' : c.assets + '/resources');
    return c;
};
