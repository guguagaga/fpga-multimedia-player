"""Independently check a freshly routed result against the packaged baseline."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('root', type=Path)
p.add_argument('run', type=Path)
p.add_argument('--td-command', required=True)
a = p.parse_args()
root, run = a.root.resolve(), a.run.resolve()
project = root / 'src'
stem = 'HDMI1.4b_Transmitter_v1.0'
out = run / 'independent_check'
out.mkdir(exist_ok=False)
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
db, bit = run / (stem + '_pr.db'), run / (stem + '.bit')
before = {f.name: sha(f) for f in [db, bit]}
manifest = json.loads((root / 'SOURCE_FILES_SHA256.json').read_text(encoding='utf-8'))
for name, h in manifest.items():
    assert sha(root / name) == h, name
baseline = json.loads((root / 'evidence/implementation/timing.json').read_text())
sdc = project / 'user_source/constraints_source/timing.sdc'
subprocess.run([sys.executable, str(project / 'build/_mk_prj2.py'), str(out)], check=True)
tcl = f'''import_device eagle_s20.db -package EG4S20BG256
open_project {stem}.prj -noanalyze
import_db {{{db.as_posix()}}}
clear_sdc -user
read_sdc {{{sdc.as_posix()}}}
update_timing -mode final
report_route_status -drc -file route_drc.txt
report_timing_summary -file fresh_pr.timing
report_timing_ignored -ep_num 10000 -path_num 1 -file ignored.txt
report_qor -step route -file route.qor
puts "INDEPENDENT_REPRODUCTION_CHECK_FINISHED"
exit 0
'''
(out / 'check.tcl').write_text(tcl, encoding='utf-8')
with (out / 'run.log').open('wb') as log:
    subprocess.run([a.td_command, 'check.tcl'], cwd=out, stdout=log,
                   stderr=subprocess.STDOUT, check=True)
log = (out / 'run.log').read_text(errors='replace')
assert 'INDEPENDENT_REPRODUCTION_CHECK_FINISHED' in log
assert not re.search(r'\bERROR:|TD_FLOW_FAILED', log)
assert 'No multi-drive.' in log and 'No abnormal timing path.' in log
t = (out / 'fresh_pr.timing').read_text()
q = (out / 'route.qor').read_text()
metric = lambda n: float(re.search(r'\|\s*' + re.escape(n) + r'\s*\|\s*(-?[\d.]+)', q)[1])
metrics = {n: metric(n) for n in ['Setup WNS', 'Setup TNS', 'Num of violated S-EP',
                                 'Hold WNS', 'Hold TNS', 'Num of violated H-EP']}
sys.path.insert(0, str(root / 'tools'))
from audit_clock_scope import audit_clock_scope
audit = audit_clock_scope(t, baseline['clock_audit']['clocks_mhz'])
coverage = float(re.search(r'STA coverage\s*:\s*([\d.]+)%', t)[1])
policy = json.loads((root / 'docs/CONSTRAINT_POLICY.json').read_text())
assert sha(sdc) == policy['candidate_sdc_sha256']
assert policy['expected_new_path_group'] in t
ignored = (out / 'ignored.txt').read_text()
async_summary = ignored.split('Async/Exclusive Summary', 1)[1].split('SFP Summary', 1)[0]
assert not re.search(r'^\s*video_clk\s*->\s*hdmi_5x_clk\s*$', async_summary, re.M)
assert not re.search(r'^\s*hdmi_5x_clk\s*->\s*video_clk\s*$', async_summary, re.M)
assert 'Confidence          : Routed' in t
assert 'Check Corner        : Both (Slow and Fast)' in t
assert before == {f.name: sha(f) for f in [db, bit]}
checks = dict(clock_audit=audit['passed'], coverage=coverage >= 96.36,
              setup=metrics['Setup WNS'] >= 0, hold=metrics['Hold WNS'] >= 0,
              zero_violations=all(metrics[n] == 0 for n in ['Setup TNS', 'Hold TNS',
                                         'Num of violated S-EP', 'Num of violated H-EP']))
released_bytes = (root / 'bitstream/FPGA_MULTIMEDIA_PLAYER.bit').read_bytes()
new_bytes = bit.read_bytes()
date_pattern = rb'(?m)^# Date: [^\r\n]*\r?\n'
date_lines_present = len(re.findall(date_pattern, released_bytes)) == len(re.findall(date_pattern, new_bytes)) == 1
same_except_date = date_lines_present and re.sub(date_pattern, b'', released_bytes) == re.sub(date_pattern, b'', new_bytes)
result = dict(passed=all(checks.values()), checks=checks, metrics_ps=metrics,
              coverage_percent=coverage, clock_audit=audit,
              source_files_verified=len(manifest), output_sha256=before,
              bit_identical_to_released=sha(bit) == sha(root / 'bitstream/FPGA_MULTIMEDIA_PLAYER.bit'),
              bit_bytes_identical_except_date_line=same_except_date,
              sdc_sha256=sha(sdc), report_dir=str(out))
(out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps(result, indent=2))
if not result['passed']:
    raise SystemExit(1)
