"""Build a future release pair for update/rollback integration checks."""
from pathlib import Path
import hashlib
import io
import json
import re
import sys
import tarfile

sys.path.insert(0, str(Path('tools').resolve()))
from release import metadata

root, code, assets, version, mode = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5]
body = code.read_bytes()
body = re.sub(rb"# ZIFY_VERSION=[0-9.]+", b"# ZIFY_VERSION=" + version.encode(), body)
body = re.sub(rb"VERSION = '[0-9.]+'", b"VERSION = '" + version.encode() + b"'", body)
if mode == 'invalid-code':
    body += b'\nif then\n'
(root/'manager-release').write_bytes(body)
with tarfile.open(assets) as archive:
    files = {m.name: archive.extractfile(m).read() for m in archive.getmembers()}
manifest = json.loads(files['manifest.json'])
manifest['version'] = version
for entry in manifest['files']:
    if entry['target'] == 'fake':
        payload = files[entry['path']] + (' release-' + version).encode()
        files[entry['path']] = payload
        entry['size'] = len(payload)
        entry['sha256'] = hashlib.sha256(payload).hexdigest()
files['manifest.json'] = (json.dumps(manifest) + '\n').encode()
with tarfile.open(root/'manager-assets', 'w:gz') as archive:
    for name, payload in files.items():
        member = tarfile.TarInfo(name)
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
index = metadata(root/'manager-release', root/'manager-assets')
(root/'manager-index').write_text(json.dumps(index) + '\n')
if mode == 'corrupt-assets':
    payload = (root/'manager-assets').read_bytes()
    (root/'manager-assets').write_bytes(payload[:-1] + bytes([payload[-1] ^ 1]))
elif mode != 'invalid-code' and mode != 'valid':
    raise ValueError(mode)
