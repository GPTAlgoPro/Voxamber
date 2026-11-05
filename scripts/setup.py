"""Download the pinned official release; never changes sandbox limits."""
import hashlib
import json
import os
from pathlib import Path
import platform
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TAG = 'v1.2.3'
DEST = ROOT / 'tools'
DEST.mkdir(exist_ok=True)
request = urllib.request.Request(f'https://api.github.com/repos/google/three-live/releases/tags/{TAG}', headers={'User-Agent': 'three-live-apple-lab'})
release = json.load(urllib.request.urlopen(request, timeout=30))
assets = {a['name']: a for a in release['assets']}
names = ['three-live-cli-macos-arm64', 'three-live-web-dist.zip']
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('This experiment pins the macOS arm64 compiler.')
receipt = {'tag': TAG, 'release_url': release['html_url'], 'assets': {}}
for name in names:
    target = DEST / ('three-live-cli' if name.startswith('three-live-cli') else name)
    if not target.exists():
        urllib.request.urlretrieve(assets[name]['browser_download_url'], target)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    expected = assets[name].get('digest')
    if expected and expected != f'sha256:{digest}':
        raise SystemExit(f'Official release digest mismatch: {name}')
    receipt['assets'][name] = {'url': assets[name]['browser_download_url'], 'sha256': digest, 'github_digest': expected}
os.chmod(DEST / 'three-live-cli', 0o755)
web = DEST / 'web'
web.mkdir(exist_ok=True)
with zipfile.ZipFile(DEST / 'three-live-web-dist.zip') as archive:
    for name in ['three-live-full.min.js', 'three-live.min.js', 'three-live-viewer.min.js']:
        (web / name).write_bytes(archive.read(name))
(DEST / 'release-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
