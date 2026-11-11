from collections import Counter
from pathlib import Path
import os
import subprocess
import sys
import time
import pty
import threading
sys.path.insert(0, str(Path("tests/support").resolve()))
from pty_ui import Terminal

config, preload = sys.argv[1:]
project = Path.cwd()
root = os.environ['ZIFY_TEST_ROOT']
log = Path(preload).with_name('ui-reads.log')
cycle = ('321qq1qq'  # composer, base picker, Flowseal picker
         '1q'             # installation submenu
         '41qq'          # IPv6 status and cancellation
         '43qq'           # QUIC status and cancellation
         '42qq'           # devices
         '44qq'           # flow offloading
         '2q')            # service
rounds = 50
env = {**os.environ, 'ZIFY_CONFIG': config, 'LD_PRELOAD': preload,
       'ZIFY_READ_LOG': str(log)}
release = Path(root) / 'etc/openwrt_release'
release.write_text("DISTRIB_ARCH='test_arch'\n")
readonly_env = {**env, 'ZIFY_FORBID_WRITES': '1', 'ZIFY_FORBID_FORK': '1'}
readonly = subprocess.run(['ucode', '-S', '-L', str(project / 'src/lib'), 'tests/performance/read-only.uc', config],
                          env=readonly_env, capture_output=True, timeout=5)
assert readonly.returncode == 0, readonly.stderr.decode(errors='replace')
log.unlink(missing_ok=True)
guard = Path(preload).with_name('navigation-guard')
guard.unlink(missing_ok=True)
env['ZIFY_FORBID_AFTER'] = str(guard)
t = Terminal(['ucode', '-S', '-L', str(project/'src/lib'), str(project/'src/main.uc')], config, env)
t.expect('Q — выход')
# Only ANSI keys are sent: numeric shortcuts select immediately, Q returns.
keys = cycle.encode()
guard.touch()
start = time.monotonic()
t.send(keys * rounds + b'1')
deadline = time.monotonic() + 15
try:
    while t.history.count('Управление компонентами'.encode()) < rounds + 1:
        t.collect(0.02)
        assert t.proc.poll() is None, t.history[-4000:]
        assert time.monotonic() < deadline, 'navigation stalled'
    elapsed = time.monotonic() - start
    assert 'Ошибка:'.encode() not in t.history, t.history[-4000:]
    plain = __import__('re').sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', t.history).decode()
    assert plain.count('zify > стратегии > сборка') == rounds * 3, (plain.count('zify > стратегии > сборка'), plain[-4000:])
finally:
    guard.unlink(missing_ok=True)
t.send(b'q')
t.expect('Q — выход')
t.close()
reads = Counter(log.read_text().splitlines())
# Navigation only reads the committed configuration through libuci.
assert reads[root + '/etc/config/zapret'] <= 1, reads
for path, count in reads.items():
    if path != root + '/etc/config/zapret':
        assert count <= 1, (path, count, reads)
assert reads[root + '/etc/zify/assets/catalogs/flowseal.json'] == 1, reads
print(f'performance: {rounds} navigation cycles, zero fork/popen, managed inputs read once; '
      f'{elapsed * 1000 / rounds:.2f} ms/cycle on this host')
