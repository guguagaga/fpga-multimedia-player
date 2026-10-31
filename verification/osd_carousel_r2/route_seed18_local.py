from pathlib import Path
import hashlib,json,subprocess,os,re,sys
R=Path('D:/codexworks/osd_carousel_v187/rebuild_r2');P=R/'candidate/project'
G=Path('D:/codexworks/release_v182_20261029/repository');stem='HDMI1.4b_Transmitter_v1.0'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
binding=json.loads((R/'synthesis_binding.json').read_text());sources=binding['source_sha256']
syn=Path(binding['gate_path']).parent
assert sha(Path(binding['gate_path']))==binding['gate_sha256']
def verify():assert all(sha(P/n)==h for n,h in sources.items())
verify()
os.environ.update(PYTHONUTF8='1',PYTHONDONTWRITEBYTECODE='1',TEMP=str(R/'tmp'),TMP=str(R/'tmp'))
phy=P/f'td_project/{stem}_Runs/phy_r2_seed18';assert not phy.exists()
def run(out,tcl,settings=None):
 out.mkdir(parents=True)
 subprocess.run([sys.executable,str(P/'build/_mk_prj2.py'),str(out)],check=True)
 if settings is not None:(out/'settings.cfg').write_text(settings)
 (out/'local_flow.tcl').write_text(tcl)
 shutil_driver=P/'build/run_flow.tcl';(out/'driver.tcl').write_bytes(shutil_driver.read_bytes())
 with (out/'flow_stdout.txt').open('w')as f:p=subprocess.run(['D:/TD3/bin/td_commands_prompt.exe','driver.tcl'],cwd=out,env=dict(os.environ,TD_FLOW_SCRIPT=str(out/'local_flow.tcl')),stdout=f,stderr=subprocess.STDOUT)
 log=(out/'flow_stdout.txt').read_text(errors='replace')
 assert p.returncode==0 and 'TD_FLOW_FINISHED'in log and not re.search(r'\bERROR:|TD_FLOW_FAILED',log)
 verify();return log
margin=R/'reports/seed18_margin.sdc';margin.write_text('set_clock_uncertainty -setup 1.400 [get_clocks {sd_card_clk}]\nset_clock_uncertainty -setup 0.400 [get_clocks {video_clk}]\n')
settings=(P/'build/settings_phy_1.cfg').read_text();settings=re.sub(r'^set parent .*$', 'set parent {'+syn.as_posix()+'}',settings,flags=re.M)
flow=(P/'build/phy_stage_flow.tcl').read_text().replace('set_param place effort high','set_param place effort high\n  set_param flow enable_seed on\n  set_param place seed 18')
flow=flow.replace('read_sdc ../../../build/optimization_margin.sdc','read_sdc {'+margin.as_posix()+'}')
print('Seed18 same verified new gate DB; optimization-only SD margin1.4ns/video0.4ns',flush=True)
log=run(phy,flow,settings);assert f'import_db {syn.as_posix()}/{stem}_gate.db'in log
assert sha(Path(binding['gate_path']))==binding['gate_sha256']
db=phy/(stem+'_pr.db');bit=phy/(stem+'.bit');fresh=R/'reports/fresh_sta_seed18'
before={str(p):sha(p)for p in (db,bit)}
print('Seed18 physical done; independent STA + detailed coverage',flush=True)
run(fresh,f'''import_device eagle_s20.db -package EG4S20BG256
open_project {stem}.prj -noanalyze
import_db {{{db.as_posix()}}}
clear_sdc -user
read_sdc {{{(P/'user_source/constraints_source/timing.sdc').as_posix()}}}
update_timing -mode final
check_timing -verbose -file coverage.txt
report_route_status -drc
report_timing_summary -file fresh_pr.timing
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
report_qor -step route -file route.qor
''')
assert before=={str(p):sha(p)for p in (db,bit)}
sys.path.insert(0,str(G/'tools'));from audit_clock_scope import audit_clock_scope
expected=json.loads((G/'releases/v186/evidence/timing.json').read_text())['clock_audit']['clocks_mhz']
t=(fresh/'fresh_pr.timing').read_text();q=(fresh/'route.qor').read_text();audit=audit_clock_scope(t,expected)
metric=lambda n:float(re.search(r'\|\s*'+re.escape(n)+r'\s*\|\s*(-?[\d.]+)',q)[1])
metrics={n:metric(n)for n in ['Setup WNS','Setup TNS','Num of violated S-EP','Hold WNS','Hold TNS','Num of violated H-EP','#slices','#RAMs','#DSPs']}
result=dict(passed=False,metrics_ps=metrics,clock_audit=audit,source_sha256=sources,gate_sha256=binding['gate_sha256'],db_sha256=sha(db),bit_sha256=sha(bit),bit_path=str(bit),note='Coverage detail review required before marking passed; never accept same-process single DeriveClock report',board_confirmed=False)
(R/'reports/result_seed18.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items()if k!='source_sha256'},indent=2),flush=True)
