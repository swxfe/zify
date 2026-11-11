"""A real terminal for ANSI UI tests; no product fallback is involved."""
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
import termios
import time
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')

class Terminal:
    def __init__(self, entry, config, env=None):
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.resize(30, 90)
        self.data = b''
        self.history = b''
        self.proc = subprocess.Popen(entry if isinstance(entry, list) else ['sh', entry, '-c', str(config)],
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
            env={**os.environ, 'TERM': 'xterm-256color', **(env or {})})
        atexit.register(self.cleanup)

    def cleanup(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=5)

    def resize(self, height, width):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
        if hasattr(self, 'proc'):
            self.proc.send_signal(signal.SIGWINCH)

    def send(self, data):
        os.write(self.master, data)

    def collect(self, duration=0.15):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            if select.select([self.master], [], [], max(0, end-time.monotonic()))[0]:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError as e:
                    if e.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                self.data += chunk
                self.history += chunk
        return ansi.sub(b'', self.data).decode()

    def expect(self, text):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            content = self.collect()
            if text in content:
                self.data = b''
                return content
            if self.proc.poll() is not None:
                break
        raise AssertionError((text, self.proc.poll(), self.data.decode(errors='replace')))

    def close(self, interrupted=False):
        if interrupted:
            self.proc.send_signal(signal.SIGTERM)
        else:
            self.send(b'q')
        self.proc.wait(timeout=5)
        self.collect()
        assert b'\x1b[?25h' in self.history and b'\x1b[?1049l' in self.history, self.history
        assert termios.tcgetattr(self.slave) == self.original, 'terminal settings leaked'
        assert self.proc.returncode == (1 if interrupted else 0), self.data
        os.close(self.master)
        os.close(self.slave)
