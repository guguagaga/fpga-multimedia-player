from pathlib import Path
import hashlib,json,subprocess,os,re,datetime,shutil,sys
R=Path('D:/codexworks/osd_carousel_v187/rebuild_r2')
G=Path('D:/codexworks/release_v182_20261029/repository')
V=Path('D:/codexworks/framerate_v185_20261029/hdmi_no_signal_v185/scaler_compare_pipeline/candidate/project')
P=R/'candidate/project'; stem='HDMI1.4b_Transmitter_v1.0'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert not R.exists(),'Never overwrite an existing build'
R.mkdir(parents=True)
os.environ.update(PYTHONUTF8='1',PYTHONDONTWRITEBYTECODE='1',TEMP=str(R/'tmp'),TMP=str(R/'tmp'))
(R/'tmp').mkdir()
m=json.loads((G/'project_manifest.json').read_text())
changed={'rtl/carousel_period_cfg.v','rtl/osd_player_ui.v','user_source/hdl_source/top_tf_hdmi_audio.v'}
sources={}
for row in m['files']:
    src=V/row['project_path'] if row['external'] else G/row['public_path']
    if row['project_path'] not in changed:assert sha(src)==row['sha256'],str(src)
    dst=P/row['project_path'];dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
    sources[row['project_path']]=sha(dst)
(R/'source_snapshot.json').write_text(json.dumps(sources,indent=2))
def verify_sources():
    assert all(sha(P/n)==h for n,h in sources.items()),'Sources changed during build'
def run(out,settings=None,flow=None,tcl=None):
    out.mkdir(parents=True)
    subprocess.run([sys.executable,str(P/'build/_mk_prj2.py'),str(out)],check=True)
    if settings is not None:(out/'settings.cfg').write_text(settings)
    (out/'local_flow.tcl').write_text(tcl if tcl is not None else flow)
    shutil.copy2(P/'build/run_flow.tcl',out/'driver.tcl')
    env=dict(os.environ,TD_FLOW_SCRIPT=str(out/'local_flow.tcl'))
    with (out/'flow_stdout.txt').open('w',encoding='utf-8') as log:
        p=subprocess.run(['D:/TD3/bin/td_commands_prompt.exe','driver.tcl'],cwd=out,env=env,stdout=log,stderr=subprocess.STDOUT)
    log=(out/'flow_stdout.txt').read_text(errors='replace')
    assert p.returncode==0 and 'TD_FLOW_FINISHED'in log and not re.search(r'\bERROR:|TD_FLOW_FAILED',log),str(out)
    verify_sources()
    return log
syn=P/f'td_project/{stem}_Runs/syn_r2'
phy=P/f'td_project/{stem}_Runs/phy_r2_seed26'
flow=(P/'build/phy_stage_flow.tcl').read_text()
print('Fresh synthesis from frozen sources',flush=True)
run(syn,(P/'build/settings_syn_1.cfg').read_text(),flow)
gate=syn/(stem+'_gate.db');assert gate.exists()
gate_hash=sha(gate)
area=(syn/(stem+'_gate.area')).read_text()
assert 'u_carousel_status' in area,'Mailbox missing from synthesized hierarchy'
(R/'synthesis_binding.json').write_text(json.dumps(dict(source_sha256=sources,gate_sha256=gate_hash,gate_path=str(gate)),indent=2))
print('New gate DB has u_carousel_status; starting physical with explicit absolute DB path',flush=True)
settings=(P/'build/settings_phy_1.cfg').read_text()
settings=re.sub(r'^set parent .*$', 'set parent {'+syn.as_posix()+'}',settings,flags=re.M)
assert f'set parent {{{syn.as_posix()}}}'in settings
flow=flow.replace('set_param place effort high','set_param place effort high\n  set_param flow enable_seed on\n  set_param place seed 26')
assert flow.count('set_param place seed 26')==1
log=run(phy,settings,flow)
assert f'import_db {syn.as_posix()}/{stem}_gate.db'in log,'Unexpected synthesis DB consumed'
assert sha(gate)==gate_hash
bit=phy/(stem+'.bit');db=phy/(stem+'_pr.db')
print('Physical ended; independent fresh-process STA now',flush=True)
fresh=R/'reports/fresh_sta'
tcl=f'''import_device eagle_s20.db -package EG4S20BG256
open_project {stem}.prj -noanalyze
import_db {{{db.as_posix()}}}
clear_sdc -user
read_sdc {{{(P/'user_source/constraints_source/timing.sdc').as_posix()}}}
update_timing -mode final
report_route_status -drc -file route_drc.txt
report_timing_summary -file fresh_pr.timing
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
report_qor -step route -file route.qor
'''
before={str(p):sha(p) for p in (bit,db)}
run(fresh,tcl=tcl)
assert before=={str(p):sha(p) for p in (bit,db)}
sys.path.insert(0,str(G/'tools'))
from audit_clock_scope import audit_clock_scope
expected=json.loads((G/'releases/v186/evidence/timing.json').read_text())['clock_audit']['clocks_mhz']
t=(fresh/'fresh_pr.timing').read_text();q=(fresh/'route.qor').read_text()
audit=audit_clock_scope(t,expected)
metric=lambda n:float(re.search(r'\|\s*'+re.escape(n)+r'\s*\|\s*(-?[\d.]+)',q)[1])
metrics={n:metric(n)for n in ['Setup WNS','Setup TNS','Num of violated S-EP','Hold WNS','Hold TNS','Num of violated H-EP','#slices','#RAMs','#DSPs']}
ignored=(fresh/'ignored.txt').read_text().split('Async/Exclusive Summary',1)[1].split('SFP Summary',1)[0]
hdmi_ok='video_clk -> hdmi_5x_clk'in t and not re.search(r'^\s*(?:video_clk\s*->\s*hdmi_5x_clk|hdmi_5x_clk\s*->\s*video_clk)\s*$',ignored,re.M)
checks=dict(clock_audit=audit['passed'],hdmi_sync_paths_present=hdmi_ok,setup_pass=metrics['Setup WNS']>=0,hold_pass=metrics['Hold WNS']>=0,zero_violations=metrics['Num of violated S-EP']==metrics['Num of violated H-EP']==0)
result=dict(passed=all(checks.values()),checks=checks,metrics_ps=metrics,clock_audit=audit,bit_path=str(bit),bit_sha256=sha(bit),source_sha256=sources,gate_sha256=gate_hash,db_sha256=sha(db),board_confirmed=False)
(R/'reports/result.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items()if k!='source_sha256'},indent=2),flush=True)
