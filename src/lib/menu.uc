import * as fs from 'fs';
import { session_cache, cached } from 'cache';
import { capture_output, report } from 'console';
import { check, invoke, tempdir } from 'common';
import { config_option } from 'platform';
import { VERSION } from 'resources';
import { update_status, check_update, apply_update } from 'manager';
import { strategy_key, strategy_group, strategy_title, strategy_order } from 'strategies';
import { source_data } from 'sources';
import { current_fakes, fake_catalog, group_fakes } from 'fakes';
import { device_list, excluded } from 'devices';
import { zapret_status, strategy_state, flow_status, quic_status } from 'status';
import { terminal_cooked, terminal_frame, terminal_pad, terminal_view, tone, terminal_open, terminal_close, terminal_resume, terminal_signals, terminal_raw, terminal_interrupted, terminal_select, terminal_input } from 'terminal';

let ended = false, assume_yes = false, menu_executor = null, menu_ctx = null, notice = '', action_active = false;

function service_header(ctx, strategy) {
    let state = cached(ctx, 'zapret-status', () => zapret_status(ctx));
    return [tone('white', 'Zapret ') + tone(state.running ? 'green' : 'red', '●') + ' ' +
        tone('white', state.installed ? (state.running == null ? 'состояние неизвестно' : (state.running ? 'активен' : 'остановлен')) : 'не установлен') +
        (state.installed ? tone('dim', ' · ') + tone('steel', state.version) : ''),
        ...(strategy ? [tone('white', 'Стратегия: ') + tone('steel', state.strategy)] : [])];
}

function prompt(label, fallback) {
    let value = terminal_input(label, fallback);
    if (value == null) ended = true;
    return value;
}
function choice(title, labels, options) {
    options = options || {};
    let value = terminal_select(title, labels, { header: menu_ctx ? service_header(menu_ctx) : [],
        notice, menu: false, ...options });
    notice = '';
    if (value == null) { ended = true; return 0; }
    return value;
}

// Each open category owns its cursor; leaving it discards the selection.
function menu_choices() {
    let selected = 0;
    return (title, labels, options) => {
        let value = choice(title, labels, { ...(options || {}), selected });
        if (type(value) == 'int' && value > 0) selected = value - 1;
        else if (type(value) == 'object' && value.toggle != null) selected = value.toggle;
        return value;
    };
}

function command(ctx, args) {
    let cooked = terminal_raw() && action_active, rc;
    if (cooked) terminal_cooked();
    try {
        rc = menu_executor ? menu_executor([...(cached(ctx, 'settings-file-exists', () => fs.stat(ctx.file) != null) ? ['--config', ctx.file] : []), ...args], ctx) : invoke(ctx, args);
    }
    catch (e) { if (cooked) terminal_resume(); die(e.message); }
    if (cooked) terminal_resume();
    terminal_signals();
    check(rc == 0, 'действие не выполнено; причина указана в журнале');
}

function perform(fn, message) {
    let failed = false, folder = tempdir();
    capture_output(folder + '/output'); action_active = true;
    terminal_frame('Применение', [], { header: ['Выполняется действие…'], footer: ['Пожалуйста, подождите'] });
    try { let result = fn(); notice = result == false ? '' : (type(result) == 'string' ? result : (message || 'Готово')); }
    catch (e) { failed = true; notice = 'Ошибка: ' + e.message; }
    capture_output(null); action_active = false;
    let details = fs.readfile(folder + '/output', 65536) || '';
    fs.unlink(folder + '/output'); fs.rmdir(folder);
    if (terminal_interrupted()) ended = true;
    terminal_resume();
    if (!ended && failed && !terminal_view('Ошибка', details, notice, true)) ended = true;
}

function confirm(text) {
    if (assume_yes) return true;
    return choice('Подтверждение', ['Отмена'], { header: [tone('yellow', text)], menu: false,
        extra: ['y'], footer: ['Y — подтвердить · Q / ← — отмена'] }) == 'y';
}
function local_file(label, fallback) {
    let value = prompt(label, fallback); check(value != null && length(value), 'путь не указан'); return value;
}

function explicit_group(ctx, group) {
    let sections = filter(strategy_state(ctx).sections, (s) => strategy_group(s.name) == group);
    return length(sections) ? join(' + ', map(sections, (s) => s.name)) : 'отключено';
}

function choose_strategy(ctx, kind, group) {
    while (!ended) {
        let data;
        try { data = source_data(ctx, kind); }
        catch (e) { notice = e.message; return null; }
        let list = filter(data.strategies, (s) => group != null ? strategy_group(s.name) == group : strategy_group(s.name) == null);
        sort(list, strategy_order);
        if (!length(list)) { notice = 'В каталоге нет стратегий этой группы'; return null; }
        let active = strategy_state(ctx).sections, selected = 0;
        let labels = map(list, (s, i) => {
            let current = length(filter(active, (a) => a.name == strategy_key(s.name) && !a.changed)) > 0;
            if (current) selected = i;
            let label = strategy_title(s.name) + (length(s.missing || []) ? ' · нет фейка: ' + join(', ', s.missing) : '') + (current ? '  (активна)' : '');
            return current ? tone('steel', label) : label;
        });
        let group_name = { base: 'базовый трафик', youtube: 'YouTube', discord: 'Discord', games: 'игры' }[group];
        let title = group == null ? 'стратегии > flowseal' : 'стратегии > ' + (group == 'games' ? 'игры' : 'сборка > ' + group_name);
        let value = choice(title, labels, { selected, menu: false, extra: ['d'], header: [
            tone('white', group == null ? 'Стратегия: ' : 'Сейчас: ') + tone('steel', group == null ? strategy_state(ctx).summary : explicit_group(ctx, group)) +
                tone('dim', ' · ') + 'каталог ' + tone('steel', substr(data.revision, 0, 8))],
            footer: ['↑↓ / номер — выбор · Enter — применить', 'Q / ← — назад · D — отключить'] });
        if (!value) return null;
        if (value == 'd') return { disable: true };
        if (length(list[value - 1].missing || [])) { notice = 'Нет фейков Flowseal: ' + join(', ', list[value - 1].missing); continue; }
        return list[value - 1];
    }
    return null;
}

function edit_group(ctx, group) {
    let selected = choose_strategy(ctx, 'manager', group);
    if (selected) perform(() => {
        command(ctx, selected.disable ? ['source', 'remove', 'manager', group] : ['source', 'select', 'manager', selected.name]);
        let current = explicit_group(ctx, group);
        return selected.disable ? (current == 'отключено' ? 'Группа отключена' : 'Изменение отменено') :
            (current == selected.name ? 'Применено: ' + selected.name : 'Изменение отменено');
    });
}

function compose_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let groups = ['base', 'youtube', 'discord'];
        let labels = ['Базовый трафик', 'YouTube', 'Discord'];
        let value = choose('стратегии > сборка', map(groups, (group, i) => terminal_pad(labels[i], 19) + explicit_group(ctx, group)),
            { menu: true, header: [tone('white', 'Стратегия: ') + tone('steel', strategy_state(ctx).summary)] });
        if (!value) return;
        edit_group(ctx, groups[value - 1]);
    }
}

function fake_purpose(slot) {
    let names = {
        'fake-tls': 'TLS', 'fake-http': 'HTTP', 'fake-quic': 'QUIC',
        'fake-discord': 'Discord', 'fake-stun': 'STUN', 'fake-unknown-udp': 'UDP',
        'fake-unknown': 'Другой трафик', 'fake-syn': 'SYN'
    };
    let key = replace(slot.option, /^--dpi-desync-/, '');
    return names[key] || key;
}

function choose_fake(ctx, slot) {
    let list = fake_catalog(ctx, 'flowseal');
    let value = choice('Фейки > замена', map(list, (name) => name == slot.filename ? tone('steel', name + '  (текущий)') : name),
        { page_size: 12, menu: false, header: [slot.filename + ' → ' + fake_purpose(slot),
            tone('gray', 'Каталог Flowseal · выбирайте файл подходящего формата')],
            footer: ['N — далее · P — назад · ↑↓ / номер / Enter — файл', 'Q / ← — отмена'] });
    return value ? list[value - 1] : null;
}

function edit_fake(ctx, slot) {
    let name = choose_fake(ctx, slot);
    if (name) perform(() => command(ctx, ['fake', 'replace', '' + slot.line, slot.path, 'flowseal', name]), fake_purpose(slot) + ' → ' + name);
}

function fake_targets_menu(ctx, path) {
    let choose = menu_choices();
    while (!ended) {
        let group = filter(group_fakes(current_fakes(ctx)), (g) => g.path == path)[0];
        if (!group) return;
        let target = choose(group.filename + ' > где заменить', map(group.slots, (s) => fake_purpose(s) + ' · ' + s.section + ' · профиль ' + s.profile), { menu: true });
        if (!target) return;
        edit_fake(ctx, group.slots[target - 1]);
    }
}

function fake_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let groups = group_fakes(current_fakes(ctx));
        if (!length(groups)) { notice = 'В текущей стратегии нет .bin файлов для замены'; return; }
        let value = choose('Фейки', map(groups, (g) => join(', ', g.sections) + ' · ' + g.filename), { menu: true, header: ['Файлов в текущей стратегии: ' + length(groups)] });
        if (!value) return;
        let group = groups[value - 1];
        if (length(group.slots) > 1) fake_targets_menu(ctx, group.path);
        else edit_fake(ctx, group.slots[0]);
    }
}

function strategy_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let value = choose('стратегии', ['Стратегии Flowseal', 'Собрать: основная + YouTube + Discord', 'Игры', 'Фейки', 'Очистить стратегию'],
            { kinds: ['menu', 'menu', 'menu', 'menu', 'action'], menu: false,
                header: [tone('white', 'Стратегия: ') + tone('steel', strategy_state(ctx).summary)] });
        if (!value) return;
        if (value == 1) {
            while (!ended) {
                let selected = choose_strategy(ctx, 'flowseal', null);
                if (!selected) break;
                perform(() => command(ctx, selected.disable ? ['source', 'remove', 'flowseal'] : ['source', 'select', 'flowseal', selected.name]),
                    selected.disable ? 'Flowseal отключён' : 'Применено: ' + strategy_title(selected.name));
            }
        }
        if (value == 2) compose_menu(ctx);
        if (value == 3) edit_group(ctx, 'games');
        if (value == 4) fake_menu(ctx);
        if (value == 5 && confirm('Очистить все текущие стратегии и остановить Zapret')) perform(() => {
            command(ctx, ['strategy', 'clear']);
            let message = length(strategy_state(ctx).sections) ? 'Очистка отменена' : 'Стратегия очищена';
            report(message + '\n'); return message;
        });
    }
}

function uninstall_menu(ctx) {
    let choose = menu_choices();
    let selected = { zapret: false, luci: false, manager: false, files: false, config: false };
    while (!ended) {
        let rows = [{ key: 'zapret', label: 'Zapret (ядро и службы)' }];
        if (selected.zapret) push(rows, { key: 'files', label: 'Файлы: стратегии и фейки', child: true });
        push(rows, { key: 'luci', label: 'LuCI (веб-интерфейс)' });
        push(rows, { key: 'manager', label: 'zify (менеджер)' });
        if (selected.manager) push(rows, { key: 'config', label: 'Служебная конфигурация', child: true });
        let value = choose('установка и удаление > удаление', map(rows, (r) => ({ ...r, checked: selected[r.key] })),
            { checkboxes: true, menu: false, header: ['Отметьте компоненты пробелом'],
                footer: ['↑↓ / номер — выбор · Пробел — отметить', 'Enter — удалить · Q / ← — назад'] });
        if (!value) return;
        if (value.toggle != null) {
            let key = rows[value.toggle].key; selected[key] = !selected[key];
            if (!selected.zapret) selected.files = false;
            if (!selected.manager) selected.config = false;
            continue;
        }
        let names = filter(['zapret', 'luci', 'manager', 'files', 'config'], (name) => selected[name]);
        if (!length(names)) { notice = 'Выберите компоненты пробелом'; continue; }
        let labels = { zapret: 'Zapret', luci: 'LuCI', manager: 'zify', files: 'файлы Zapret', config: 'конфигурация zify' };
        if (!confirm('Удалить: ' + join(', ', map(names, (name) => labels[name])))) { notice = 'Удаление отменено'; continue; }
        perform(() => { command(ctx, ['uninstall', 'components', ...names]); if (selected.manager) ended = true; }, 'Выбранные компоненты удалены');
        if (!ended) return;
    }
}

function install_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let state = cached(ctx, 'zapret-status', () => zapret_status(ctx)), update = update_status(ctx);
        let value = choose('установка и удаление', ['Обновить zify' + (update.available ? '  (' + VERSION + ' → ' + update.version + ')' : ''),
            state.installed ? 'Обновить Zapret' : 'Установить Zapret', 'Обновить всё разом', 'Выборочное удаление'],
            { menu: false, kinds: ['action', 'action', 'action', 'menu'], header: ['Управление компонентами'] });
        if (!value) return;
        if (value == 4) { uninstall_menu(ctx); continue; }
        perform(() => {
            if (value == 2 || value == 3) command(ctx, ['install-upstream']);
            if (value == 1 || value == 3) {
                let info = check_update(ctx);
                if (info.available) { apply_update(ctx); report('zify обновлён. Перезапустите менеджер.\n'); ended = true; }
                else report('Установлена последняя версия zify.\n');
            }
        });
    }
}

function service_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let enabled = cached(ctx, 'autostart', () => length(fs.glob(ctx.root + '/etc/rc.d/S??zapret') || []) > 0);
        let value = choose('запуск и автозапуск', ['Запустить', 'Остановить', 'Перезапустить', 'Включить автозапуск', 'Выключить автозапуск'],
            { menu: false, header: [service_header(ctx)[0], tone('white', 'Автозапуск: ') + tone(enabled ? 'steel' : 'gray', enabled ? 'включен' : 'выключен')] });
        if (!value) return;
        perform(() => command(ctx, ['service', ['start', 'stop', 'restart', 'enable', 'disable'][value - 1]]));
    }
}

function devices_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let devices = device_list(ctx), current = excluded(ctx);
        let labels = map(devices, (item) => (index(current, item.ip) == -1 ? '[Zapret] ' : '[Исключён] ') + item.ip + ' · ' + item.name);
        push(labels, 'Ввести IP вручную'); push(labels, 'Очистить исключения');
        let value = choose('настройки > устройства', labels, { menu: false, header: [service_header(ctx)[0],
            'Исключено устройств: ' + length(current)] });
        if (!value) return;
        perform(() => {
            if (value == length(labels)) { if (confirm('Очистить все исключения устройств')) command(ctx, ['devices', 'clear']); return; }
            let ip = value == length(devices) + 1 ? local_file('IPv4 устройства', null) : devices[value - 1].ip;
            command(ctx, ['devices', 'toggle', ip]);
        });
    }
}

function flow_menu(ctx) {
    let choose = menu_choices();
    while (!ended) {
        let state;
        try { state = flow_status(ctx); } catch (e) { notice = e.message; return; }
        let names = { donttouch: 'системный режим', none: 'выключено', software: 'программное', hardware: 'аппаратное' };
        let value = choose('настройки > Flow Offloading', ['Программное ускорение Zapret', 'Аппаратное ускорение Zapret',
            'Отключить ускорение', 'Не управлять ускорением', 'Вернуть настройки до изменений zify'],
            { menu: false, header: ['Zapret: ' + tone('steel', names[state.mode] || state.mode),
                tone('gray', 'Системное: software ' + (state.software ? 'вкл' : 'выкл') + ' · hardware ' + (state.hardware ? 'вкл' : 'выкл'))],
                footer: ['↑↓ / номер — выбор · Enter — применить', 'Q / ← — назад'],
                notice: notice || 'Выборочным offload управляют штатные скрипты Zapret' });
        if (!value) return;
        if (value == 5 && !state.saved) { notice = 'Сохранённых настроек нет'; continue; }
        perform(() => command(ctx, ['network', 'offload', ['software', 'hardware', 'none', 'donttouch', 'restore'][value - 1]]));
    }
}

function config_menu(ctx) {
    let choose = menu_choices();
    if (!fs.stat(ctx.config)) { notice = 'Сначала установите Zapret'; return; }
    while (!ended) {
        let value = choose('Настройки Zapret', ['IPv6', 'Исключить устройства из Zapret', 'Блокировка QUIC (UDP 80/443)', 'Flow Offloading'], { menu: true, header: [service_header(ctx)[0], 'IPv6: ' + (trim(config_option(ctx, 'DISABLE_IPV6', true)) == '1' ? 'выключен' : 'включён') +
                ' · QUIC: ' + (quic_status(ctx) ? 'заблокирован' : 'разрешён')] });
        if (!value) return;
        if (value == 2) { devices_menu(ctx); continue; }
        if (value == 4) { flow_menu(ctx); continue; }
        if (value == 1) {
            let active = trim(config_option(ctx, 'DISABLE_IPV6', true)) != '1';
            let next = choice('настройки > IPv6', ['Включить IPv6 в Zapret', 'Отключить IPv6 в Zapret'], { menu: false,
                header: [service_header(ctx)[0], 'IPv6 в Zapret: ' + tone(active ? 'green' : 'gray', active ? 'включён' : 'выключен')] });
            if (next) perform(() => command(ctx, ['config', 'set', 'DISABLE_IPV6', next == 1 ? '0' : '1']));
        }
        if (value == 3) {
            let blocked = quic_status(ctx);
            let next = choice('настройки > QUIC', ['Включить блокировку QUIC', 'Отключить блокировку QUIC'],
                { menu: false, header: [service_header(ctx)[0], 'Блокировка UDP 80/443: ' +
                    tone(blocked ? 'yellow' : 'gray', blocked ? 'включена' : 'выключена')] });
            if (next) perform(() => command(ctx, ['network', 'quic', next == 1 ? 'on' : 'off']));
        }
    }
}

function menu_session(ctx) {
    let choose = menu_choices();
    while (!ended && !terminal_interrupted()) {
        let info = update_status(ctx);
        let header = service_header(ctx, true);
        if (info.available) unshift(header, tone('yellow', 'доступно zify ' + info.version));
        else if (info.checked) push(header, tone('gray', 'zify актуален'));
        let value = choose('', ['Установка / обновление / удаление', 'Запуск и автозапуск', 'Стратегии', 'Настройки Zapret'],
            { root: true, version: VERSION, header, menu: false, kinds: ['menu', 'menu', 'menu', 'menu'], extra: ['u'], notice });
        if (!value) break;
        if (value == 1) install_menu(ctx);
        if (value == 2) service_menu(ctx);
        if (value == 3) strategy_menu(ctx);
        if (value == 4) config_menu(ctx);
        if (value == 'u') perform(() => {
            let update = check_update(ctx);
            report(update.available ? 'Доступно zify ' + update.version + '\n' : 'Установлена последняя версия zify.\n');
            if (update.available && confirm('Установить обновление zify')) { apply_update(ctx); ended = true; }
        });
    }
}

export function menu(initial, executor) {
    ended = false; assume_yes = initial.assume_yes == true;
    session_cache(initial); menu_executor = executor; menu_ctx = initial;
    try {
        terminal_open();
        {
            let folder = tempdir();
            capture_output(folder + '/output');
            terminal_frame('', [], { version: VERSION, header: ['Проверка обновлений…'], footer: ['Пожалуйста, подождите'] });
            try { check_update(initial); } catch (e) { /* Offline startup keeps the last known version. */ }
            capture_output(null); fs.unlink(folder + '/output'); fs.rmdir(folder);
            terminal_signals();
        }
        menu_session(initial);
    }
    catch (e) { terminal_close(); die(e.message); }
    terminal_close();
    check(!terminal_interrupted(), 'операция прервана');
    print('\nДо встречи. Запуск менеджера: zify\n');
};
