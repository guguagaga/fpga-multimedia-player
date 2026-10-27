from pathlib import Path
import os,subprocess,time,json,hashlib
R=Path(__file__).resolve().parents[1];files=[R/'tests/tb_image_center.v',R/'candidate/project/rtl/image_center_720p.v'];exe=R/'tests/image_center.vvp';t=time.time()
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb_image_center','-o',str(exe),*[str(f)for f in files]],capture_output=True,text=True);assert c.returncode==0,c.stderr
c=subprocess.run([os.environ.get('VVP','vvp'),str(exe)],capture_output=True,text=True);out=c.stdout+c.stderr;ok=c.returncode==0 and 'PASS720 image centering'in out
(R/'reports/image_center.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files},output=out),indent=2));print(out);assert ok
