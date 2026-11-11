import { report } from 'console';
import { menu } from 'menu';
import { current_fakes, prepare_fake_replacement } from 'fakes';
import { check_update, cache_update, install_manager, apply_update } from 'manager';
import { resource, VERSION } from 'resources';
import * as fs from 'fs';
import { check, read, backend, run, output, send, transact, approve } from 'common';
import { settings } from 'settings';
import { invalidate } from 'cache';
import { catalog, compose, compose_bodies, preserve_body, label_strategy, replace_group, remove_flowseal, strategy_key, strategy_group, strategy_sections } from 'strategies';
import { source_data } from 'sources';
import { release_install } from 'releases';
import { install_assets } from 'assets';
import { excluded, exclusion_hook, ipv4, device_list, legacy_exclusions } from 'devices';
import { configured_strategy, inspect_strategy, reference_catalog, service_running } from 'status';
import { strategy_hash, read_applied, create_applied } from 'applied';

const HELP = 'zify — управление Zapret в OpenWrt\n' +
    '\n' +
    'Использование: zify [параметры] [команда [аргументы]]\n' +
    'Без команды открывается меню.\n' +
    '\n' +
    'Параметры (в любом месте до --):\n' +
    '  -h, --help           Справка\n' +
    '  -V, --version        Версия\n' +
    '  -c, --config ФАЙЛ    Настройки zify (по умолчанию /etc/config/zify)\n' +
    '  -y, --yes           Подтвердить изменения без запроса ввода\n' +
    '  --non-interactive   То же, что --yes\n' +
    '  --                  Конец параметров\n' +
    '\n' +
    'Команды:\n' +
    '  status\n' +
    '  service start|stop|restart|enable|disable\n' +
    '  config get ОПЦИЯ | config set DISABLE_IPV6 0|1\n' +
    '  source list|show|apply|select|compose|group|remove ИСТОЧНИК ...\n' +
    '  strategy list|show|apply|import|validate|clear ...\n' +
    '  fake list|replace ...\n' +
    '  devices list|add|remove|toggle|clear [IP]\n' +
    '  network status|offload none|software|hardware|donttouch|restore|quic on|off\n' +
    '  install-upstream | update-upstream\n' +
    '  manager-install [АРХИВ] | manager-check | manager-update | manager-uninstall\n' +
    '  assets-install АРХИВ | uninstall manager|all|components [zapret luci manager files config]\n' +
    '  help | version\n' +
    '\n' +
    'Примеры: zify status; zify service restart; zify source list flowseal\n';

function arity(args, min, max) {
    check(length(args) >= min && length(args) <= max, 'неверное число аргументов; см. help');
}

function editable(key, value) {
    check(key == 'DISABLE_IPV6', 'изменение этой опции не поддерживается: ' + key);
    check(value == '0' || value == '1', 'ожидается 0 или 1');
}

function validate_ports(ports) {
    for (let range in split(ports, ',')) {
        check(match(range, /^[0-9]{1,5}(-[0-9]{1,5})?$/), 'неверный диапазон портов');
        let pair = split(range, '-');
        check(+pair[0] >= 1 && +pair[0] <= 65535 &&
              (length(pair) == 1 || (+pair[1] >= +pair[0] && +pair[1] <= 65535)), 'порт вне диапазона');
    }
}

function dependencies(ctx, body) {
    // The upstream init script expands arguments; paths must exist before config is changed.
    let path_pattern = /^--[^=]+=(\/[^,]+)$/;
    for (let line in split(body, '\n')) {
        let m = match(line, path_pattern);
        if (m) check(fs.stat(ctx.root + m[1])?.type == 'file', 'не найден файл стратегии: ' + m[1]);
    }
}

function persist_applied(ctx, body) {
    let raw = strategy_sections(body);
    let wanted = length(filter(raw, (s) => s.label == null)) ? null : map(raw, (s) => strategy_key(s.label));
    let list = reference_catalog(ctx, wanted);
    let state = create_applied(body, inspect_strategy(body, list), list, time());
    send(ctx, 'state-write', ['state.json'], sprintf('%J\n', state));
}

function approve_strategy_change(ctx, clearing) {
    let state = read_applied(ctx);
    if (state == null || strategy_hash(configured_strategy(ctx)) == state.applied_hash) return true;
    return approve(ctx, clearing ? 'Ваши ручные изменения будут удалены. Продолжить' :
        'Ваши ручные изменения будут заменены версией из каталога. Продолжить');
}

function apply(ctx, body) {
    if (!length(trim(body))) {
        run(ctx, 'config-set', ['NFQWS_OPT', '', 'NFQWS_ENABLE', '0']);
        run(ctx, 'service', ['stop']);
        persist_applied(ctx, '');
        return;
    }
    body = preserve_body(body);
    dependencies(ctx, body);
    let updates = [];
    for (let proto in ['TCP', 'UDP']) {
        let option = 'NFQWS_PORTS_' + proto;
        let ports = trim(output(ctx, 'config-get-optional', [option]));
        let previous = ports, seen_ports = {};
        let items = [];
        for (let port in (length(ports) ? split(ports, ',') : []))
            if (!exists(seen_ports, port)) { seen_ports[port] = true; push(items, port); }
        let filter_pattern = regexp('^--filter-' + lc(proto) + '=([0-9,-]+)$');
        for (let line in split(body, '\n')) {
            let m = match(line, filter_pattern);
            if (m) for (let port in split(m[1], ',')) if (!exists(seen_ports, port)) { seen_ports[port] = true; push(items, port); }
        }
        if (length(items)) {
            ports = join(',', items);
            validate_ports(ports);
            if (ports != previous) push(updates, option, ports);
        }
    }
    if (!length(updates) && trim(configured_strategy(ctx)) == trim(body) &&
        replace(output(ctx, 'config-get-optional', ['NFQWS_ENABLE']), /\n$/, '') == '1' && service_running(ctx) == true) {
        persist_applied(ctx, body);
        return;
    }
    run(ctx, 'config-set', [...updates, 'NFQWS_OPT', body, 'NFQWS_ENABLE', '1']);
    run(ctx, 'service', ['restart']);
    persist_applied(ctx, body);
}

function initialize_lists(ctx) {
    for (let kind in ['user', 'exclude', 'google']) {
        let name = kind == 'user' ? 'zapret-hosts-user.txt' :
            (kind == 'exclude' ? 'zapret-hosts-user-exclude.txt' : 'zapret-hosts-google.txt');
        if (fs.stat(ctx.base + '/ipset/' + name)) continue;
        let body = resource(ctx.resources, kind + '.txt');
        send(ctx, 'hosts-write', [kind], body);
    }
}

function dispatch(ctx, command, args) {
    let changes_strategy = (command == 'strategy' && index(['apply', 'import', 'clear'], args[0]) != -1) ||
        (command == 'source' && index(['apply', 'select', 'compose', 'group', 'remove'], args[0]) != -1);
    // Run after acquiring the transaction lock, before downloads or configuration writes.
    if (changes_strategy && !approve_strategy_change(ctx, command == 'strategy' && args[0] == 'clear')) { report('\nДействие отменено.\n'); return; }
    switch (command) {
    case 'uninstall':
        arity(args, 1, 1);
        check(args[0] == 'manager', 'полное удаление выполняется через пакетную фазу');
        run(ctx, 'uninstall-cleanup', args);
        break;
    case 'assets-install':
        arity(args, 1, 1);
        install_assets(ctx, args[0]);
        break;
    case 'manager-install':
        arity(args, 0, 1); install_manager(ctx, args[0]); break;
    case 'manager-uninstall':
        arity(args, 0, 0); run(ctx, 'manager-uninstall'); break;
    case 'manager-update':
        arity(args, 0, 0);
        apply_update(ctx);
        break;
    case 'manager-check':
        arity(args, 0, 0);
        check_update(ctx);
        break;
    case 'network':
        arity(args, 1, 2);
        run(ctx, 'network', args);
        break;
    case 'devices': {
        arity(args, 1, 2);
        let current = excluded(ctx);
        if (args[0] == 'list') {
            for (let item in device_list(ctx)) report(sprintf('%s %s %s\n', index(current, item.ip) == -1 ? 'Zapret' : 'Исключён', item.ip, item.name));
            break;
        }
        if (args[0] == 'clear') { arity(args, 1, 1); current = []; }
        else {
            check(index(['toggle', 'add', 'remove'], args[0]) != -1, 'неверная команда исключений'); arity(args, 2, 2);
            let ip = ipv4(args[1]);
            let present = index(current, ip) != -1;
            if (args[0] == 'add' && present || args[0] == 'remove' && !present) break;
            if (args[0] == 'add' || args[0] == 'toggle' && !present) push(current, ip);
            else current = filter(current, (item) => item != ip);
        }
        check(fs.stat(ctx.config), 'Zapret не установлен');
        send(ctx, 'device-hook-write', legacy_exclusions(ctx) != null ? ['migrate'] : [], exclusion_hook(ctx, current));
        send(ctx, 'state-write', ['devices.txt'], length(current) ? join('\n', sort(current)) + '\n' : '');
        run(ctx, 'config-set', ['DISABLE_CUSTOM', '0']);
        run(ctx, 'service', ['restart']);
        break;
    }
    case 'fake':
        arity(args, 1, 5);
        if (args[0] == 'list') {
            arity(args, 1, 1);
            report(sprintf('%J\n', current_fakes(ctx)));
        }
        else {
            check(args[0] == 'replace', 'неверная команда фейков');
            arity(args, 5, 5);
            let body = prepare_fake_replacement(ctx, args[1], args[2], args[3], args[4]);
            if (trim(body) != trim(configured_strategy(ctx))) apply(ctx, body);
        }
        break;
    case 'source': {
        arity(args, 2, 10);
        let action = args[0], kind = args[1];
        check(kind == 'flowseal' || kind == 'manager', 'неизвестный источник');
        check(index(['list', 'show', 'apply', 'select', 'compose', 'group', 'remove'], action) != -1, 'неизвестное действие источника');
        if (action == 'remove') {
            arity(args, kind == 'manager' ? 3 : 2, 3);
            let current = output(ctx, 'config-get-optional', ['NFQWS_OPT']);
            apply(ctx, length(args) == 3 ? replace_group(current, '', args[2]) : remove_flowseal(current));
            break;
        }
        let wanted = index(['show', 'apply', 'select', 'compose', 'group'], action) != -1 ?
            map(slice(args, action == 'group' ? 3 : 2), strategy_key) : null;
        let data = source_data(ctx, kind, wanted), list = data.strategies;
        if (action == 'list') { for (let s in list) report(sprintf('%s\n', s.name)); break; }
        if (action == 'show' || action == 'apply' || action == 'select' || action == 'compose' || action == 'group') {
            arity(args, action == 'group' ? 4 : 3, action == 'compose' ? 10 : (action == 'group' ? 4 : 3));
            let selected = [], seen = {};
            for (let name in slice(args, action == 'group' ? 3 : 2)) {
                check(!seen[name], 'повтор стратегии: ' + name);
                seen[name] = true;
                let found = filter(list, (s) => strategy_key(s.name) == strategy_key(name));
                check(length(found) == 1, 'стратегия не найдена: ' + name);
                push(selected, label_strategy(name, found[0].body));
            }
            let body = action == 'compose' ? compose_bodies(selected) : join('--new\n', selected);
            if (action == 'select') {
                let current = output(ctx, 'config-get-optional', ['NFQWS_OPT']);
                let sections = strategy_sections(current), group = strategy_group(args[2]);
                let games = filter(sections, (section) => strategy_group(section.label) == 'games');
                let has_flowseal = length(filter(sections, (section) => match(strategy_key(section.label) || '', /^general(_|$)/))) > 0;
                if (kind == 'flowseal') {
                    if (length(games)) body = compose_bodies([body, ...map(games, (section) => label_strategy(section.label, section.body))]);
                }
                else {
                    check(group != null, 'стратегия не относится к группе');
                    if (group != 'games' && has_flowseal)
                        body = compose_bodies([body, ...map(games, (section) => label_strategy(section.label, section.body))]);
                    else body = replace_group(current, body, group);
                }
            }
            if (action == 'group') {
                check(strategy_group(slice(args, 3)[0]) == args[2], 'стратегия не относится к выбранной группе');
                body = replace_group(output(ctx, 'config-get-optional', ['NFQWS_OPT']), body, args[2]);
            }
            if (action == 'show') report(body);
            else {
                check(ctx.profile == 'zapret' && fs.stat(ctx.config), 'сначала установите Zapret');
                initialize_lists(ctx);
                apply(ctx, body);
            }
            break;
        }
        die('неизвестное действие источника');
    }
    case 'status':
        arity(args, 0, 0);
        run(ctx, command);
        break;
    case 'service':
        arity(args, 1, 1);
        check(index(['start', 'stop', 'restart', 'enable', 'disable'], args[0]) != -1, 'неизвестная команда сервиса');
        run(ctx, 'service', args);
        break;
    case 'config':
        arity(args, 1, 3);
        if (args[0] == 'get') {
            arity(args, 2, 2);
            check(match(args[1], /^[A-Za-z][A-Za-z0-9_]*$/), 'неверное имя опции');
            report(output(ctx, 'config-get', [args[1]]));
        }
        else {
            check(args[0] == 'set', 'config: get/set DISABLE_IPV6'); arity(args, 3, 3);
            editable(args[1], args[2]);
            let current = replace(output(ctx, 'config-get-optional', [args[1]]), /\n$/, '');
            if (current == args[2]) break;
            run(ctx, 'config-set', slice(args, 1));
            run(ctx, 'service', ['restart']);
        }
        break;
    case 'strategy':
        check(length(args) > 0, 'strategy: list/show/apply/import/validate/clear');
        if (args[0] == 'clear') {
            arity(args, 1, 1);
            check(fs.stat(ctx.config), 'Zapret не установлен');
            if (length(trim(configured_strategy(ctx))) ||
                trim(output(ctx, 'config-get-optional', ['NFQWS_ENABLE'])) != '0' || service_running(ctx) != false)
                apply(ctx, '');
            else if (read_applied(ctx)?.applied_hash != strategy_hash('')) persist_applied(ctx, '');
        }
        else if (args[0] == 'list') {
            arity(args, 1, 2);
            for (let s in catalog(ctx, args[1])) report(sprintf('%s\n', s.name));
        }
        else if (args[0] == 'validate' || args[0] == 'import') {
            arity(args, 2, 2);
            let body = preserve_body(read(args[1], ctx.max_file_bytes));
            if (args[0] == 'validate') report(body); else apply(ctx, body);
        }
        else {
            check(args[0] == 'show' || args[0] == 'apply', 'неизвестная операция стратегии');
            arity(args, 2, args[0] == 'show' ? 2 : ctx.max_strategies);
            let body = compose(ctx, slice(args, 1));
            if (args[0] == 'show') report(body); else apply(ctx, body);
        }
        break;
    default: die('неизвестная команда: ' + command);
    }
}

function package_phase(ctx, args) {
    check(!getenv('ZIFY_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
    arity(args, 0, 0);
    let plan = release_install({ ...ctx, cache: null });
    if (plan != 'none') invalidate(ctx);
    if (plan != 'both') return 0;
    return transact(ctx, 'configure', []) == 0 ? 0 : 1;
}

// Global options may occur before or after a command. -- preserves literal operands.
export function cli_arguments(argv) {
    let args = [], file = null, yes = false, literal = false, special = null;
    for (let i = 0; i < length(argv); i++) {
        let value = argv[i];
        if (literal) { push(args, value); continue; }
        if (value == '--') { literal = true; continue; }
        if (value == '-h' || value == '--help') { special = 'help'; continue; }
        if (value == '-V' || value == '--version') { special = 'version'; continue; }
        if (value == '-y' || value == '--yes' || value == '--non-interactive') { yes = true; continue; }
        if (substr(value, 0, 9) == '--config=') {
            file = substr(value, 9); check(length(file), 'не задано значение --config'); continue;
        }
        if (value == '-c' || value == '--config') {
            check(i + 1 < length(argv) && length(argv[i + 1]) && substr(argv[i + 1], 0, 1) != '-', 'не задано значение ' + value);
            file = argv[++i]; continue;
        }
        check(substr(value, 0, 1) != '-' || value == '-', 'неизвестный параметр: ' + value + '; см. zify --help');
        push(args, value);
    }
    return { command: special || shift(args), args: special ? [] : args, file, yes };
};

export function destination_context(ctx) {
    let destination = getenv('DESTDIR');
    if (!destination) return ctx;
    check(match(destination, /^\/[A-Za-z0-9_./ -]+$/) && !match(destination, /(^|\/)\.\.?(\/|$)/), 'неверный DESTDIR');
    ctx.root = destination == '/' ? '' : replace(destination, /\/$/, '');
    ctx.state = ctx.root + '/etc/zify'; ctx.base = ctx.root + '/opt/zapret';
    ctx.config = ctx.root + '/etc/config/zapret'; ctx.assets = ctx.state + '/assets';
    ctx.file = ctx.root + '/etc/config/zify';
    return ctx;
};

export function command_main(argv, session) {
try {
    // ucode defers handlers until a synchronous helper has finished. The supervisor
    // waits for that worker before restoring files, so helpers cannot race the rollback.
    for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP'])
        signal(name, () => die('операция прервана'));
    let cli = cli_arguments(argv), args = cli.args, file = cli.file;
    let command = cli.command || 'help';
    if (command == 'help' || command == 'version') {
        arity(args, 0, 0);
        report(command == 'help' ? HELP : VERSION + '\n');
        return 0;
    }
    check(index(['status', 'service', 'config', 'source', 'strategy', 'fake',
        'devices', 'network', 'install-upstream', 'update-upstream',
        'manager-install', 'manager-uninstall', 'manager-check', 'manager-update', 'assets-install', 'uninstall'], command) != -1,
        'неизвестная команда: ' + command + '; см. zify --help');
    let ctx = session && (file == null || file == session.file) ? session : settings(getenv('ZIFY_HOME'), file || getenv('ZIFY_CONFIG'));
    ctx.assume_yes = cli.yes || (session?.assume_yes == true);
    if (index(['manager-install', 'manager-uninstall', 'uninstall'], command) != -1) ctx = destination_context(ctx);
    // Pure input errors need neither a snapshot nor a worker; validate again under the lock.
    if (command == 'config' && args[0] == 'set') {
        arity(args, 3, 3);
        editable(args[1], args[2]);
    }
    let readonly = index(['status', 'manager-check'], command) != -1 ||
        (command == 'network' && args[0] == 'status') ||
        (command == 'devices' && args[0] == 'list') ||
        (command == 'fake' && args[0] == 'list') ||
        (command == 'source' && index(['list', 'show'], args[0]) != -1) ||
        (command == 'strategy' && index(['list', 'show', 'validate'], args[0]) != -1) ||
        (command == 'config' && args[0] == 'get');
    if (!readonly && !getenv('ZIFY_TRANSACTION') && session == null)
        check(approve(ctx, 'Выполнить zify ' + command), 'операция отменена');
    if (index(['install-upstream', 'update-upstream'], command) != -1)
        return package_phase(ctx, args);
    if (command == 'uninstall') {
        arity(args, 1, 6);
        check(index(['manager', 'all', 'components'], args[0]) != -1, 'ожидается manager, all или components');
        if (args[0] != 'manager') {
            let selected = args[0] == 'all' ? ['zapret', 'luci', 'manager', 'files', 'config'] : slice(args, 1);
            check(length(selected), 'не выбраны компоненты');
            let seen = {};
            for (let name in selected) {
                check(index(['zapret', 'luci', 'manager', 'files', 'config'], name) != -1 && !seen[name], 'неверный компонент: ' + name);
                seen[name] = true;
            }
            check(!seen.files || seen.zapret, 'удаление файлов требует выбора Zapret');
            check(!seen.config || seen.manager, 'удаление конфигурации требует выбора zify');
            check(!getenv('ZIFY_TRANSACTION'), 'пакетная операция внутри транзакции запрещена');
            check(!fs.stat(ctx.root + '/tmp/zify.zapret.lock'), 'занято: выполняется другая операция');
            let packages = [];
            if (seen.luci) push(packages, 'luci-app-zapret');
            if (seen.zapret) push(packages, 'zapret');
            if (length(packages)) run(ctx, 'package', ['remove', ...packages]);
            check(transact(ctx, 'cleanup', ['components', ...selected]) == 0, 'не удалось очистить конфигурацию');
            return 0;
        }
    }
    if (!readonly && !getenv('ZIFY_TRANSACTION')) {
        // A POSIX supervisor owns the lock, signal handling and rollback for the entire command.
        let rc = backend(ctx, 'transaction', ctx.assume_yes && !cli.yes ? ['--yes', ...argv] : argv);
        return rc == 0 ? 0 : 1;
    }
    dispatch(ctx, command, args);
    return 0;
}
catch (e) {
    report('zify: ' + e.message + '\n', true);
    return 1;
}
};

function configure_installed(ctx) {
    initialize_lists(ctx);
    run(ctx, 'service', ['enable']);
    run(ctx, 'service', ['restart']);
}

export function atom_main(argv) {
    try {
        let args = [...argv];
        arity(args, 3, 1024);
        check(args[2] == 'zapret' && type(args[1]) == 'string' &&
            (args[1] == '' || match(args[1], /^\/([A-Za-z0-9_. -]+\/)*[A-Za-z0-9_. -]*$/)) &&
            !match(args[1], /(^|\/)\.\.?(\/|$)/), 'неверный корень backend');
        let ctx = settings(getenv('ZIFY_HOME'), null);
        ctx.root = args[1]; ctx.state = ctx.root + '/etc/zify'; ctx.base = ctx.root + '/opt/zapret';
        ctx.config = ctx.root + '/etc/config/zapret'; ctx.assets = ctx.state + '/assets'; ctx.file = ctx.root + '/etc/config/zify';
        let action = args[0], values = slice(args, 3);
        let readonly = index(['status', 'config-read', 'config-read-optional'], action) != -1 ||
            (action == 'network' && values[0] == 'status');
        if (!readonly && !getenv('ZIFY_TRANSACTION')) return transact(ctx, 'atom', args) == 0 ? 0 : 1;
        if (index(['state-write', 'hosts-write', 'device-hook-write', 'manager-config-init'], action) != -1) {
            check(length(values), 'не указан файл операции');
            send(ctx, action, slice(values, 1), read(values[0], ctx.max_file_bytes));
        }
        else if (action == 'config-read' || action == 'config-read-optional')
            report(output(ctx, action == 'config-read' ? 'config-get' : 'config-get-optional', values));
        else {
            check(index(['config-set', 'service', 'network', 'asset-file', 'manager-install', 'manager-uninstall',
                'uninstall-cleanup', 'status'], action) != -1, 'неизвестная нативная операция: ' + action);
            run(ctx, action, values);
        }
        return 0;
    }
    catch (e) { report('zify: ' + e.message + '\n', true); return 1; }
};

export function cli_main(argv) {
    try {
        let cli = cli_arguments(argv);
        if (cli.command != null) return command_main(argv);
        check(fs.stdin.isatty(), 'меню требует TTY; укажите команду, см. zify --help');
        let ctx = settings(getenv('ZIFY_HOME'), cli.file || getenv('ZIFY_CONFIG'));
        ctx.assume_yes = cli.yes;
        menu(ctx, command_main);
        return 0;
    }
    catch (e) { report('zify: ' + e.message + '\n', true); return 1; }
};


export function worker_main(argv) {
    try {
        let args = [...argv], kind = shift(args);
        if (kind == 'transaction') return command_main(args);
        check(kind == 'call' && getenv('ZIFY_TRANSACTION'), 'нет активного супервизора');
        let operation = shift(args), file = shift(args);
        let ctx = settings(getenv('ZIFY_HOME'), file || null);
        if (index(['install', 'cleanup'], operation) != -1) ctx = destination_context(ctx);
        switch (operation) {
        case 'configure': configure_installed(ctx); break;
        case 'cleanup': run(ctx, 'uninstall-cleanup', args); break;
        case 'install': install_manager(ctx, args[0]); break;
        case 'cache': cache_update(ctx, json(args[0])); break;
        case 'self-update': apply_update(ctx); break;
        case 'atom': return atom_main(args);
        default: die('неизвестная внутренняя функция');
        }
        return 0;
    }
    catch (e) { report('zify: ' + e.message + '\n', true); return 1; }
};
