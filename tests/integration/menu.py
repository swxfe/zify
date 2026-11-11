"""Exercise the actual ANSI UI in a PTY, including terminal restoration."""
from pathlib import Path
import atexit
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import tempfile
import time

config = Path(sys.argv[1])
root = Path(os.environ['ZIFY_TEST_ROOT'])
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')

sys.path.insert(0, str(Path('tests/support').resolve()))
from pty_ui import Terminal as PtyTerminal

def Terminal(entry, env=None):
    return PtyTerminal(entry, config, env)

for entry in ['src/launcher.sh', 'dist/zify.sh']:
    saved = {p: p.read_bytes() for p in [root/'etc/config/zapret', config]}
    t = Terminal(entry)
    text = t.expect('Q — выход')
    assert '\x1b' not in text
    assert 'Blockcheck' not in text
    assert not termios.tcgetattr(t.slave)[3] & termios.ICANON, (text, t.collect())
    assert '> 1  Установка / обновление / удаление' in text, text
    # Retired keys cannot exit, go back or move the selection.
    t.send(b'0\x1b[5~\x1b[6~\x1b[B')
    text = t.expect('> 2  Запуск и автозапуск')
    assert t.proc.poll() is None and 'До встречи' not in text, text
    t.send(b'\x1b[A')
    t.expect('> 1  Установка / обновление / удаление')
    # Left at root must be harmless, even when repeated.
    t.send(b'\x1b[D' * 4)
    assert t.proc.poll() is None and 'До встречи' not in t.collect()
    # Right opens a submenu, left returns; selection wraps upwards.
    t.send(b'\x1b[C')
    text = t.expect('Выборочное удаление')
    assert '0 / Q' not in text, text
    t.send(b'0\x1b[5~\x1b[6~\x1b[B')
    text = t.expect('> 2  Обновить Zapret')
    assert 'Q / ← — назад' in text, text
    t.send(b'\x1b[D')
    t.expect('Q — выход')
    t.send(b'\x1b[A')
    text = t.expect('Q — выход')
    assert '> 4  Настройки Zapret' in text, text
    t.send(b'3')
    text = t.expect('Очистить стратегию')
    assert 'загрузить свой файл' not in text and 'F —' not in text, text
    t.send(b'fF\x1b[B')
    text = t.expect('> 2  Собрать:')
    assert 'Файл стратегии' not in text, text
    t.send(b'2')
    text = t.expect('Базовый трафик')
    rows = [line for line in text.splitlines() if any(name in line for name in ['Базовый трафик', 'YouTube', 'Discord']) and 'отключено' in line]
    assert len(rows) == 3 and len({line.index('отключено') for line in rows}) == 1, rows
    # Parent cursors survive a return through several levels, then reset on reentry.
    t.send(b'2')
    t.expect('стратегии > сборка > YouTube')
    t.send(b'\x1b[D')
    text = t.expect('Базовый трафик')
    assert '> 2  YouTube' in text, text
    t.send(b'q')
    text = t.expect('Очистить стратегию')
    assert '> 2  Собрать:' in text, text
    t.send(b'q')
    text = t.expect('Q — выход')
    assert '> 3  Стратегии' in text, text
    t.send(b'\x1b[C')
    text = t.expect('Очистить стратегию')
    assert '> 1  Стратегии Flowseal' in text, text
    t.send(b'2')
    text = t.expect('Базовый трафик')
    assert '> 1  Базовый трафик' in text, text
    t.send(b'qq')
    t.expect('Q — выход')
    # A checkbox adds its dependent child row; cancellation never changes files.
    t.send(b'14')
    t.expect('Отметьте компоненты')
    t.send(b' ')
    text = t.expect('[x]')
    assert 'Файлы: стратегии и фейки' in text, text
    t.send(b'\r')
    t.expect('Y — подтвердить')
    t.send(b'q')
    t.expect('Удаление отменено')
    t.send(b'qq')
    t.expect('Q — выход')
    for p, before in saved.items():
        assert p.read_bytes() == before, p
    # Resize is event-driven and clips the window, then restores navigation.
    t.resize(10, 35)
    t.expect('Увеличьте окно')
    t.resize(24, 80)
    t.expect('Q — выход')
    # Settings show their own state, with no unrelated strategy or retired submenu.
    t.send(b'4')
    text = t.expect('IPv6: ')
    assert 'Дополнительно' not in text and 'Стратегия:' not in text, text
    assert '> 1  IPv6' in text, text
    t.send(b'\x1b[Bq')
    text = t.expect('Q — выход')
    assert '> 4  Настройки Zapret' in text, text
    t.send(b'4')
    text = t.expect('IPv6: ')
    assert '> 1  IPv6' in text, text
    t.send(b'1')
    text = t.expect('IPv6 в Zapret: ')
    assert 'Стратегия:' not in text, text
    t.send(b'\x1b[D')
    text = t.expect('IPv6: ')
    assert '> 1  IPv6' in text, text
    t.send(b'3')
    text = t.expect('Отключить блокировку QUIC')
    assert 'Блокировка UDP 80/443: выключена' in text and 'Стратегия:' not in text, text
    firewall_before = (root/'firewall-actions').read_bytes() if (root/'firewall-actions').exists() else b''
    t.send(b'\x1b[C')  # Actions run with Enter, not Right.
    t.collect()
    assert ((root/'firewall-actions').read_bytes() if (root/'firewall-actions').exists() else b'') == firewall_before
    t.send(b'\r')
    t.expect('QUIC: заблокирован')
    t.send(b'3')
    text = t.expect('Отключить блокировку QUIC')
    assert 'Блокировка UDP 80/443: включена' in text, text
    t.send(b'2')
    t.expect('QUIC: разрешён')
    t.send(b'2')
    text = t.expect('Исключено устройств: ')
    assert 'Стратегия:' not in text, text
    t.send(b'q')
    t.expect('IPv6: ')
    t.send(b'4')
    text = t.expect('Системное: ')
    assert 'Стратегия:' not in text, text
    assert '> 1  Программное ускорение Zapret' in text, text
    t.send(b'\x1b[Bq')
    text = t.expect('IPv6: ')
    assert '> 4  Flow Offloading' in text, text
    t.send(b'\x1b[C')
    text = t.expect('Системное: ')
    assert '> 1  Программное ускорение Zapret' in text, text
    t.send(b'qq')
    text = t.expect('Q — выход')
    assert '> 4  Настройки Zapret' in text, text
    t.send(b'\x1b[C')
    text = t.expect('IPv6: ')
    assert '> 1  IPv6' in text, text
    t.send(b'q')
    t.expect('Q — выход')
    # Service chatter stays in /tmp; success and rollback keep the alternate screen.
    noisy = root/'noisy-service'
    noisy.write_text('1')
    t.send(b'2')
    t.expect('Выключить автозапуск')
    boundary = len(t.history)
    t.send(b'3')
    t.expect('Готово')
    new = t.history[boundary:]
    assert b'NOISY_SERVICE' not in new and b'\x1b[?1049l' not in new, new
    for back in [b'\x1b[D', b'q', b'\r']:
        (root/'fail-restart').write_text('1')
        boundary = len(t.history)
        t.send(b'3')
        text = t.expect('Enter / Q / ← — вернуться в меню')
        assert 'Ошибка:' in text and 'NOISY_SERVICE' in text, text
        assert 'PgUp' not in text and 'PgDn' not in text, text
        assert b'\x1b[?1049l' not in t.history[boundary:], 'error exposed the old terminal screen'
        t.send(back)
        t.expect('Выключить автозапуск')
        assert 'zify > Ошибка' not in t.collect(), 'action reopened after returning'
    t.send(b'q')
    t.expect('Q — выход')
    noisy.unlink()
    t.send(b'2')
    t.expect('Выключить автозапуск')
    t.send(b'2')
    t.expect('Готово')
    t.send(b'q')
    t.expect('Q — выход')
    t.close()
    # An asynchronous interrupt must also restore echo, canonical mode and cursor.
    t = Terminal(entry)
    t.expect('Q — выход')
    t.close(interrupted=True)

# Startup checks without a key press; offline startup keeps navigation available.
release = root/'manager-release'
update_cache = root/'etc/zify/update.json'
previous = release.read_bytes() if release.exists() else None
cached_update = update_cache.read_bytes() if update_cache.exists() else None
try:
    release.write_text('# ZIFY_FORMAT=2\n# ZIFY_VERSION=1.1\n')
    for entry in ['src/launcher.sh', 'dist/zify.sh']:
        t = Terminal(entry)
        t.expect('доступно zify 1.1')
        t.close()
    (root/'update-offline').write_text('1')
    for entry in ['src/launcher.sh', 'dist/zify.sh']:
        update_cache.unlink(missing_ok=True)
        t = Terminal(entry)
        text = t.expect('Q — выход')
        assert 'Ошибка:' not in text, text
        assert 'не проверена' not in text and 'zify актуален' not in text, text
        assert 'Установка / обновление / удаление' in text, text
        t.close()
finally:
    (root/'update-offline').unlink(missing_ok=True)
    if previous is None:
        release.unlink(missing_ok=True)
    else:
        release.write_bytes(previous)
    if cached_update is None:
        update_cache.unlink(missing_ok=True)
    else:
        update_cache.write_bytes(cached_update)

# Missing terminal support fails clearly instead of selecting a text-menu fallback.
for entry in ['src/launcher.sh', 'dist/zify.sh']:
    with tempfile.TemporaryDirectory(prefix='zify-no-stty-', dir='/tmp') as folder:
        stty = Path(folder)/'stty'
        stty.write_text('#!/bin/sh\nexit 1\n')
        stty.chmod(0o755)
        for env, message in [({'TERM': 'dumb'}, 'ANSI-терминал'),
                             ({'PATH': folder + ':' + os.environ['PATH']}, 'требуется рабочий stty')]:
            t = Terminal(entry, env)
            text = t.expect(message)
            t.proc.wait(timeout=5)
            assert t.proc.returncode == 1 and '↑↓ / номер' not in text, text
            assert termios.tcgetattr(t.slave) == t.original
            os.close(t.master)
            os.close(t.slave)

# Long lists exercise scrolling, retired page keys and ambiguous numeric prefixes.
with tempfile.TemporaryDirectory(prefix='zify-menu-', dir='/tmp') as folder:
    program = Path(folder)/'picker.uc'
    program.write_text("""import { terminal_open, terminal_select, terminal_close } from 'terminal';
        let rows = []; for (let i = 1; i <= 36; i++) push(rows, 'Профиль ' + i);
        try {
            terminal_open();
            for (let i = 0; i < 4; i++) {
                let value = terminal_select('Каталог', rows, { page_size: 12, ...(i >= 2 ? { selected: 19 } : {}) });
                print('RESULT=' + value + '\\n');
            }
            terminal_close();
        } catch (e) { terminal_close(); die(e.message); }
    """)
    t = Terminal(['ucode', '-S', '-L', str(Path('src/lib').resolve()), str(program)])
    t.expect('Профиль 1')
    t.send(b'0\x1b[5~\x1b[6~\x1b[B')
    t.expect('> 2  Профиль 2')
    t.send(b'\x1b[A')
    t.expect('> 1  Профиль 1')
    t.send(b'n')
    text = t.expect('Профиль 13')
    assert 'Профиль 1\r' not in text, text
    t.send(b'p')
    t.expect('Профиль 1')
    t.send(b'20')
    text = t.expect('RESULT=20')
    if '> 1  Профиль 1' not in text:
        text += t.expect('> 1  Профиль 1')
    assert '> 1  Профиль 1' in text, text
    t.resize(15, 49)
    t.send(b'\x1b[H')
    t.expect('Профиль 1')
    t.send(b'n')
    text = t.expect('Профиль 7')
    assert all(len(line) <= 49 for line in text.splitlines()), text
    t.send(b'3')  # Waits only for the 300 ms ambiguity window, with no Enter.
    text = t.expect('RESULT=3')
    if '> 20 Профиль 20' not in text:
        text += t.expect('> 20 Профиль 20')
    assert '> 20 Профиль 20' in text, text
    t.send(b'\x1b[Bq')
    text = t.expect('RESULT=0')
    if '> 20 Профиль 20' not in text:
        text += t.expect('> 20 Профиль 20')
    assert '> 20 Профиль 20' in text, text
    t.send(b'q')
    t.expect('RESULT=0')
    t.close()
print('menu: source + bundle PTY, arrows, numeric prefixes, pages, cancel, resize, context headers, QUIC state, errors and terminal restoration OK')
