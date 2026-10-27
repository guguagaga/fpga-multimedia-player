from pathlib import Path
import os,subprocess,json,hashlib,time
R=Path(__file__).resolve().parent;D=R/'tests';sources=[D/'tb_mapper.v',R/'candidate/project/rtl/fat32_sector_mapper.v'];t=time.time()
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'mapper.vvp'),*[str(f)for f in sources]],capture_output=True,text=True);assert c.returncode==0,c.stderr
c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'mapper.vvp')],capture_output=True,text=True,timeout=120)
out=c.stdout+c.stderr;(R/'reports/mapper.log').write_text(out);print(out,flush=True)
ok=c.returncode==0 and 'PASS FAT mapper'in out
(R/'reports/mapper.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,output=out,source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in sources}),indent=2));assert ok
