"""Verify v183 candidate source/evidence identity, without synthesis or board claims."""
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
evidence=root/'releases/v183/evidence'
timing=json.loads((evidence/'fresh_routed.json').read_text())
assert timing['passed'] and timing['bit_sha256']==status['bit_sha256']
assert timing['clock_audit']['passed']
for kind in ['Setup','Hold']:
    assert timing['metrics_ps'][kind+' WNS']>=0 and timing['metrics_ps'][kind+' TNS']==0
    assert timing['metrics_ps']['Num of violated '+kind[0]+'-EP']==0
by_path={r['project_path']:r for r in manifest['files']}
assert all(by_path[n]['sha256']==h for n,h in timing['source_sha256'].items())
index=json.loads((evidence/'verification_index.json').read_text());assert index['passed']
markers={'  reg         sel_pending;':'  // 2026-10-10','  wire av_drain_old_stream =':'  reg [1:0] av_mute_sync;'}
top=(root/by_path['user_source/hdl_source/top_tf_hdmi_audio.v']['public_path']).read_text(encoding='utf-8')
for row in index['tests']:
    report=evidence/(row['name']+'.json');assert sha(report)==row['sha256'],report
    r=json.loads(report.read_text());assert r.get('passed',r.get('data_correct',False)),report
    if row['name']=='actual_720p':assert r['continuity_pass']
    for name,digest in row.get('final_source_checks',{}).items():
        if name in markers:
            block=top[top.index(name):top.index(markers[name],top.index(name))]
            assert hashlib.sha256(block.encode()).hexdigest()==digest
        else:assert by_path[name.replace('\\','/')]['sha256']==digest,name
    if row['name']=='osd_index_equivalence':assert r['source_sha256']==by_path['rtl/osd_player_ui.v']['sha256'] and r['cases']==256
assert status['board_confirmed'] is False
print(f'PASS: {public} exact public candidate files, {external} vendor dependencies, independent STA and layered evidence; board acceptance pending')
