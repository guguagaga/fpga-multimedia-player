from pathlib import Path
import os,subprocess,json,hashlib,time
R=Path(__file__).resolve().parents[1];P=R/'candidate/project';H=P/'user_source/hdl_source';D=R/'tests'/('packed_'+str(int(time.time())));D.mkdir(exist_ok=False)
files=[R/'tests/tb_packed_frame.v',P/'rtl/rgb565_pair_pack.v']+[H/n for n in ['SD/frame_read_write.v','SD/frame_fifo_write.v','SD/frame_fifo_read.v','ip/afifo_16_32_256.v','ip/afifo_32_16_256.v']]
snapshot={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
s='onerror {quit -code 1}\nvlib work\nvlog -sv '+ ' '.join('{'+f.resolve().as_posix()+'}'for f in files)+'\nvsim work.tb_packed_frame\nrun -all\nquit -code 0\n'
(D/'run.do').write_text(s);t=time.time()
with(D/'console.log').open('w')as log:p=subprocess.run([str(Path(os.environ['MODELSIM_BIN'])/'vsim.exe'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=p.returncode==0 and 'PASS packed three-buffer'in out and not any(x in out for x in ['** Error','** Fatal','FATAL:'])
assert snapshot=={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
(R/'reports/packed_frame.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,source_sha256=snapshot,summary=out[-6000:]),indent=2))
print(out[-6000:]);assert ok
