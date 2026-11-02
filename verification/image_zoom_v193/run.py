"""Run zoom regressions. All generated files go under --output.
Fast suite requires Icarus Verilog; --full-chain also requires ModelSim and TD vendor RAM models.
"""
from pathlib import Path
import argparse,subprocess,os,json,shutil
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path)
p.add_argument('--iverilog',default='iverilog');p.add_argument('--vvp',default='vvp')
p.add_argument('--case',action='append',choices=['control','races','pixels','timer/timeline','timer/presets','timer/edges']);p.add_argument('--full-chain',action='store_true');p.add_argument('--vsim',default='vsim');p.add_argument('--vendor-sim',type=Path)
a=p.parse_args();T=Path(__file__).resolve().parent;G=T.parent.parent;O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
image=G/'rtl/image';results=[]
def run_case(name,cmd,cwd):
 log=cwd/'console.log'
 with log.open('w') as f:ret=subprocess.run(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT).returncode
 txt=log.read_text(errors='replace');ok=ret==0 and 'PASS' in txt and '** Fatal' not in txt and '** Error' not in txt
 results.append({'case':name,'passed':ok});print(results[-1],flush=True)
for case in ['control','races','pixels','timer/timeline','timer/presets','timer/edges']:
 if a.case and case not in a.case:continue
 d=O/case;d.mkdir(parents=True,exist_ok=True)
 if case.startswith('timer/'):
  tb=T/(case+'.v');files=[tb,T/'timer/models.v',image/'sd_card_bmp.v',G/'rtl/control/carousel_period_cfg.v']
 elif case=='pixels':files=[T/'pixels/tb.v',image/'img_scaler.v']
 else:files=[T/case/'tb.v',T/'control/models.v',image/'sd_card_bmp.v']
 sim=d/'sim.vvp'
 subprocess.run([a.iverilog,'-g2012','-s','tb','-o',str(sim)]+[str(f)for f in files],cwd=d,check=True)
 run_case(case,[a.vvp,str(sim)],d)
if a.full_chain:
 if a.vendor_sim is None:p.error('--full-chain requires --vendor-sim pointing to TD sim_release/eg4')
 for name,kind in [('qoi',1),('bmp',0)]:
  d=O/'chain'/name;d.mkdir(parents=True,exist_ok=True)
  shutil.copy2(T/'chain'/name/'header.hex',d/'header.hex')
  def q(path):return '{'+path.resolve().as_posix()+'}'
  files=[T/'chain'/name/'tb.v',image/'sd_card_bmp.v',image/'bmp_read.v',image/'img_scaler.v',a.vendor_sim/'eg_phy_bram32k.v',a.vendor_sim/'eg_phy_glbl.v']
  body='onerror {quit -code 1}\nvlib work\n'
  body+='vlog '+q(G/'rtl/image/qoi_stream.v')+' '+q(a.vendor_sim/'eg_logic_dram.v')+'\n'
  body+='vlog -sv '+' '.join(q(f)for f in files)+'\n'
  body+='vlog '+q(G/'rtl/storage/sd_arbiter.v')+'\n'
  # Source dimensions are encoded in the saved per-format header.
  hdr=bytes(int(x,16)for x in (d/'header.hex').read_text().split())
  w=int.from_bytes(hdr[4:8],'big') if kind else int.from_bytes(hdr[18:22],'little')
  h=int.from_bytes(hdr[8:12],'big') if kind else abs(int.from_bytes(hdr[22:26],'little',signed=True))
  body+=f'vsim -gEARLY=0 work.tb work.glbl +W={w} +H={h} +KIND={kind}\nrun -all\nquit -code 0\n'
  (d/'run.do').write_text(body)
  run_case('chain/'+name,[a.vsim,'-c','-do','run.do'],d)
(O/'result.json').write_text(json.dumps({'passed':all(x['passed']for x in results),'cases':results},indent=2))
raise SystemExit(0 if all(x['passed']for x in results)else 1)
