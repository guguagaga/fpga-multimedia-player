"""Record deliberately edited build inputs before a new local build."""
from pathlib import Path
import argparse
import hashlib
import json
import datetime

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--accept-local-edits', action='store_true')
p.add_argument('--vendor-project', type=Path, help='Optional matching project for vendor identity checks')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
path = root / 'project_manifest.json'
data = json.loads(path.read_text(encoding='utf-8'))
changes = []
for item in data['files']:
    if item['external'] and a.vendor_project is None:
        continue
    f = a.vendor_project.resolve() / item['project_path'] if item['external'] else root / item['public_path']
    digest = hashlib.sha256(f.read_bytes()).hexdigest()
    if digest != item['sha256'] or f.stat().st_size != item['bytes']:
        if item['external']:
            raise RuntimeError('Vendor dependency changed: ' + str(f))
        changes.append(dict(path=item['public_path'], old=item['sha256'], new=digest))
        item.update(sha256=digest, bytes=f.stat().st_size)
print(json.dumps(changes, ensure_ascii=False, indent=2))
if changes and not a.accept_local_edits:
    p.error('Review the changes, then rerun with --accept-local-edits to record them.')
if changes:
    out = root / 'build_workspace' / ('manifest_edit_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
    out.mkdir(parents=True)
    (out / 'previous_manifest.json').write_bytes(path.read_bytes())
    (out / 'changes.json').write_text(json.dumps(changes, indent=2), encoding='utf-8')
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
if a.vendor_project is None:
    print('NOT CHECKED: external vendor inputs; pass --vendor-project to verify them.')
print('Manifest ready for the next build. Released evidence is unchanged.')
