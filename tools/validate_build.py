"""Reject stale output, failed routing, and negative routed timing slack."""
from pathlib import Path
import argparse, hashlib, json, re, time
a=argparse.ArgumentParser()
a.add_argument('--since',type=float,required=True,help='Build start, Unix seconds')
a.add_argument('--run-dir',type=Path,help='Optional independent physical run directory')
a.add_argument('--report',type=Path,help='Optional validation report output')
args=a.parse_args()
b=Path(__file__).resolve().parent.parent; p=b/'project'
r=args.run_dir.resolve() if args.run_dir else p/'td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_1'
stem='HDMI1.4b_Transmitter_v1.0'
needed=[r/'route.qor',r/(stem+'.bit'),r/(stem+'_pr.timing'),r/'flow_stdout.txt']
for f in needed:
    assert f.is_file() and f.stat().st_size>0,f'Missing output: {f}'
    assert f.stat().st_mtime>=args.since,f'Stale output: {f}'
flow=(r/'flow_stdout.txt').read_text(encoding='utf-8',errors='replace')
assert 'TD_FLOW_FINISHED' in flow and 'FLOW_EXIT=0' in flow,'TD flow did not complete'
assert not re.search(r'\bERROR:|TD_FLOW_FAILED',flow),'TD flow contains errors'
qor=(r/'route.qor').read_text()
def metric(label):
    m=re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*(-?[0-9.]+)',qor)
    assert m, f'Missing QoR metric {label}'
    return float(m.group(1))
values={label:metric(label) for label in ['Setup WNS','Hold WNS','Num of violated S-EP','Num of violated H-EP','slices percentage','#RAMs','#DSPs']}
assert values['Setup WNS']>=0 and values['Hold WNS']>=0,values
assert values['Num of violated S-EP']==0 and values['Num of violated H-EP']==0,values
source_files=[]
for f in p.rglob('*'):
    if f.is_file() and '_Runs' not in str(f) and f.suffix.lower() in ['.v','.sdc','.adc','.al','.mem','.hex']:
        # build.ps1 captures the start time as whole Unix seconds, while st_mtime is a
        # float. A source edited in the same second the build started therefore used to
        # fail this gate even though it predates the build. Truncate to whole seconds so
        # the comparison means what it says: "not modified after the build started".
        assert int(f.stat().st_mtime)<=args.since,f'Source changed after build start: {f}'
        source_files.append(f)
hashes={str(f.relative_to(p)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest() for f in source_files}
result={'validated_at_unix':time.time(),'build_started_unix':args.since,'timing_scope':'Existing SDC, routed checks; not full CDC or board-level validation','qor':values,'bit_path':str(needed[1]),'bit_sha256':hashlib.sha256(needed[1].read_bytes()).hexdigest(),'sources':hashes}
(args.report or b/'reports/build_validation.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print('PASS routed timing/output/source freshness gate:',json.dumps(values))
print('BIT SHA256',result['bit_sha256'])
