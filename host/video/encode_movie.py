"""Pipe original video to native 720p encoder, canonical-repack and verify."""
from pathlib import Path
import argparse,subprocess,json,time,hashlib,sys
R=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--seconds',type=float);p.add_argument('--budget',type=int,default=145000);p.add_argument('--output',type=Path,required=True)
p.add_argument('--input',type=Path,required=True)
p.add_argument('--ffmpeg',default='ffmpeg')
p.add_argument('--repacker',type=Path,default=R/'repack_codec10.exe');a=p.parse_args()
D=a.output;D.mkdir(parents=True,exist_ok=True);t=time.time()
src=a.input
ff=[a.ffmpeg,'-hide_banner','-loglevel','error','-threads','2','-i',str(src)]
if a.seconds:ff+=['-t',str(a.seconds)]
ff+=['-vf','scale=1280:720:flags=lanczos,fps=15','-pix_fmt','rgb565le','-f','rawvideo','pipe:1']
c9=D/'VIDEO720_C9.VID';c10=D/'VIDEO720.VID';enc=R/'encode_720p.exe'
assert not c9.exists() and not c10.exists(),'Refuse overwriting encoded output'
with (D/'ffmpeg.log').open('w') as fe,(D/'encode.log').open('w')as ee:
 f=subprocess.Popen(ff,stdout=subprocess.PIPE,stderr=fe)
 try:
  e=subprocess.Popen([str(enc),str(c9),'500','8000',str(a.budget),'1'],stdin=f.stdout,stderr=ee)
  f.stdout.close();ec=e.wait();fc=f.wait()
 finally:
  if f.poll()is None:f.terminate()
 assert ec==fc==0,(ec,fc)
pack=str(a.repacker)
subprocess.run([pack,'encode',str(c9),str(c10)],check=True)
verified=json.loads(subprocess.check_output([pack,'verify',str(c9),str(c10)]));assert verified['passed']
sys.path.insert(0,str(R));from codec_tools import validate
v=validate(c9,a.budget);v.pop('frame_offsets')
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
report=dict(passed=True,seconds=time.time()-t,scope='Full token parsing, canonical C9/C10 block equivalence; not RTL full-film/board endurance.',source_path=str(src),source_sha256=sha(src),encoder_sha256=sha(enc),budget=a.budget,c9=v,c10=verified,c10_sha256=sha(c10))
(D/'encoding_validation.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
