import * as fs from 'fs';
import { VERSION } from 'resources';

let root = getenv('ZIFY_HOME');
function content(path) {
    let value = fs.readfile(root + '/' + path);
    if (value == null) die('bundle: не найден ' + path);
    return replace(value, /\r\n/g, '\n');
}
function module_body(path) {
    let body = content(path);
    body = join('\n', map(filter(split(body, '\n'), (line) => !match(line, /^import /)),
        (line) => replace(line, /^export /, '')));
    return '\n// ---- ' + path + ' ----\n' + body;
}
function shell_body(name) {
    let body = content('src/shell/' + name + '.sh');
    body = join('\n', filter(split(body, '\n'), (line) => !match(line, /^(#!|# shellcheck source=|\. "\$\(dirname)/)));
    return body;
}
function heredoc(name, body) {
    let marker = '__ZIFY_' + name + '__';
    if (index('\n' + body, '\n' + marker + '\n') != -1) die('bundle: конфликт разделителя');
    return name + "=$(cat <<'" + marker + "'\n" + trim(body) + '\n' + marker + '\n)\nexport ' + name + '\n\n';
}

let header = replace(content('tools/header.sh'), /@VERSION@/g, VERSION);
let footer = content('tools/footer.sh');
let backend = shell_body('common') + '\n';
for (let name in ['transaction', 'packages'])
    backend += '\nzify_' + name + '() {\n' + shell_body(name) + '\n}\n';
let dispatch = shell_body('backend');
for (let name in ['transaction', 'packages'])
    dispatch = replace(dispatch,
        'exec /bin/sh "$(dirname "$0")/' + name + '.sh" "$action" "$root" "$profile" "$@"',
        'zify_' + name + ' "$@"');
backend += '\n# ---- system operation dispatcher ----\n' + dispatch;

let program = "import * as fs from 'fs';\nimport * as uci from 'uci';\nimport * as ubus from 'ubus';\nimport { sha256 } from 'digest';\nimport * as uclient from 'uclient';\nimport * as uloop from 'uloop';\n";
program += 'const EMBEDDED_HEADER = ' + sprintf('%J', header) + ';\n';
program += 'const EMBEDDED_FOOTER = ' + sprintf('%J', footer) + ';\n';
for (let file in ['console', 'resources', 'cache', 'platform', 'http', 'mutations', 'common', 'settings', 'strategies', 'lists', 'devices', 'applied', 'status', 'sources', 'assets', 'fakes', 'releases', 'manager', 'terminal', 'menu']) {
    let body = module_body('src/lib/' + file + '.uc');
    if (file == 'resources') {
        for (let kind in ['header', 'footer'])
            body = replace(body, 'function embedded_' + kind + '() { return null; }',
                'function embedded_' + kind + '() { return EMBEDDED_' + uc(kind) + '; }');
    }
    program += body;
}
program += module_body('src/lib/commands.uc');

// Split only between lines so UTF-8 and the concatenated source remain intact.
let parts = [], part = '';
for (let line in split(program, '\n')) {
    if (length(part) + length(line) > 24000 && length(part)) { push(parts, part); part = ''; }
    part += line + '\n';
}
if (length(part)) push(parts, part);
let result = header + heredoc('ZIFY_BACKEND', backend);
for (let i = 0; i < length(parts); i++) result += heredoc('ZIFY_UCODE_' + (i + 1), parts[i]);
result += 'ZIFY_PARTS=' + length(parts) + '\nexport ZIFY_PARTS\n' + footer;
let target = root + '/dist/zify.sh';
fs.mkdir(root + '/dist');
if (fs.writefile(target, result) != length(result)) die('bundle: ошибка записи');
fs.chmod(target, 0755);
printf('%s (%d bytes, readable source)\n', target, length(result));
