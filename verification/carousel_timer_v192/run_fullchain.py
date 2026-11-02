"""Replay the packaged real-reader/scaler regressions using installed vendor models."""
from pathlib import Path
import argparse,os,json,shutil,subprocess
a=argparse.ArgumentParser()
a.add_argument('--output',type=Path,required=True)
a.add_argument('--modelsim',required=True,help='Path to vsim.exe')
a.add_argument('--td-root',type=Path,required=True,help='Tang Dynasty installation')
args=a.parse_args();T=Path(__file__).resolve().parent;G=T.parent.parent
O=args.output.resolve();O.mkdir(parents=True,exist_ok=True);(O/'tmp').mkdir(exist_ok=True)
manifest=json.loads((G/'project_manifest.json').read_text(encoding='utf-8'))
mapping={x['project_path']:G/x['public_path']for x in manifest['files']if not x['external']}
def path(name):
 p=mapping[name];assert p.is_file(),str(p);return '{'+p.as_posix()+'}'
ram=args.td_root/'sim_release/eg4';assert ram.is_dir()
results=[]
for case in ['qoi_three','bmp_two','qoi_restart/candidate_fixed']:
 D=O/case;D.mkdir(parents=True,exist_ok=False);shutil.copy2(T/case/'tb.v',D/'tb.v')
 full=case!='qoi_restart/candidate_fixed'
 lines=['onerror {quit -code 1}','vlib work','vlog '+path('user_source/hdl_source/qoi_stream.v')+' {'+(ram/'eg_logic_dram.v').as_posix()+'}']
 src=['user_source/hdl_source/SD/bmp_read.v']
 if full:src+=['user_source/hdl_source/SD/sd_card_bmp.v','rtl/img_scaler.v']
 lines+=['vlog -sv {'+(D/'tb.v').as_posix()+'} '+' '.join(path(n)for n in src)]
 if full:
  shutil.copy2(T/case/'header.hex',D/'header.hex')
  lines+=['vlog '+path('user_source/hdl_source/sd_arbiter.v'),
   'vlog -sv {'+(ram/'eg_phy_bram32k.v').as_posix()+'} {'+(ram/'eg_phy_glbl.v').as_posix()+'}',
   'vsim -gEARLY=0 work.tb work.glbl +W=320 +H=240 +KIND='+('1'if case=='qoi_three'else '0')]
 else:lines+=['vsim work.tb']
 lines+=['run -all','quit -code 0'];(D/'run.do').write_text('\n'.join(lines)+'\n')
 with(D/'console.log').open('w',encoding='utf-8')as f:
  p=subprocess.run([args.modelsim,'-c','-do','run.do'],cwd=D,env=dict(os.environ,TEMP=str(O/'tmp'),TMP=str(O/'tmp')),stdout=f,stderr=subprocess.STDOUT,timeout=1800)
 log=(D/'console.log').read_text(encoding='utf-8',errors='replace')
 ok=p.returncode==0 and ('PASS EARLY='if full else 'PASS5')in log and '** Fatal'not in log and '** Error'not in log
 results.append({'case':case,'passed':ok});print(results[-1],flush=True)
(O/'results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(0 if all(x['passed']for x in results)else 1)
