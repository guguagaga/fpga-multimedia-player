"""Reproduce frozen 720P30 stress cases with hash-checked RTL and fixtures."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,shutil,subprocess,time

R=Path(__file__).resolve().parent
a=argparse.ArgumentParser()
a.add_argument('--case',required=True)
a.add_argument('--project',type=Path,default=R.parent/'source/candidate/project')
a.add_argument('--tool-root',type=Path,default=Path('D:/codexworks/toolchains/oss-cad-20261029'))
a.add_argument('--validate-only',action='store_true')
args=a.parse_args()
assert R.drive.upper()=='D:','Run from D: to keep generated work off C:'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest=R/'compiled_cases.json'
case=json.loads(manifest.read_text())[args.case]
S=R/'compiled_cases'/args.case
P=args.project.resolve()
assert all(sha(S/n)==h for n,h in case['assets'].items()),'Fixture changed'
for item in case['files']:
    file=(P if item['kind']=='project'else S)/item['path']
    assert sha(file)==item['sha256'],str(file)
if args.validate_only:
    print('PASS source and fixture identity:',args.case)
    raise SystemExit(0)
B=R/'runs'/(args.case+'_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
B.mkdir(parents=True,exist_ok=False)
for file in S.iterdir():
    if file.suffix in ('.v','.sv','.vh'):
        data=re.sub(r'[A-Za-z]:/[^"\n]+?/candidate/project',lambda m:P.as_posix(),file.read_text(encoding='utf-8'))
        (B/file.name).write_text(data,encoding='utf-8')
    else:shutil.copy2(file,B/file.name)
V=args.tool_root/'oss-cad-suite'
G=args.tool_root/'w64devkit/bin'
tmp=R/'tmp';tmp.mkdir(exist_ok=True)
os.environ.update(PATH=str(G)+os.pathsep+str(V/'bin')+os.pathsep+str(V/'lib')+os.pathsep+os.environ['PATH'],TEMP=str(tmp),TMP=str(tmp),VERILATOR_ROOT=str(V/'share/verilator'))
files=[(P if x['kind']=='project'else B)/x['path']for x in case['files']]
start=time.time()
cmd=[str(V/'bin/verilator_bin.exe'),'--cc','--main','--timing','--top-module','tb_video_quality_sd_cache','--Mdir','obj','--prefix','Vbench','-Wno-fatal']+[p.as_posix()for p in files if p.suffix=='.v']
with(B/'translate.log').open('w')as f:subprocess.run(cmd,cwd=B,stdout=f,stderr=subprocess.STDOUT,check=True)
inc=V/'share/verilator/include'
cpp=list((B/'obj').glob('*.cpp'))+[inc/n for n in('verilated.cpp','verilated_timing.cpp','verilated_threads.cpp')]
cmd=[str(G/'g++.exe'),'-std=c++20','-O2','-pthread','-DVL_TIME_CONTEXT','-DVM_TIMING=1','-I'+str(B/'obj'),'-I'+str(inc),'-I'+str(inc/'vltstd')]+[str(p)for p in cpp]+['-o',str(B/'sim.exe')]
with(B/'compile.log').open('w')as f:subprocess.run(cmd,cwd=B,stdout=f,stderr=subprocess.STDOUT,check=True)
compile_seconds=time.time()-start;start=time.time()
with(B/'console.log').open('w')as f:rc=subprocess.run([str(B/'sim.exe')]+case['plusargs'],cwd=B,stdout=f,stderr=subprocess.STDOUT).returncode
s=(B/'console.log').read_text()
decode=[tuple(map(int,x))for x in re.findall(r'CHECKED720 frame=(\d+) pixels=(\d+) bank=(\d+) cycles=(\d+)',s)]
present=[tuple(map(int,x))for x in re.findall(r'PRESENT720 n=(\d+) cycle=(\d+) consumed=(\d+)',s)]
gap=re.search(r'maxstall=(\d+)',s)
n=case['frames'];intervals=[b[1]-a[1]for a,b in zip(present,present[1:])]
checks=dict(exit_ok=rc==0,pixels=len(decode)==n and all(x[0]==i+1 and x[1]==921600 for i,x in enumerate(decode)),
    cadence=len(present)==n and all(x[0]==i+1 and x[2]==i*1600 for i,x in enumerate(present))and all(x==3030304 for x in intervals),
    pcm_eof='FINITE_EOF_PASS'in s and f'PASS720 real IMA video decoded={n} presented={n} PCM_samples={n*1600}'in s,
    bounded_audio_wait=gap is not None and int(gap[1])<=1894,no_fatal=not re.search(r'%Error|%Fatal|\*\* (Error|Fatal)',s),
    source_unchanged=all(sha((P if x['kind']=='project'else S)/x['path'])==x['sha256']for x in case['files']))
report=dict(passed=all(checks.values()),checks=checks,case=args.case,source_manifest_sha256=sha(manifest),project=str(P),seconds=time.time()-start,compile_seconds=compile_seconds,interval_cycles=intervals)
(B/'result.json').write_text(json.dumps(report,indent=2))
print(s[-1800:]);print(B)
raise SystemExit(0 if report['passed']else 1)
