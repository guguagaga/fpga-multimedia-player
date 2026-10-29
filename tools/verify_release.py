"""Verify production source mappings and the v182 evidence identity, without synthesis."""
from pathlib import Path
import hashlib, json

root=Path(__file__).resolve().parents[1]
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
manifest=json.loads((root/'project_manifest.json').read_text(encoding='utf-8'))
status=json.loads((root/'release_status.json').read_text(encoding='utf-8'))
paths=set();public=external=0
for row in manifest['files']:
    assert row['project_path'] not in paths
    paths.add(row['project_path'])
    if row['external']:
        assert row['public_path'] is None
        external+=1;continue
    file=root/row['public_path']
    assert file.is_file() and file.stat().st_size==row['bytes'] and sha(file)==row['sha256'],row['public_path']
    assert b'`pragma protect begin_protected' not in file.read_bytes()
    public+=1
timing=json.loads((root/'releases/v182/evidence/fresh_routed.json').read_text())
assert timing['passed'] and timing['bit_sha256']==status['bit']['sha256']
by_path={r['project_path']:r for r in manifest['files']}
assert all(by_path[n]['sha256']==h for n,h in timing['source_sha256'].items())
for report in (root/'releases/v182/evidence').glob('av_v182_*.json'):
    r=json.loads(report.read_text());assert r['data_correct'] and r['continuity_pass'],report
assert status['board_feedback']['classification']=='USER_REPORTED_NORMAL'
print(f'PASS: {public} exact public production files, {external} vendor dependencies, independent STA and joint evidence identities')
