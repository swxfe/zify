"""Drive real ANSI menu frames or a foreground CLI confirmation through a PTY."""
import errno
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import threading
import time

entry = sys.argv[1:]
arguments = entry[2:] if entry[0] in ('sh', '/bin/sh') else entry[1:]
index = 0
while index < len(arguments):
    arg = arguments[index]
    if arg in ('--config', '-c'):
        index += 2
    elif arg.startswith('--config=') or arg in ('--yes', '-y', '--non-interactive'):
        index += 1
    else:
        break
is_menu = index == len(arguments)
master, slave = pty.openpty()
attrs = termios.tcgetattr(slave)
attrs[3] &= ~termios.ECHO
termios.tcsetattr(slave, termios.TCSANOW, attrs)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
data = sys.stdin.buffer.read()

if not is_menu:
    def feed():
        try:
            os.write(master, data + b"\x04")
        except OSError:
            pass
    threading.Thread(target=feed, daemon=True).start()
    try:
        result = subprocess.run(entry, stdin=slave, timeout=20)
        sys.exit(result.returncode)
    finally:
        os.close(slave)
        os.close(master)

ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
tokens = data.decode().splitlines()
child = subprocess.Popen(entry, stdin=slave, stdout=slave, stderr=slave,
                         env={**os.environ, 'TERM': 'xterm-256color'})
output = b''
pending = b''
sent = 0
try:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        readable = select.select([master], [], [], 0.03)[0]
        if readable:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output += chunk
            pending += chunk
            continue
        if child.poll() is not None:
            break
        if not pending:
            continue
        screen = ansi.sub(b'', pending.split(b'\x1b[H')[-1]).decode(errors='replace').replace('\r', '')
        frame = b'\x1b[J' in pending
        confirmation = 'Y — подтвердить' in screen
        review = 'Enter / Q / ← — вернуться в меню' in screen
        prompt = screen.endswith('[y/N] ') or bool(re.search(r'    [^\n]+: $', screen))
        menu = frame and any(hint in screen for hint in ['↑↓ / номер', '↑↓ / номер / Enter', 'Пробел — отметить'])
        if not (menu or confirmation or review or prompt):
            continue
        # Old scripted conversations included a pause after each action. ANSI success
        # notices need no extra Enter; retain Enter only at actual prompts/reviews.
        while sent < len(tokens) and tokens[sent] == '' and not (prompt or confirmation or review or 'Пробел — отметить' in screen):
            sent += 1
        token = tokens[sent] if sent < len(tokens) else None
        sent += 1
        if token is None:
            key = b'\x04'
        elif prompt:
            key = token.encode() + b'\n'
        elif confirmation:
            key = b'y' if token.lower() == 'y' else b'q'
        elif review:
            key = b'\r'
        elif 'Пробел — отметить' in screen and token.isdigit() and int(token) > 0:
            key = b'\x1b[H' + b'\x1b[B' * (int(token) - 1) + b' '
        else:
            key = token.encode() if token else b'\r'
        os.write(master, key)
        if token and not prompt and not confirmation and not review and not token.isdigit() and token.lower() not in ('q', 'd', 'f', 'u', 'n', 'p'):
            continue
        pending = b''
    else:
        raise TimeoutError('ANSI conversation did not finish: ' + ansi.sub(b'', output[-4000:]).decode(errors='replace'))
    child.wait(timeout=5)
finally:
    if child.poll() is None:
        child.kill()
        child.wait(timeout=5)
    os.close(slave)
    os.close(master)
if os.environ.get('ZIFY_COLOR') == 'always':
    sys.stdout.buffer.write(output)
else:
    sys.stdout.buffer.write(ansi.sub(b'', output.replace(b'\x1b[H', b'\n')).replace(b'\r', b''))
sys.exit(child.returncode)
