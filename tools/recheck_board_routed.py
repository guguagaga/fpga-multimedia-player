"""Reopen a new routed database with its original constraints before first STA."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, datetime, sys
from audit_clock_scope import audit_clock_scope

a = argparse.ArgumentParser()
a.add_argument('root', type=Path)
a.add_argument('--seed', type=int, default=18)
a.add_argument('--td-command', required=True, help='Installed td_commands_prompt.exe path')
args = a.parse_args()
root = args.root.resolve()
project = root / 'candidate/project'
run = project / f'td_project/HDMI1.4b_Transmitter_v1.0_Runs/phy_cjk_align_seed{args.seed}'
out = root / f'reports/fresh_routed_seed{args.seed}'
if out.exists():
    out = out.with_name(out.name + '_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
out.mkdir(exist_ok=False)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
db = run / 'HDMI1.4b_Transmitter_v1.0_pr.db'
bit = run / 'HDMI1.4b_Transmitter_v1.0.bit'
before = {str(p): sha(p) for p in [db, bit]}
syn = json.loads((root / 'candidate/reports/cjk_align_synthesis.json').read_text(encoding='utf-8-sig'))
assert all(sha(project / n) == h for n, h in syn['sources'].items())
reference = root / 'tools/v167_clock_reference.json'
if not reference.exists(): reference = root / 'baseline/reports/acceptance_phy_cjk_align_seed18.json'
baseline = json.loads(reference.read_text())
sdc = project / 'user_source/constraints_source/timing.sdc'
policy = json.loads((root / 'CONSTRAINT_POLICY.json').read_text())
assert policy['original_sdc_sha256'] == baseline['constraint_sha256']
assert sha(sdc) == policy['candidate_sdc_sha256']
assert all(sha(project / n) == h for n, h in policy['rtl_sha256'].items())
assert sha(project / 'user_source/hdl_source/ip/sys_pll.v') == baseline['source_sha256']['user_source/hdl_source/ip/sys_pll.v']
subprocess.run([sys.executable, str(project / 'build/_mk_prj2.py'), str(out)], check=True)
tcl = f'''import_device eagle_s20.db -package EG4S20BG256
open_project HDMI1.4b_Transmitter_v1.0.prj -noanalyze
import_db {{{db.as_posix()}}}
clear_sdc -user
read_sdc {{{sdc.as_posix()}}}
update_timing -mode final
report_route_status -drc -file route_drc.txt
report_timing_summary -file fresh_pr.timing
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
report_qor -step route -file route.qor
'''
(out / 'check.tcl').write_text(tcl)
subprocess.run(['cmd.exe', '/d', '/c', str(project / 'build/_flow_run.cmd'), str(out), 'check.tcl', args.td_command], check=True)
assert before == {str(p): sha(p) for p in [db, bit]}
log = (out / 'flow_stdout.txt').read_text(errors='replace')
assert 'FLOW_EXIT=0' in log and not re.search(r'\bERROR:|TD_FLOW_FAILED', log)
assert 'No multi-drive.' in log and 'No abnormal timing path.' in log
start = log.index('start command "report_route_status')
end = log.index('start command "report_timing_summary', start)
(out / 'route_drc_excerpt.txt').write_text(log[start:end])
t = (out / 'fresh_pr.timing').read_text()
q = (out / 'route.qor').read_text()
assert policy['expected_new_path_group'] in t
ignored = (out / 'ignored.txt').read_text()
async_summary = ignored.split('Async/Exclusive Summary', 1)[1].split('SFP Summary', 1)[0]
assert not re.search(r'^\s*video_clk\s*->\s*hdmi_5x_clk\s*$', async_summary, re.M)
assert not re.search(r'^\s*hdmi_5x_clk\s*->\s*video_clk\s*$', async_summary, re.M)
metric = lambda n: float(re.search(r'\|\s*' + re.escape(n) + r'\s*\|\s*(-?[\d.]+)', q)[1])
metrics = {n: metric(n) for n in ['Setup WNS', 'Setup TNS', 'Num of violated S-EP', 'Hold WNS', 'Hold TNS', 'Num of violated H-EP', '#slices', '#RAMs', '#DSPs']}
for kind, wns, tns in [('Setup', 'SWNS', 'STNS'), ('Hold', 'HWNS', 'HTNS')]:
    assert metrics[kind + ' WNS'] >= 0 and metrics[kind + ' TNS'] == 0
    assert metrics['Num of violated ' + kind[0] + '-EP'] == 0
    match = re.search(wns + r':\s*(-?[\d.]+)ns, ' + tns + r':\s*(-?[\d.]+)ns', t)
    assert abs(float(match[1]) * 1000 - metrics[kind + ' WNS']) < .01 and float(match[2]) == 0
assert 'Confidence          : Routed' in t and 'Check Corner        : Both (Slow and Fast)' in t
audit = audit_clock_scope(t, baseline['clock_audit']['clocks_mhz'])
review_path = root / 'reports/coverage_review.json'
if not audit['checks'].get('coverage_not_reduced') and review_path.exists():
    # A smaller netlist changes the percentage denominator. Require a separate
    # detailed, hashed baseline/candidate category audit; never lower the
    # threshold silently or accept missing clocks on the strength of WNS.
    review = json.loads(review_path.read_text())
    assert review['passed'] and all(review['checks'].values())
    assert review['source_sha256'] == syn['sources']
    assert all(sha(Path(p)) == h for p, h in review['files_sha256'].items())
    coverage = float(re.search(r'STA coverage\s*:\s*([\d.]+)%', t)[1])
    assert coverage == review['candidate_coverage_percent']
    audit['original_coverage_threshold_passed'] = audit['checks'].pop('coverage_not_reduced')
    audit['checks']['coverage_scope_independently_reviewed'] = True
    audit['coverage_review_sha256'] = sha(review_path)
    audit['coverage_percent'] = coverage
    audit['passed'] = all(audit['checks'].values())
assert audit['passed'], audit
assert all(sha(project / n) == h for n, h in syn['sources'].items())
result = dict(passed=True, seed=args.seed, metrics_ps=metrics, clock_audit=audit,
              bit_sha256=sha(bit), db_sha256=sha(db), source_sha256=syn['sources'],
              files_sha256={str(p): sha(p) for p in out.iterdir() if p.is_file()},
              rtl_change=policy.get('rtl_change'),
              scope='Fresh-process final routed STA; reviewed stronger HDMI clock constraints and documented image-fit pipeline change. PLL unchanged. Route DRC output requires inspection. External IO/CDC and physical board acceptance remain separate.')
(root / f'reports/fresh_routed_seed{args.seed}.json').write_text(json.dumps(result, indent=2))
print('PASS fresh final routed setup/hold', json.dumps(metrics))
