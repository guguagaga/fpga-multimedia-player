from pathlib import Path
import os,subprocess,json,hashlib,time
R=Path(__file__).resolve().parents[1];D=R/'tests/timeline';D.mkdir(exist_ok=True)
template=R/'tests/templates/av_timeline.v'
if not template.exists():
 s=(R.parent/'image_fast_v19_validation/tests/tb_av_sample_sync.v').read_text()
 s=s.replace('av_sample_sync dut(', 'av_sample_sync #(.LEAD_SAMPLES(1920)) dut(')
 s=s.replace('(consumed+960)/p','(consumed+((p>1920)?1920:p-240))/p')
 template.write_text(s)
files=[template,R/'candidate/project/rtl/av_sample_sync.v'];snapshot={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}
subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb_av_sample_sync','-o',str(D/'sim.vvp'),*[str(f)for f in files]],check=True)
t=time.time();results=[]
for period,frames in [(2400,100),(1920,100),(1600,100),(3200,12660)]:
 with(D/f'p{period}.log').open('w')as log:c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp'),f'+PERIOD={period}',f'+FRAMES={frames}'],stdout=log,stderr=subprocess.STDOUT)
 out=(D/f'p{period}.log').read_text();print(out,flush=True);assert c.returncode==0 and 'PASS'in out
 results.append(dict(period=period,frames=frames,summary=out))
(R/'reports/long_timeline.json').write_text(json.dumps(dict(passed=True,seconds=time.time()-t,source_sha256=snapshot,scope='Actual sample budget RTL; 12660 frame grants = 844s of 15fps media timeline, randomized stalls and repeated pauses. 20/25/30fps header-period compatibility also checked. Accelerated sample requests; not full-film decoder or board endurance.',results=results),indent=2))
