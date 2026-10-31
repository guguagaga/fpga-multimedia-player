from pathlib import Path
import struct,subprocess,os,json,time
R=Path('D:/codexworks/image_prefetch_v188/fixed_qoi');S=R/'tests/full_chain_v4_early1';T=R/'tests/bmp_two_frames';T.mkdir(exist_ok=False)
s=(S/'tb.v').read_text().replace('if(shown_count==3)begin','if(shown_count==2)begin').replace('if(load_count!=3 || frames!=3)','if(load_count!=2 || frames!=2)')
(T/'tb.v').write_text(s)
w,h=320,240;stride=w*3;hdr=bytearray(512);hdr[:2]=b'BM';struct.pack_into('<I',hdr,2,54+stride*h);struct.pack_into('<I',hdr,10,54);struct.pack_into('<IiiHHIIiiII',hdr,14,40,w,h,1,24,0,stride*h,0,0,0,0)
(T/'header.hex').write_text('\n'.join(f'{x:02x}'for x in hdr)+'\n')
script=(S/'run.do').read_text().replace(S.as_posix(),T.as_posix()).replace('+KIND=1','+KIND=0');(T/'run.do').write_text(script)
start=time.time()
with(T/'console.log').open('w')as f:a=subprocess.run(['E:/modelsim/modelsim_ase/win32aloem/vsim.exe','-c','-do','run.do'],cwd=T,env=dict(os.environ,TEMP=str(R/'tmp'),TMP=str(R/'tmp')),stdout=f,stderr=subprocess.STDOUT,timeout=1800)
log=(T/'console.log').read_text(errors='replace');ok=a.returncode==0 and 'PASS EARLY='in log and '** Fatal'not in log and '** Error'not in log
result=dict(passed=ok,seconds=time.time()-start,events=[x for x in log.splitlines()if 'EVENT 'in x or 'PASS EARLY'in x]);(T/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True);assert ok
