"""Final signoff is separate from implementation; never trust single DeriveClock QoR."""
from pathlib import Path
import argparse,hashlib,json,re,sys
a=argparse.ArgumentParser();a.add_argument('root',type=Path);a.add_argument('--fresh',default='fresh_sta');a.add_argument('--physical',default='phy_r3_seed24');o=a.parse_args()
R=o.root;P=R/'candidate/project';F=R/'reports'/o.fresh
G=Path('D:/codexworks/release_v182_20261029/repository');stem='HDMI1.4b_Transmitter_v1.0'
V=P/f'td_project/{stem}_Runs'/o.physical
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
binding=json.loads((R/'synthesis_binding.json').read_text())
sources=binding['source_sha256'];assert all(sha(P/n)==h for n,h in sources.items())
gate=Path(binding['gate_path']);assert sha(gate)==binding['gate_sha256']
phylog=(V/'flow_stdout.txt').read_text();assert 'import_db '+gate.as_posix() in phylog
assert 'TD_FLOW_FINISHED'in phylog and not re.search(r'\bERROR:|TD_FLOW_FAILED',phylog)
base=Path('D:/codexworks/osd_carousel_v187/rebuild_r2/reports/coverage_v186_reference')
def categories(f):
 t=f.read_text();t=t[t.index('1. checking nets with no clock driven.'):]
 return {re.match(r'(\d+)\.',s)[1]:re.sub(r'\s+',' ',s).strip() for s in re.split(r'(?m)(?=^\d+\. checking )',t) if s.strip()}
bs,cs=categories(base/'coverage.txt'),categories(F/'coverage.txt')
coverage_checks={f'category_{n}_unchanged':bs[n]==cs[n] for n in bs if n!='3'}
families=lambda x:sorted(set(re.findall(r'DummyNode in Model: (\w+)',x)))
coverage_checks['dummy_families_unchanged']=families(bs['3'])==families(cs['3'])
groups=lambda f:sorted(set(re.findall(r'^\w+ -> \w+$',f.read_text(),re.M)))
coverage_checks['async_groups_unchanged']=groups(base/'ignored.txt')==groups(F/'ignored.txt')
t=(F/'fresh_pr.timing').read_text();q=(F/'route.qor').read_text();log=(F/'flow_stdout.txt').read_text()
sys.path.insert(0,str(G/'tools'));from audit_clock_scope import audit_clock_scope
reference=json.loads((G/'releases/v186/evidence/timing.json').read_text())
audit=audit_clock_scope(t,reference['clock_audit']['clocks_mhz'])
audit['original_coverage_threshold_passed']=audit['checks'].pop('coverage_not_reduced')
audit['checks']['coverage_detail_compared_to_v186']=all(coverage_checks.values())
audit['passed']=all(audit['checks'].values())
metric=lambda n:float(re.search(r'\|\s*'+re.escape(n)+r'\s*\|\s*(-?[\d.]+)',q)[1])
metrics={n:metric(n)for n in ['Setup WNS','Setup TNS','Num of violated S-EP','Hold WNS','Hold TNS','Num of violated H-EP','#slices','#RAMs','#DSPs']}
ignored=(F/'ignored.txt').read_text().split('Async/Exclusive Summary',1)[1].split('SFP Summary',1)[0]
checks=dict(source_binding=True,gate_binding=True,clock_scope=audit['passed'],setup=metrics['Setup WNS']>=0 and metrics['Setup TNS']==0 and metrics['Num of violated S-EP']==0,hold=metrics['Hold WNS']>=0 and metrics['Hold TNS']==0 and metrics['Num of violated H-EP']==0,hdmi_path='video_clk -> hdmi_5x_clk'in t and not re.search(r'^\s*(?:video_clk\s*->\s*hdmi_5x_clk|hdmi_5x_clk\s*->\s*video_clk)\s*$',ignored,re.M),routed_both_corners='Confidence          : Routed'in t and 'Check Corner        : Both (Slow and Fast)'in t,no_multidrive='No multi-drive.'in log,no_abnormal_paths='No abnormal timing path.'in log)
for kind,wns,tns in [('Setup','SWNS','STNS'),('Hold','HWNS','HTNS')]:
 m=re.search(wns+r':\s*(-?[\d.]+)ns, '+tns+r':\s*(-?[\d.]+)ns',t)
 checks[kind+'_reports_agree']=abs(float(m[1])*1000-metrics[kind+' WNS'])<.01 and abs(float(m[2])*1000-metrics[kind+' TNS'])<.01
result=dict(passed=all(checks.values()),checks=checks,coverage_checks=coverage_checks,clock_audit=audit,metrics_ps=metrics,coverage_percent=float(re.search(r'STA coverage\s*:\s*([\d.]+)',t)[1]),source_sha256=sources,gate_sha256=sha(gate),db_sha256=sha(V/(stem+'_pr.db')),bit_sha256=sha(V/(stem+'.bit')),bit_path=str(V/(stem+'.bit')),physical_run=str(V),files_sha256={str(p):sha(p)for p in [F/'coverage.txt',F/'fresh_pr.timing',F/'ignored.txt',F/'route.qor',F/'flow_stdout.txt',V/'local_flow.tcl',V/'settings.cfg',V/'flow_stdout.txt',R/'synthesis_binding.json']},board_confirmed=False,scope='Independent production-SDC internal STA; existing external IO and CDC limitations remain. Physical board test is pending.')
(R/'reports'/('signoff_'+o.physical+'.json')).write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items() if k not in ('source_sha256','files_sha256')},indent=2))
sys.exit(0 if result['passed']else 2)
