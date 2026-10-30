"""Independent original-constraint STA with portable baseline scope review."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess,sys
a=argparse.ArgumentParser();a.add_argument('root',type=Path);a.add_argument('--seed',type=int,default=24);a.add_argument('--td-command',default='D:/TD3/bin/td_commands_prompt.exe');args=a.parse_args()
C=args.root.resolve();P=C/'candidate/project';tools=C/'tools';baseline=json.loads((tools/'coverage_baseline.json').read_text())
assert C.drive.upper()=='D:','Build and verification outputs must be on D:'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
syn=json.loads((C/'candidate/reports/cjk_align_synthesis.json').read_text(encoding='utf-8-sig'));assert all(sha(P/n)==h for n,h in syn['sources'].items())
for n,h in baseline['constraint_pll_sha256'].items():assert sha(P/n)==h,f'Original constraint/clock source changed: {n}'
O=C/'reports'/('coverage'+str(args.seed)+'_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S'));O.mkdir(parents=True,exist_ok=False)
db=P/f'td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_cjk_align_seed{args.seed}/HDMI1.4b_Transmitter_v1.0_pr.db';before=sha(db)
tmp=C/'tmp';tmp.mkdir(exist_ok=True);os.environ.update(TEMP=str(tmp),TMP=str(tmp),PYTHONDONTWRITEBYTECODE='1',PATH=str(Path(sys.executable).parent)+os.pathsep+os.environ['PATH'])
subprocess.run([sys.executable,str(P/'build/_mk_prj2.py'),str(O)],check=True)
(O/'check.tcl').write_text(f'''import_device eagle_s20.db -package EG4S20BG256
open_project HDMI1.4b_Transmitter_v1.0.prj -noanalyze
import_db {{{db.as_posix()}}}
clear_sdc -user
read_sdc {{{(P/'user_source/constraints_source/timing.sdc').as_posix()}}}
update_timing -mode final
check_timing -verbose -file coverage.txt
report_timing_summary -file timing.txt
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
''')
subprocess.run(['cmd.exe','/d','/c',str(P/'build/_flow_run.cmd'),str(O),'check.tcl',args.td_command],check=True)
assert sha(db)==before
text=(O/'coverage.txt').read_text();text=text[text.index('1. checking nets with no clock driven.'):]
sections={re.match(r'(\d+)\.',s)[1]:re.sub(r'\s+',' ',s).strip()for s in re.split(r'(?m)(?=^\d+\. checking )',text)if s.strip()}
checks={f'category_{i}_unchanged':sections[i]==s for i,s in baseline['sections'].items()}
checks['async_groups_unchanged']=sorted(set(re.findall(r'^\w+ -> \w+$',(O/'ignored.txt').read_text(),re.M)))==baseline['async_groups']
# Unconnected synthesized LUT inputs and BRAM parity outputs vary with logic.
# Reject unexpected primitive families rather than silently waiving category3.
dummy_models=sorted(set(re.findall(r'DummyNode in Model: (\w+)',sections['3'])))
checks['dummy_node_models_reviewed']=set(dummy_models)<=set(baseline['dummy_models'])
checks['source_hashes_unchanged']=all(sha(P/n)==h for n,h in syn['sources'].items())
coverage=float(re.search(r'STA coverage\s*:\s*([\d.]+)%',(O/'timing.txt').read_text())[1])
review=dict(passed=all(checks.values()),checks=checks,baseline_coverage_percent=baseline['coverage_percent'],candidate_coverage_percent=coverage,source_sha256=syn['sources'],files_sha256={str(p):sha(p)for p in [tools/'coverage_baseline.json',O/'coverage.txt',O/'timing.txt',O/'ignored.txt']},scope='Detailed coverage categories and asynchronous groups must match the recorded v167 baseline; dummy-node primitive families checked separately. Existing external IO/CDC limits persist.')
(C/'reports/coverage_review.json').write_text(json.dumps(review,indent=2));assert review['passed'],checks
subprocess.run([sys.executable,str(tools/'recheck_board_routed.py'),str(C),'--seed',str(args.seed),'--td-command',args.td_command],check=True)
print('PASS independent routed STA and coverage scope. Physical board and external IO/CDC acceptance remain separate.')
