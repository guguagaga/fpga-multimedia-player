from pathlib import Path
import argparse, os, shutil, concurrent.futures, hashlib, json, re, subprocess, time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description='Pin-level SD CMD17/CMD18 regression')
parser.add_argument('--modelsim-dir', type=Path, default=os.environ.get('MODELSIM_BIN'))
options = parser.parse_args()
ms = options.modelsim_dir
if ms is None:
    found = shutil.which('vsim.exe')
    if found: ms = Path(found).parent
if ms is None: parser.error('Supply --modelsim-dir or set MODELSIM_BIN')
ms = ms.resolve()
for executable in ('vsim.exe','vlog.exe','vlib.exe'):
    if not (ms / executable).is_file(): parser.error('Missing executable: ' + str(ms / executable))
sd = root/'candidate/project/user_source/hdl_source/SD'
report = root/'fpga/reports/sd_speed'
report.mkdir(parents=True, exist_ok=True)
snap = {str(p.relative_to(root/'candidate/project')): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (root/'candidate/project').rglob('*') if p.is_file() and '_Runs' not in str(p)
        and p.suffix.lower() in ('.v', '.sdc', '.adc', '.al', '.mem', '.hex')}

def run_variant(legacy):
    name = 'baseline' if legacy else 'fixed'
    lib = root/'fpga/sim_runs'/('sd_speed_'+name)
    lib.parent.mkdir(parents=True, exist_ok=True)
    sources = [root/'fpga/sim/sd_spi_model.sv', root/'fpga/sim/tb_sd_speed.sv',
               sd/'sd_card_top.v', sd/'sd_card_sec_read_write.v', sd/'spi_master.v',
               sd/'spi_sniffer.v', root/'candidate/project/user_source/hdl_source/sd_arbiter.v',
               root/'reference/sd_card_cmd_v18.v' if legacy else sd/'sd_card_cmd.v']
    logs=[]
    for args in [[ms/'vlib.exe', lib], [ms/'vlog.exe', '-sv', '-work', lib, *sources]]:
        p=subprocess.run(list(map(str,args)), cwd=root/'fpga/sim', capture_output=True, text=True, errors='replace')
        logs.append(p.stdout+p.stderr)
        if p.returncode:
            (report/(name+'_compile.log')).write_text('\n'.join(logs),encoding='utf-8')
            raise RuntimeError('\n'.join(logs)[-6000:])
    (report/(name+'_compile.log')).write_text('\n'.join(logs),encoding='utf-8')
    results=[]
    for top,marker in [('tb_sd_speed','PASS SD speed regression'),('tb_sd_cmd_tail','PASS command-tail regression')]:
        started=time.time()
        args=[ms/'vsim.exe','-c','-lib',lib,'-l',report/(name+'_'+top+'.log'),'-gLEGACY='+str(legacy),top,
              '-do','onerror {quit -f -code 1}; run -all; quit -f -code 0']
        p=subprocess.run(list(map(str,args)),cwd=root/'fpga/sim',capture_output=True,text=True,errors='replace',timeout=300)
        output=p.stdout+p.stderr
        (report/(name+'_'+top+'_console.txt')).write_text(output,encoding='utf-8')
        passed=p.returncode==0 and marker in output and not re.search(r'\*\* (?:Error|Fatal)|FATAL',output)
        result={'variant':name,'test':top,'passed':passed,'seconds':round(time.time()-started,2)}
        results.append(result)
        print(json.dumps(result),flush=True)
        print('\n'.join(l for l in output.splitlines() if 'PASS ' in l or 'MEASURE ' in l),flush=True)
        if not passed: print(output[-6000:],flush=True)
    return results

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=[r for group in pool.map(run_variant,[1,0]) for r in group]
measure={}
for name in ['baseline','fixed']:
    text=(report/(name+'_tb_sd_speed_console.txt')).read_text(encoding='utf-8')
    measure[name]={int(d):{'cycles':int(c),'spi_bytes':int(b)} for d,c,b in
                   re.findall(r'MEASURE legacy=\d+ token_delay=(\d+) cycles=(\d+) spi_bytes=(\d+)',text)}
comparison=[]
for delay,base in measure['baseline'].items():
    fixed=measure['fixed'][delay]
    comparison.append({'token_delay_bytes':delay,'baseline':base,'fixed':fixed,
                       'speedup':base['cycles']/fixed['cycles'],
                       'saved_us_at_100MHz':(base['cycles']-fixed['cycles'])/100})
unchanged=all(hashlib.sha256((root/'candidate/project'/k).read_bytes()).hexdigest()==v for k,v in snap.items())
result={'passed':all(r['passed'] for r in results) and unchanged,'source_unchanged':unchanged,
        'results':results,'sector_comparison':comparison,'sources':snap,
        'scope':'Pin-level SPI model, actual arbiter + sector + command + SPI RTL. Synthetic token latency; not board timing.'}
(report/'validation.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps({'passed':result['passed'],'sector_comparison':comparison},indent=2),flush=True)
raise SystemExit(not result['passed'])
