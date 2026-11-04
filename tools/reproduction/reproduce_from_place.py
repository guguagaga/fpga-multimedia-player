"""Route the packaged placement checkpoint and independently verify final STA."""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--project-root', type=Path, required=True)
p.add_argument('--td-command', type=Path, required=True)
p.add_argument('--prepare-only', action='store_true')
a = p.parse_args()
root = a.project_root.resolve()
td = a.td_command.resolve()
if not str(root).isascii() or not str(td).isascii():
    p.error('TD requires an ASCII project and tool path for this workflow.')
if root.drive.upper() != 'D:':
    p.error('Extract the project to D: for this workflow.')
if not td.is_file():
    p.error('TD executable does not exist.')
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
manifest = json.loads((root / 'SOURCE_FILES_SHA256.json').read_text(encoding='utf-8'))
for name, expected in manifest.items():
    if sha(root / name) != expected:
        raise RuntimeError('Packaged input changed: ' + name)
subprocess.run([sys.executable, str(root / 'tools/verify_release.py')], check=True)
project = root / 'src'
stem = 'HDMI1.4b_Transmitter_v1.0'
run = project / 'td_project' / (stem + '_Runs') / (
    'reproduce_place_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
run.mkdir(parents=True, exist_ok=False)
subprocess.run([sys.executable, str(project / 'build/_mk_prj2.py'), str(run)], check=True)
checkpoint = root / 'implementation_checkpoint'
for name, expected in json.loads((checkpoint / 'SHA256.json').read_text()).items():
    if sha(checkpoint / name) != expected:
        raise RuntimeError('Checkpoint mismatch: ' + name)
shutil.copy2(checkpoint / (stem + '_place.db'), run / (stem + '_place.db'))
settings = (project / 'build/settings_phy_1.cfg').read_text()
if settings.count('set start_step opt_place') != 1:
    raise RuntimeError('Unexpected physical settings template')
(run / 'settings.cfg').write_text(settings.replace(
    'set start_step opt_place', 'set start_step opt_route'), encoding='utf-8')
flow = (project / 'build/phy_stage_flow.tcl').read_text(encoding='utf-8')
if flow.count('  route\n') != 1:
    raise RuntimeError('Unexpected routing flow template')
flow = flow.replace('  route\n', '  restore_production_sdc\n'
                   '  read_sdc ../../../build/optimization_margin.sdc\n  route\n')
(run / 'local_flow.tcl').write_text(flow, encoding='utf-8')
inputs = dict(start_step='opt_route', end_step='bitgen',
              source_manifest_sha256=sha(root / 'SOURCE_FILES_SHA256.json'),
              place_db_sha256=sha(run / (stem + '_place.db')),
              production_sdc_sha256=sha(project / 'user_source/constraints_source/timing.sdc'),
              flow_sha256=sha(run / 'local_flow.tcl'),
              settings_sha256=sha(run / 'settings.cfg'),
              optimization_margin=(project / 'build/optimization_margin.sdc').read_text(),
              rtl_modified=False, td_command=str(td))
(run / 'reproduction_inputs.json').write_text(json.dumps(inputs, indent=2), encoding='utf-8')
print('Prepared:', run, flush=True)
if a.prepare_only:
    raise SystemExit(0)
shutil.copy2(project / 'build/run_flow.tcl', run / '.td_flow_driver.tcl')
temp = root / 'build_workspace/tmp'
temp.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TD_FLOW_SCRIPT='local_flow.tcl', TEMP=str(temp), TMP=str(temp),
           PYTHONUTF8='1', PYTHONDONTWRITEBYTECODE='1')
with (run / 'flow_stdout.txt').open('wb') as log:
    subprocess.run([str(td), '.td_flow_driver.tcl'], cwd=run, env=env,
                   stdout=log, stderr=subprocess.STDOUT, check=True)
log = (run / 'flow_stdout.txt').read_text(errors='replace')
if 'TD_FLOW_FINISHED' not in log or 'TD_FLOW_FAILED' in log or 'ERROR:' in log:
    raise RuntimeError('Routing failed; inspect ' + str(run / 'flow_stdout.txt'))
checker = Path(__file__).resolve().with_name('verify_new_route.py')
subprocess.run([sys.executable, str(checker), str(root), str(run),
                '--td-command', str(td)], env=env, check=True)
print('PASS: independent production-constraint check. Reports:', run / 'independent_check')
