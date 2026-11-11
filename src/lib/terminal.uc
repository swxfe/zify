import * as fs from 'fs';
import * as uloop from 'uloop';
import { check } from 'common';

let tty = { raw: false, screen: false, saved: null, width: 90, height: 30, frame: '', winch: null, resize: false, interrupted: false };
let terminal_handlers = [];
const PALETTE = { white: '97', silver: '38;5;251', steel: '38;5;146', gray: '90', dim: '38;5;244',
    green: '38;5;82', red: '38;5;203', yellow: '38;5;214', lavender: '38;5;183', text: '38;5;254' };
let color = false;

export function tone(name, text, bold) {
    return color ? '\x1b[' + (bold ? '1;' : '') + (PALETTE[name] || name) + 'm' + text + '\x1b[0m' : text;
};

// All UI labels use single-cell Latin/Cyrillic characters; preserve UTF-8 and ANSI sequences.
export function terminal_clip(line, width) {
    if (width < 1) return '';
    let out = '', visible = 0, i = 0, clipped = false;
    while (i < length(line)) {
        if (substr(line, i, 2) == '\x1b[') {
            let end = index(substr(line, i), 'm');
            if (end != -1) { out += substr(line, i, end + 1); i += end + 1; continue; }
        }
        let c = ord(line, i), bytes = c >= 240 ? 4 : (c >= 224 ? 3 : (c >= 192 ? 2 : 1));
        if (c >= 32) {
            if (visible >= width) { clipped = true; break; }
            out += substr(line, i, bytes); visible++;
        }
        i += bytes;
    }
    if (clipped) out = terminal_clip(out, width - 1) + tone('dim', '…');
    return out + (color ? '\x1b[0m' : '');
};

function dimensions(value) {
    let m = match(trim(value || ''), /^([0-9]+) ([0-9]+)$/);
    if (m && +m[1] > 0 && +m[2] > 0) { tty.height = +m[1]; tty.width = +m[2]; }
}

function resize_terminal() {
    tty.resize = false;
    let process = fs.popen('stty size 2>/dev/null', 'r');
    if (process) { dimensions(process.read('all')); process.close(); }
}

function clear_terminal_signals() {
    for (let handler in terminal_handlers) handler.delete();
    terminal_handlers = [];
}

export function terminal_signals() {
    clear_terminal_signals();
    for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP']) signal(name, () => { tty.interrupted = true; die('операция прервана'); });
    if (tty.raw) {
        uloop.init();
        for (let name in ['SIGINT', 'SIGTERM', 'SIGHUP', tty.winch]) {
            let handler = uloop.signal(name, name == tty.winch ? () => {
                tty.resize = true; uloop.end();
            } : () => { tty.interrupted = true; uloop.end(); });
            check(handler != null, 'не удалось подключить сигналы терминала');
            push(terminal_handlers, handler);
        }
    }
};

export function terminal_raw() { return tty.raw; };
export function terminal_interrupted() { return tty.interrupted; };

export function terminal_resume() {
    if (!tty.raw) {
        check(system(['stty', '-echo', '-icanon', 'min', '1', 'time', '0']) == 0, 'не удалось настроить терминал');
        tty.raw = true;
        if (!tty.screen) fs.stdout.write('\x1b[?1049h');
        tty.screen = true;
        fs.stdout.write('\x1b[?25l'); fs.stdout.flush();
    }
    tty.frame = '';
    terminal_signals();
};

// Return canonical input to foreground helpers without leaving the UI screen.
export function terminal_cooked() {
    clear_terminal_signals();
    if (tty.raw) {
        tty.raw = false;
        system(['stty', tty.saved]);
        fs.stdout.write('\x1b[0m\x1b[?25h'); fs.stdout.flush();
    }
};

function terminal_suspend() {
    terminal_cooked();
    if (tty.screen) {
        tty.screen = false;
        fs.stdout.write('\x1b[0m\x1b[?25h\x1b[?1049l'); fs.stdout.flush();
    }
};

export function terminal_close() {
    terminal_suspend();
    tty.saved = null;
};

export function terminal_open() {
    check(fs.stdin.isatty() && fs.stdout.isatty(), 'меню требует TTY: подключитесь по SSH с терминалом');
    check(length(getenv('TERM') || '') && getenv('TERM') != 'dumb', 'меню требует ANSI-терминал: задайте TERM=xterm-256color');
    color = getenv('ZIFY_COLOR') == 'always' || getenv('NO_COLOR') == null;
    tty.interrupted = false;
    // All supported OpenWrt architectures use POSIX stty, provided by BusyBox.
    let process = fs.popen('stty -g 2>/dev/null && stty size 2>/dev/null && (kill -l WINCH 2>/dev/null || /bin/kill -l WINCH)', 'r');
    let result = process ? process.read('all') : '', status = process ? process.close() : 1;
    let lines = split(trim(result || ''), '\n');
    check(status == 0 && length(lines) == 3 && length(lines[0]) && match(lines[2], /^[0-9]+$/),
        'для меню требуется рабочий stty; запустите установщик zify для проверки зависимостей');
    tty.saved = lines[0]; dimensions(lines[1]); tty.winch = +lines[2];
    terminal_resume();
};

function row_menu(options, index) {
    return options.kinds?.[index] != null ? options.kinds[index] == 'menu' : options.menu == true;
}

// ucode sprintf width counts UTF-8 bytes, whereas terminal columns count characters.
export function terminal_pad(text, width) {
    let cells = 0;
    for (let i = 0; i < length(text); i++) if ((ord(text, i) & 0xc0) != 0x80) cells++;
    while (cells++ < width) text += ' ';
    return text;
};

export function terminal_frame(title, labels, options) {
    options = options || {};
    if (tty.resize) resize_terminal();
    let selected = options.selected || 0, lines = ['', '    ' + tone('white', 'zify', true) +
        (title ? tone('dim', ' > ') + tone('white', title) : ' ' + tone('steel', options.version || '')) +
        (options.root ? tone('dim', ' · ') + tone('steel', 'https://github.com/swxfe/zify') : '')];
    for (let line in (options.header || [])) push(lines, '    ' + line);
    push(lines, '');
    let window = min(options.page_size || 10, max(1, tty.height - length(lines) - 6));
    let top = max(0, min(selected - int(window / 2), length(labels) - window));
    if (options.page_size) top = int(selected / window) * window;
    let bottom = min(length(labels), top + window);
    for (let i = top; i < bottom; i++) {
        let row = labels[i], text = type(row) == 'object' ? row.label : row;
        let marker = i == selected ? tone('lavender', '>') + ' ' : '  ';
        let box = type(row) == 'object' && row.checked != null ? tone(row.checked ? 'red' : 'dim', row.checked ? '[x] ' : '[ ] ') : '';
        let child = type(row) == 'object' && row.child ? tone('dim', '└─ ') : '';
        let drill = row_menu(options, i) ? tone('dim', '  ›') : '';
        push(lines, '  ' + marker + child + box + tone(i == selected ? 'white' : 'text', sprintf('%-3s', i + 1) + text, i == selected) + drill);
    }
    for (let line in (options.body || [])) push(lines, '    ' + line);
    if (bottom < length(labels)) push(lines, '    ' + tone('lavender', '↓') + tone('dim', ' ещё ' + (length(labels) - bottom) + ' ниже…'));
    else if (top > 0) push(lines, '    ' + tone('dim', '· конец списка'));
    push(lines, '');
    for (let hint in (options.footer || ['↑↓ / номер — выбор · ' + (row_menu(options, selected) ? 'Enter / → — открыть' : 'Enter — выполнить'), options.back_hint || (options.root ? 'Q — выход' : 'Q / ← — назад')])) push(lines, '    ' + tone('silver', hint));
    push(lines, options.notice ? '    ' + tone(options.warning ? 'yellow' : 'steel', options.notice) : '');
    if (tty.width < 49 || tty.height < 15) lines = ['', '  zify', '  Увеличьте окно до 49 × 15', '  Q — выход'];
    let width = max(1, tty.width - 3), height = max(1, tty.height - 1);
    let frame = join('\n', map(slice(lines, 0, height), (line) => terminal_clip(line, width) + '\x1b[K'));
    frame = '\x1b[H' + frame + '\x1b[J';
    if (frame != tty.frame) { fs.stdout.write(frame); fs.stdout.flush(); tty.frame = frame; }
};

// Wait in OpenWrt's native event loop, then read exactly one byte without stdio
// read-ahead. Older ucode fs.stdin keeps EOF set after a termios timeout.
function read_byte() {
    uloop.init();
    let value = '', handle = uloop.handle(fs.stdin, () => {
        value = fs.readfile('/proc/self/fd/0', 1);
        uloop.end();
    }, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
    check(handle != null, 'не удалось подключить ввод терминала');
    let timer = uloop.timer(100, () => uloop.end());
    try { uloop.run(); }
    catch (e) { handle.delete(); timer.cancel(); die(e.message); }
    handle.delete(); timer.cancel();
    return value;
}

// Resize notifications can interrupt a multi-byte key without ending its sequence.
function sequence_byte() {
    for (let i = 0; i < 3 && !tty.interrupted; i++) {
        let value = read_byte();
        if (value != '') return value;
    }
    return '';
}

function read_key() {
    let c = read_byte();
    if (c == null) return 'EOF';
    if (c == '') return 'TICK';
    if (c == '\x04') return 'EOF';
    if (c == '\n' || c == '\r') return 'ENTER';
    if (c == '\x1b') {
        let sequence = sequence_byte();
        if (sequence != '[' && sequence != 'O') return 'TICK';
        let next = sequence_byte();
        if (next == 'A') return 'UP'; if (next == 'B') return 'DOWN';
        if (next == 'C') return 'RIGHT'; if (next == 'D') return 'BACK';
        if (next == 'H') return 'HOME'; if (next == 'F') return 'END';
        if (next == '5' || next == '6') { sequence_byte(); return 'TICK'; }
        return 'TICK';
    }
    return c;
}

export function terminal_input(label, fallback) {
    check(tty.raw, 'терминал меню не открыт');
    fs.stdout.write('    ' + tone('silver', label) + (fallback != null ? ' [' + fallback + ']' : '') + ': '); fs.stdout.flush();
    let line = '';
    while (true) {
        let key = read_key();
        if (key == null || key == 'EOF') return null;
        if (key == 'TICK') continue;
        if (key == 'ENTER' || key == '\n' || key == '\r') break;
        if (key == '\x7f' || key == '\b') {
            if (length(line)) {
                let i = length(line) - 1;
                while (i > 0 && (ord(line, i) & 0xc0) == 0x80) i--;
                line = substr(line, 0, i);
                fs.stdout.write('\b \b');
            }
        }
        else if (length(key) == 1 && ord(key) >= 32) { line += key; fs.stdout.write(key); }
        check(length(line) <= 4096, 'слишком длинный ввод');
        fs.stdout.flush();
    }
    fs.stdout.write('\n'); fs.stdout.flush();
    line = trim(line);
    return line == '' && fallback != null ? '' + fallback : line;
};

export function terminal_select(title, labels, options) {
    options = options || {};
    if (!length(labels)) return 0;
    let selected = options.selected ?? 0;
    selected = max(0, min(selected, length(labels) - 1));
    let digits = '', ticks = 0;
    while (!tty.interrupted) {
        terminal_frame(title, labels, { ...options, selected });
        let key = read_key();
        if (key == null || key == 'EOF') return null;
        if (tty.width < 49 || tty.height < 15) { if (key == 'q' || key == 'Q' || key == 'EOF') return 0; continue; }
        if (key == 'TICK') {
            if (!length(digits) || ++ticks < 3) continue;
            key = 'ENTER';
        }
        if (match(key, /^[0-9]$/)) {
            if (key == '0' && digits == '') continue;
            digits += key; ticks = 0;
            if (+digits < 1 || +digits > length(labels)) { options.notice = 'Нет пункта ' + digits; digits = ''; continue; }
            selected = +digits - 1;
            if (+digits * 10 <= length(labels)) continue;
            key = 'ENTER';
        }
        if (key == 'BACK' && options.root) continue;
        if (key == 'q' || key == 'Q' || key == 'BACK') return 0;
        if (key == 'UP') selected = (selected + length(labels) - 1) % length(labels);
        if (key == 'DOWN') selected = (selected + 1) % length(labels);
        if (key == 'HOME') selected = 0;
        if (key == 'END') selected = length(labels) - 1;
        if (key == 'n' || key == 'N') selected = min(length(labels) - 1, selected + min(options.page_size || 10, max(1, tty.height - length(options.header || []) - 9)));
        if (key == 'p' || key == 'P') selected = max(0, selected - min(options.page_size || 10, max(1, tty.height - length(options.header || []) - 9)));
        if (options.extra && index(options.extra, lc(key)) != -1) return lc(key);
        if (key == ' ' && options.checkboxes) return { toggle: selected };
        if (key == 'ENTER' || (key == 'RIGHT' && row_menu(options, selected))) {
            return options.checkboxes ? { apply: true } : selected + 1;
        }
        digits = ''; ticks = 0;
    }
    return 0;
};

// A review belongs to the current action: Enter, Q and Left all return once.
export function terminal_view(title, text, message, failed) {
    let lines = split(replace(text || '', /\r/g, ''), '\n'), top = 0;
    while (!tty.interrupted) {
        if (tty.resize) resize_terminal();
        let page = max(1, tty.height - 10);
        top = max(0, min(top, length(lines) - page));
        terminal_frame(title, [], { body: slice(lines, top, top + page), notice: message, warning: failed,
            footer: ['↑↓ — прокрутка', 'Enter / Q / ← — вернуться в меню'] });
        let key = read_key();
        if (key == 'EOF') return false;
        if (key == 'ENTER' || key == 'q' || key == 'Q' || key == 'BACK') return true;
        if (key == 'UP') top--;
        if (key == 'DOWN') top++;
        if (key == 'HOME') top = 0;
        if (key == 'END') top = length(lines);
    }
    return false;
};
