from pathlib import Path
import os,subprocess,json,hashlib,time
R=Path(__file__).resolve().parents[1];D=R/'tests/byte_ram';D.mkdir(exist_ok=True)
files=[R/'tests/tb_byte_ram.v',R/'candidate/project/rtl/video_byte_ram.v',Path(os.environ['TD_SIM_EG4'])/'eg_phy_bram32k.v',Path(os.environ['TD_SIM_EG4'])/'eg_phy_glbl.v']
snapshot={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files};t=time.time()
(D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.resolve().as_posix()+'}'for f in files)+'\nvsim work.tb work.glbl\nrun -all\nquit -code 0\n')
with(D/'console.log').open('w')as log:c=subprocess.run([str(Path(os.environ['MODELSIM_BIN'])/'vsim.exe'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=c.returncode==0 and 'PASS byte RAM'in out
(R/'reports/byte_ram.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,source_sha256=snapshot,summary=out[-2500:]),indent=2))
print(out[-2500:]);assert ok
