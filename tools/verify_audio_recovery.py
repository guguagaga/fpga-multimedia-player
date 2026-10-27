from pathlib import Path
import argparse,subprocess,hashlib,json
p=argparse.ArgumentParser();p.add_argument('--iverilog',default='iverilog');p.add_argument('--vvp',default='vvp');a=p.parse_args()
r=Path(__file__).resolve().parents[1];d=r/'verification/audio_recovery';out=r/'generated/audio_recovery';out.mkdir(parents=True,exist_ok=True)
top=r/'rtl/top/top_tf_hdmi_audio.v';sector=r/'rtl/storage/sector_byte_source.v'
s=top.read_text(encoding='utf-8');i=s.index("vau_tgt  <= 1'b0;");begin=s.rfind('always @',0,i);end=s.index('\nend',i)+4;control=s[begin:end]
tb=(d/'tb_restart_template.v').read_text();i=tb.index("vau_tgt  <= 1'b0;");begin=tb.rfind('always @',0,i);end=tb.index('\nend',i)+4
(out/'tb_restart.v').write_text(tb[:begin]+control+tb[end:],encoding='utf-8')
results=[]
for name,files,marker in [('sector',[d/'tb_sector.v',sector],'PASS SECTOR RECOVERY'),('restart',[out/'tb_restart.v'],'PASS RESTART POLICY')]:
 exe=out/(name+'.vvp');subprocess.run([a.iverilog,'-g2012','-s','tb','-o',str(exe),*map(str,files)],check=True)
 c=subprocess.run([a.vvp,str(exe)],capture_output=True,text=True);print(c.stdout);assert c.returncode==0 and marker in c.stdout
 results.append(dict(name=name,passed=True))
(out/'result.json').write_text(json.dumps(dict(passed=True,results=results,source_sha256={str(f.relative_to(r)):hashlib.sha256(f.read_bytes()).hexdigest()for f in [top,sector]}),indent=2))
