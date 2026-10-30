"""Encode the matching PCM companion to IMA and verify decoded sample count."""
from pathlib import Path
import argparse,hashlib,json,os,struct,subprocess,wave
a=argparse.ArgumentParser(description=__doc__)
a.add_argument('--pcm',type=Path,required=True);a.add_argument('--video',type=Path,required=True);a.add_argument('--output',type=Path,required=True)
args=a.parse_args();R=Path(__file__).resolve().parent;out=args.output.resolve()
if out.drive.upper()!='D:':raise ValueError('Project outputs must be on D:')
if out.exists():raise FileExistsError(out)
with args.video.open('rb')as f:h=f.read(512)
assert h[:6]==b'FPGV\x01\x0e' and h[20:24]==b'H6D1'
fps=struct.unpack_from('<H',h,10)[0];count=struct.unpack_from('<I',h,16)[0]
expected=count*48000//fps
with wave.open(str(args.pcm))as w:assert (w.getnchannels(),w.getsampwidth(),w.getframerate(),w.getnframes())==(1,2,48000,expected)
tmp=out.with_suffix('.verify.wav');report=out.with_suffix('.json')
for p in (tmp,report):
 if p.exists():raise FileExistsError(p)
(R/'tmp').mkdir(exist_ok=True);os.environ.update(TEMP=str(R/'tmp'),TMP=str(R/'tmp'))
xq=R/'adpcm-xq.exe'
subprocess.run([str(xq),'-8','-b10','-n',str(args.pcm.resolve()),str(out)],check=True)
subprocess.run([str(xq),'-d','-q',str(out),str(tmp)],check=True)
with wave.open(str(tmp))as w:assert (w.getnchannels(),w.getsampwidth(),w.getframerate(),w.getnframes())==(1,2,48000,expected)
def sha(p):
 with p.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()
report.write_text(json.dumps(dict(passed=True,video_sha256=sha(args.video),pcm_sha256=sha(args.pcm),audio_sha256=sha(out),frames=count,fps=fps,samples=expected,seconds=count/fps,ima_bytes=out.stat().st_size,scope='Lossy IMA-XQ; independent decoded sample count checked. Listen against PCM. No SD modification.'),indent=2))
print('Verified companion:',out)
