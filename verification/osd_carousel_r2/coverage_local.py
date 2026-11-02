from pathlib import Path
import json,re,subprocess,os,sys,hashlib
R=Path('D:/codexworks/osd_carousel_v187/rebuild_r2');P=R/'candidate/project';stem='HDMI1.4b_Transmitter_v1.0'
B=Path('D:/codexworks/framerate_v185_20261029/hdmi_no_signal_v185/scaler_compare_pipeline')
G=Path('D:/codexworks/release_v182_20261029/repository')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
baseline=json.loads((G/'releases/v186/evidence/timing.json').read_text())
base_db=B/f'candidate/project/td_project/{stem}_Runs/phy_cjk_align_seed26/{stem}_pr.db'
assert sha(base_db)==baseline['db_sha256'],'v186 reference DB changed'
os.environ.update(PYTHONUTF8='1',PYTHONDONTWRITEBYTECODE='1',TEMP=str(R/'tmp'),TMP=str(R/'tmp'))
def report(name,db):
 out=R/'reports'/name;out.mkdir(exist_ok=False)
 subprocess.run([sys.executable,str(P/'build/_mk_prj2.py'),str(out)],check=True)
 tcl=f'''import_device eagle_s20.db -package EG4S20BG256
open_project {stem}.prj -noanalyze
import_db {{{db.as_posix()}}}
clear_sdc -user
read_sdc {{{(P/'user_source/constraints_source/timing.sdc').as_posix()}}}
update_timing -mode final
check_timing -verbose -file coverage.txt
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
report_route_status -drc
'''
 (out/'local_flow.tcl').write_text(tcl);(out/'driver.tcl').write_bytes((P/'build/run_flow.tcl').read_bytes())
 before=sha(db)
 with(out/'flow_stdout.txt').open('w')as f:
  p=subprocess.run(['D:/TD3/bin/td_commands_prompt.exe','driver.tcl'],cwd=out,env=dict(os.environ,TD_FLOW_SCRIPT=str(out/'local_flow.tcl')),stdout=f,stderr=subprocess.STDOUT)
 assert p.returncode==0 and before==sha(db)
 return out
def sections(out):
 text=(out/'coverage.txt').read_text();text=text[text.index('1. checking nets with no clock driven.'):]
 return {re.match(r'(\d+)\.',s)[1]:re.sub(r'\s+',' ',s).strip()for s in re.split(r'(?m)(?=^\d+\. checking )',text)if s.strip()}
base=report('coverage_v186_reference',base_db)
candidate=report('coverage_r2_seed26',P/f'td_project/{stem}_Runs/phy_r2_seed26/{stem}_pr.db')
bs,cs=sections(base),sections(candidate)
checks={f'category_{n}_unchanged':bs[n]==cs[n]for n in bs if n!='3'}
bm=sorted(set(re.findall(r'DummyNode in Model: (\w+)',bs['3'])));cm=sorted(set(re.findall(r'DummyNode in Model: (\w+)',cs['3'])))
checks['dummy_primitive_families_unchanged']=bm==cm
groups=lambda d:sorted(set(re.findall(r'^\w+ -> \w+$',(d/'ignored.txt').read_text(),re.M)))
checks['async_groups_unchanged']=groups(base)==groups(candidate)
record=dict(passed=all(checks.values()),checks=checks,baseline_sections=bs,candidate_sections=cs,baseline_dummy_models=bm,candidate_dummy_models=cm,baseline_db_sha256=sha(base_db),files_sha256={str(p):sha(p)for o in (base,candidate)for p in (o/'coverage.txt',o/'ignored.txt')},source_sha256=json.loads((R/'source_snapshot.json').read_text()))
(R/'reports/coverage_comparison.json').write_text(json.dumps(record,indent=2))
print(json.dumps(dict(passed=record['passed'],checks=checks),indent=2),flush=True)
