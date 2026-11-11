"""The fake replacement picker returns to its immediate parent."""
from pathlib import Path
import json
import os
import subprocess
import sys

sys.path.insert(0, str(Path('tests/support').resolve()))
from pty_ui import Terminal

config = Path(sys.argv[1])
root = Path(os.environ['ZIFY_TEST_ROOT'])
paths = [root/'etc/config/zapret', root/'etc/zify/state.json', root/'service-actions']

for entry in ['src/launcher.sh', 'dist/zify.sh']:
    saved = {path: path.read_bytes() for path in paths}
    result = subprocess.run(['sh', entry, '--config', str(config), 'fake', 'list'],
                            capture_output=True, check=True)
    groups = {}
    for slot in json.loads(result.stdout):
        groups.setdefault(slot['path'], []).append(slot)
    candidates = [(group_index, slots, target_index) for group_index, slots in enumerate(groups.values(), 1)
                  for target_index, slot in enumerate(slots, 1)
                  if target_index > 1 and slot['option'] == '--dpi-desync-split-seqovl-pattern']
    assert candidates, 'fixture must contain a shared pattern file with a nested target menu'
    group_index, slots, target_index = candidates[-1]
    filename = slots[target_index - 1]['filename']
    selected = f'> {target_index:<3}split-seqovl-pattern'
    t = Terminal(entry, config)
    t.expect('Q — выход')
    t.send(b'3')
    t.expect('Очистить стратегию')
    t.send(b'4')
    t.expect('Файлов в текущей стратегии:')
    t.send(str(group_index).encode())
    text = t.expect('где заменить')
    assert 'Шаблон перекрытия' not in text and 'split-seqovl-pattern' in text, text
    t.send(str(target_index).encode())
    text = t.expect('N — далее')
    assert filename + ' → split-seqovl-pattern' in text, text
    # Both back keys return one level, preserving the selected occurrence.
    for back in [b'q', b'\x1b[D']:
        t.send(back)
        text = t.expect('где заменить')
        assert selected in text, text
        assert 'Файлов в текущей стратегии:' not in text, text
        t.send(b'\x1b[C')
        t.expect('N — далее')
    t.send(b'q')
    t.expect('где заменить')
    t.send(b'q')
    t.expect('Файлов в текущей стратегии:')
    # A fresh visit to the occurrence menu starts at its first row.
    t.send(b'\x1b[C')
    text = t.expect('где заменить')
    assert '> 1  ' in text, text
    t.send(b'qqq')
    t.expect('Q — выход')
    t.close()
    for path, before in saved.items():
        assert path.read_bytes() == before, path

print('fake menu: source + bundle, Q/Left return one level, scoped selection, exact pattern label and read-only cancellation OK')
