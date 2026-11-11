"""CLI contracts on source and standalone artifacts, with no writes to host paths."""
import os
from pathlib import Path
import subprocess
import sys

config = Path(sys.argv[1])
root = Path(os.environ['ZIFY_TEST_ROOT'])
project = Path(os.environ['ZIFY_HOME'])
passed = 0


def run(entry, args, code=0):
    global passed
    result = subprocess.run(['sh', str(entry), *args], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=5)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    passed += 1
    return result


def refuse_open_pipe(entry, args):
    global passed
    child = subprocess.Popen(['sh', str(entry), *args], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        child.stdin.write(b'y\n')
        child.stdin.flush()
        # Keep stdin open: an accidental prompt would block even though a writer exists.
        child.wait(timeout=3)
        out, err = child.communicate(timeout=2)
        assert child.returncode == 1 and not out and err, (args, child.returncode, out, err)
        passed += 1
        return err
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()


initial_running = (root / 'state').exists()
for entry in (project / 'src/launcher.sh', project / 'dist/zify.sh'):
    for flag in ['-h', '--help', 'help']:
        out = run(entry, ['-c', str(config.with_name('missing')), flag])
        assert 'zify [параметры]'.encode() in out.stdout and not out.stderr
        assert not any(word in out.stdout for word in [b'--internal', b'backend-operation', b'package-configure', b'uninstall-finish'])
    version = run(entry, ['version']).stdout
    assert run(entry, ['-V']).stdout == run(entry, ['--version']).stdout == version
    status = run(entry, ['-c', str(config), 'status']).stdout
    for args in [['status', '-c', str(config)], ['status', '--config=' + str(config)],
                 ['-c', str(config), '--', 'status'], ['status', '--yes', '--config', str(config)]]:
        assert run(entry, args).stdout == status
    for args in [['-c'], ['--config='], ['--unknown'], ['--internal'], ['help', 'extra']]:
        run(entry, args, 1)
    for command in ['blockcheck', 'hosts', 'backup', 'test', 'benchmark', 'auto-best', 'targets', 'schedule', 'doctor', 'recover', 'install', 'update', 'remove', 'nonexistent', 'backend-operation', 'package-configure', 'uninstall-finish', 'manager-cache']:
        result = run(entry, [command, '-c', str(config)], 1)
        assert not result.stdout and 'неизвестная команда'.encode() in result.stderr
    before = (root / 'etc/config/zapret').read_bytes()
    for args in [['service', 'stop'], ['strategy', 'clear'], ['devices', 'clear'], ['network', 'quic', 'on'],
                 ['uninstall', 'manager'], ['manager-update'],
                 ['assets-install', '/tmp/missing']]:
        err = refuse_open_pipe(entry, [*args, '-c', str(config)])
        assert b'--yes' in err, (args, err)
        assert (root / 'etc/config/zapret').read_bytes() == before
        assert not (root / 'tmp/zify.zapret.lock').exists()
    for args in [[], ['-y'], ['-c', str(config)]]:
        assert b'TTY' in refuse_open_pipe(entry, args)
    run(entry, ['config', '-c', str(config), 'set', 'DISABLE_IPV6', '0', '-y'])
    assert run(entry, ['config', 'get', 'DISABLE_IPV6', '-c', str(config)]).stdout == b'0\n'
    run(entry, ['config', 'set', 'DISABLE_IPV6', '1', '--non-interactive', '-c', str(config)])
    # A live non-TTY writer must not delay an explicitly approved operation either.
    child = subprocess.Popen(['sh', str(entry), 'config', 'set', 'DISABLE_IPV6', '1',
                              '-c', str(config), '--yes'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        child.wait(timeout=3)
        out, err = child.communicate(timeout=2)
        assert child.returncode == 0, (out, err)
        passed += 1
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()
    for option in ['NFQWS_PORTS_TCP', 'NFQWS_PORTS_UDP', 'MODE_FILTER', 'DISABLE_CUSTOM', 'DEBUG', 'ENABLED']:
        result = run(entry, ['config', 'set', option, '1', '-y', '-c', str(config)], 1)
        assert 'не поддерживается'.encode() in result.stderr
    result = run(entry, ['config', 'show', '-c', str(config)], 1)
    assert not result.stdout
    for action in ['export', 'benchmark', 'auto-best', 'refresh']:
        before = (root/'etc/config/zapret').read_bytes()
        result = run(entry, ['source', action, 'flowseal', 'unused.txt', '-y', '-c', str(config)], 1)
        assert 'неизвестное действие'.encode() in result.stderr
        assert (root/'etc/config/zapret').read_bytes() == before
        assert not (root/'tmp/zify.zapret.lock').exists()
    # Real terminal confirmation: n leaves state untouched; y executes the command.
    for answer, expected in [(b'n\n', 1), (b'y\n', 0)]:
        before_running = (root / 'state').exists()
        result = subprocess.run([sys.executable, 'tests/support/terminal.py', 'sh', str(entry),
                                 'service', 'stop', '-c', str(config)], input=answer,
                                capture_output=True, timeout=5)
        assert result.returncode == expected, (answer, result.stdout, result.stderr)
        assert b'[y/N]' in result.stderr
        if answer == b'n\n':
            assert (root / 'state').exists() == before_running
        else:
            assert not (root / 'state').exists()
        passed += 1
    # --yes also reaches menu confirmations and the supervisor's worker.
    paths = [root / 'etc/config/zapret', root / 'etc/zify/state.json', root / 'state',
             root / 'enabled', root / 'opt/zapret/config']
    saved = {path: path.read_bytes() if path.exists() else None for path in paths}
    result = subprocess.run([sys.executable, 'tests/support/terminal.py', 'sh', str(entry),
                             '--yes', '-c', str(config)], input=b'3\n5\n\nq\nq\n',
                            capture_output=True, timeout=5)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert b'[y/N]' not in result.stdout + result.stderr
    assert run(entry, ['config', 'get', 'NFQWS_ENABLE', '-c', str(config)]).stdout == b'0\n'
    assert not (root / 'state').exists()
    for path, content in saved.items():
        if content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(content)
    passed += 1
    # --yes after -- is a literal value and cannot authorize a write.
    run(entry, ['-c', str(config), 'config', 'set', 'DISABLE_IPV6', '--', '--yes'], 1)
    run(entry, ['service', 'start' if initial_running else 'stop', '-y', '-c', str(config)])
    # Verify that a piped answer does not count as consent, even when it contains y.
    err = run(entry, ['config', 'set', 'DISABLE_IPV6', '0', '-c', str(config)], 1)
    assert b'--yes' in err.stderr

print(f'cli: {passed} source/bundle contract checks passed')
