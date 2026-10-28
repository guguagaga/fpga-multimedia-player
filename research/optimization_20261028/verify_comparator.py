from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--iverilog',default='iverilog');p.add_argument('--vvp',default='vvp');a=p.parse_args()
r=Path(a.repo).resolve();here=Path(__file__).resolve().parent
s=(r/'rtl/image/bmp_read.v').read_text(encoding='utf-8');tb=(here/'v118/verification/comparator/tb.v').read_text()
def fn(s):
 start=s.index('function lt_u32;');return s[start:s.index('endfunction',start)+len('endfunction')]
assert fn(s)==fn(tb),'Apply the v118 patch on an isolated checkout first'
out=r/'generated/optimization_20261028';out.mkdir(parents=True,exist_ok=True);exe=out/'comparator.vvp'
subprocess.run([a.iverilog,'-g2012','-s','tb','-o',str(exe),str(here/'v118/verification/comparator/tb.v')],check=True)
c=subprocess.run([a.vvp,str(exe)],capture_output=True,text=True);print(c.stdout);assert c.returncode==0 and 'PASS COMPARATOR' in c.stdout
