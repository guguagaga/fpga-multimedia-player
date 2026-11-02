"""Run from verification/carousel_timer_v190 after packaging.

Requires Icarus Verilog on PATH, or IVERILOG/VVP environment overrides.
Writes only under the explicitly supplied output directory.
"""
from pathlib import Path
import argparse,os,subprocess,json
a=argparse.ArgumentParser();a.add_argument('--output',type=Path,required=True);args=a.parse_args()
T=Path(__file__).resolve().parent;G=T.parent.parent;O=args.output.resolve();O.mkdir(parents=True,exist_ok=True)
results=[]
for name,tb in [('timeline',T/'tb.v'),('presets',T/'presets/tb.v'),('edges',T/'edges/tb.v')]:
 sim=O/(name+'.vvp')
 subprocess.run([os.getenv('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(sim),str(tb),str(T/'models.v'),str(G/'rtl/image/sd_card_bmp.v'),str(G/'rtl/control/carousel_period_cfg.v')],check=True)
 p=subprocess.run([os.getenv('VVP','vvp'),str(sim)],capture_output=True,text=True)
 (O/(name+'.log')).write_text(p.stdout+p.stderr,encoding='utf-8')
 results.append({'case':name,'passed':p.returncode==0});print(results[-1],flush=True)
(O/'result.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
raise SystemExit(0 if all(x['passed']for x in results)else 1)
