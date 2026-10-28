from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser();p.add_argument('--variant',choices=['v115','v116','v117'],required=True);p.add_argument('--repo',required=True);p.add_argument('--iverilog',default='iverilog');p.add_argument('--vvp',default='vvp');a=p.parse_args()
here=Path(__file__).resolve().parent;r=Path(a.repo).resolve();out=r/'generated/optimization_20261028';out.mkdir(parents=True,exist_ok=True)
for name,rel,top,marker in [('expand','rtl/image/img_scaler.v','tb_expand','PASS EXPAND EQUIVALENCE'),('spectrum','rtl/spectrum/spectrum_display.v','tb','PASS SPECTRUM EQUIVALENCE')]:
 fixture=here/(a.variant if (here/a.variant/'verification'/name).exists()else 'v115')/'verification'/name
 exe=out/(name+'.vvp');files=[fixture/'tb.v',fixture/'reference.v',r/rel]
 subprocess.run([a.iverilog,'-g2012','-s',top,'-o',str(exe),*map(str,files)],check=True)
 c=subprocess.run([a.vvp,str(exe)],capture_output=True,text=True);print(c.stdout);assert c.returncode==0 and marker in c.stdout
