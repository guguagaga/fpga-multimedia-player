"""Portable ModelSim runner for immutable, hashed saved integration benches."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess
R=Path(__file__).resolve().parent
a=argparse.ArgumentParser();a.add_argument('--list',action='store_true');a.add_argument('--case');a.add_argument('--project',type=Path,default=R.parent/'source/candidate/project');a.add_argument('--td-root',type=Path,default=Path('D:/TD3'));a.add_argument('--vsim',type=Path,default=Path('E:/modelsim/modelsim_ase/win32aloem/vsim.exe'));args=a.parse_args()
cases=json.loads((R/'cases.json').read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
if args.list:print('\n'.join(cases));raise SystemExit(0)
assert args.case in cases,'Choose a listed --case'
assert R.drive.upper()=='D:','Place the package on D: before running'
P=args.project.resolve();case=cases[args.case];S=R/'cases'/args.case
assert all(sha(S/n)==h for n,h in case['assets'].items()),'Bench/fixture was changed'
assert all(sha(P/n)==h for n,h in case['project_assets'].items()),'Frozen decoder ROM was changed'
T=R/'runs'/(args.case+'_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'));T.mkdir(parents=True,exist_ok=False)
for p in S.iterdir():
 if p.suffix in ('.v','.sv','.vh'):
  s=p.read_text(encoding='utf-8')
  s=re.sub(r'[A-Za-z]:/[^"\n]+?/candidate/project',lambda m:P.as_posix(),s)
  (T/p.name).write_text(s,encoding='utf-8')
 else:(T/p.name).write_bytes(p.read_bytes())
files=[]
for entry in case['files']:
 root={'project':P,'td':args.td_root,'local':S}[entry['kind']];p=root/entry['path']
 assert sha(p)==entry['sha256'],f'Source/model mismatch: {p}'
 files.append(T/p.name if entry['kind']=='local'else p)
flow='onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+p.as_posix()+'}'for p in files)+'\n'+case['command']+'\nrun -all\nquit -code 0\n'
(T/'run.do').write_text(flow);tmp=R/'tmp';tmp.mkdir(exist_ok=True);os.environ.update(TEMP=str(tmp),TMP=str(tmp),PYTHONDONTWRITEBYTECODE='1')
with(T/'console.log').open('w')as f:rc=subprocess.run([str(args.vsim),'-c','-do','run.do'],cwd=T,stdout=f,stderr=subprocess.STDOUT)
out=(T/'console.log').read_text(errors='replace');passed=rc.returncode==0 and case['marker']in out and '** Fatal'not in out and '** Error'not in out
intervals=[]
if case['full_cadence']:
 rows=[tuple(map(int,x))for x in re.findall(r'PRESENT720 n=(\d+) cycle=(\d+) consumed=(\d+)',out)]
 intervals=[b[1]-a[1]for a,b in zip(rows,rows[1:])]
 gap=re.search(r'maxstall=(\d+)',out)
 expected_frames=case.get('expected_frames',30)
 passed=passed and len(rows)==expected_frames and [x[0]for x in rows]==list(range(1,expected_frames+1))and all(x==3030304 for x in intervals)and gap is not None and int(gap[1])<=1894
(T/'result.json').write_text(json.dumps(dict(passed=passed,case=args.case,interval_cycles=intervals,project=str(P),source_manifest_sha256=sha(R/'cases.json')),indent=2))
print(out[-1800:]);print(T);assert passed
