from pathlib import Path
import os,subprocess,hashlib,time,json
R=Path(__file__).resolve().parents[1];H=R/'candidate/project/user_source/hdl_source'
D=R/'tests/display';D.mkdir(exist_ok=True)
files=[R/'tests/tb_display720.v',H/'SD/video_timing_gen.v',H/'video_coord.v',H/'video_rgb_to_axis_640x480.v']
snapshot={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files};t=time.time()
subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'sim.vvp'),*[str(p)for p in files]],check=True)
result=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp')],capture_output=True,text=True)
out=result.stdout+result.stderr;(D/'console.log').write_text(out)
ok=result.returncode==0 and 'PASS display720'in out
(R/'reports/display.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,source_sha256=snapshot,scope='Four complete raster frames through production timing generator, coordinates and AXI bridge. Not TMDS electrical/monitor lock.',summary=out),indent=2))
print(out);assert ok
