"""Verify v186 source identity and the explicitly scoped release evidence."""
from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((R/'project_manifest.json').read_text(encoding='utf-8'))
s=json.loads((R/'release_status.json').read_text(encoding='utf-8'))
assert m['release']==s['release']=='v186-720p30-board-confirmed-20261031'
assert s['board_confirmed']
by={x['project_path']:x for x in m['files']}
assert len(by)==len(m['files'])
for row in m['files']:
    if row['external']:
        assert row['public_path'] is None
    else:
        p=R/row['public_path']
        assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],str(p)
        assert b'`pragma protect begin_protected'not in p.read_bytes()
gates={}
for name,row in s['gates'].items():
    p=R/row['path'];assert sha(p)==row['sha256'],str(p)
    gates[name]=json.loads(p.read_text(encoding='utf-8'))
    if name!='board':assert gates[name]['passed'],name
t=gates['timing'];b=gates['board']
assert t['bit_sha256']==b['bit_sha256']==s['bit_sha256']
assert b['board_confirmed'] and b['second_cs_full_duration_tested'] and b['end_av_sync_normal'] and b['automatic_next_video_normal']
assert t['clock_audit']['passed'] and all(t['clock_audit']['checks'].values())
assert all(by[n]['sha256']==h for n,h in t['source_sha256'].items())
for kind in ['Setup','Hold']:
    assert t['metrics_ps'][kind+' WNS']>=0 and t['metrics_ps'][kind+' TNS']==0
    assert t['metrics_ps']['Num of violated '+kind[0]+'-EP']==0
E=R/'releases/v186/evidence'
assert 'video_clk -> hdmi_5x_clk' in (E/'fresh_routed.timing').read_text()
policy=json.loads((E/'CONSTRAINT_POLICY.json').read_text())
assert by['user_source/constraints_source/timing.sdc']['sha256']==policy['candidate_sdc_sha256']
assert all(by[n]['sha256']==h for n,h in policy['rtl_sha256'].items())
assert gates['source_export']['project_manifest_sha256']==sha(R/'project_manifest.json')
assert gates['source_export']['total_files']==len(m['files'])
for n,h in gates['media_reuse']['media_source_bindings'].items():assert by[n.replace('\\','/')]['sha256']==h
for name,key in [('image_pixels','files_sha256'),('image_integration','source_sha256')]:
    gate=gates[name]
    assert all(x['passed']for x in gate['cases'])
    for n,h in gate[key].items():
        text=n.replace('\\','/')
        if '/candidate/project/'in text:assert by[text.split('/candidate/project/',1)[1]]['sha256']==h
assert len(gates['image_pixels']['cases'])==6 and len(gates['image_integration']['cases'])==2
assert gates['source_identity']['checked_frames']==8136 and gates['source_identity']['fps']==30
assert gates['frame_assembly']['frames']==8136
assert gates['encoder_pairing']['checked_codewords']==1536
assert all(gates['sustained_peak']['checks'].values())
print('PASS v186 exact public sources, independent internal STA, image regression, media evidence reuse and recorded board confirmation.')
print('Scope excludes exhaustive external-IO/CDC audit, every display/card, instrumented unique-frame capture and multi-hour soak.')
