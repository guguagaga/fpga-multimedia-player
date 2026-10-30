"""Verify public source identity and completed gate evidence, without board claims."""
from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((R/'project_manifest.json').read_text(encoding='utf-8'))
s=json.loads((R/'release_status.json').read_text(encoding='utf-8'))
assert m['release']==s['release']=='v185-720p30-board-test-20261030'and not s['board_confirmed']
by={x['project_path']:x for x in m['files']}
assert len(by)==len(m['files'])
for row in m['files']:
    if row['external']:
        assert row['public_path']is None
    else:
        p=R/row['public_path']
        assert p.stat().st_size==row['bytes']and sha(p)==row['sha256'],str(p)
        assert b'`pragma protect begin_protected'not in p.read_bytes()
gates={}
for k,row in s['gates'].items():
    p=R/row['path'];assert sha(p)==row['sha256'],str(p)
    gates[k]=json.loads(p.read_text());assert gates[k]['passed'],k
t=gates['timing'];assert t['bit_sha256']==s['bit_sha256']and t['clock_audit']['passed']
assert all(by[n]['sha256']==h for n,h in t['source_sha256'].items())
for kind in ('Setup','Hold'):
    assert t['metrics_ps'][kind+' WNS']>=0 and t['metrics_ps'][kind+' TNS']==0
    assert t['metrics_ps']['Num of violated '+kind[0]+'-EP']==0
E=R/'releases/v185/evidence'
index=json.loads((E/'EVIDENCE_INDEX.json').read_text())
for row in index.values():assert sha(E/row['path'])==row['sha256'],row['path']
for row in gates['source_evidence']['results']:
    assert row['test_passed']and row['source_matches']
    assert all(by[x['path']]['sha256']==x['candidate_sha256']for x in row['modules'])
assert len(gates['av_cadence']['interval_cycles'])==29
assert all(gates['sustained_peak']['checks'].values())
assert gates['source_identity']['checked_frames']==8136 and gates['source_identity']['fps']==30
assert gates['frame_assembly']['frames']==8136
assert gates['frame_assembly']['token_sha256']==json.loads((E/index[next(k for k in index if k.replace('\\','/').endswith('/canonical_merge.json'))]['path']).read_text())['token_sha256']
assert gates['encoder_pairing']['checked_codewords']==1536
assert gates['source_export']['total_files']==len(m['files'])
print('PASS exact v185 public sources, internal STA and completed layered evidence; board acceptance pending.')
