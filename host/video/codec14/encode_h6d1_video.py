"""Encode a 720P video with the production spatial budget and H6D1 tables."""
from pathlib import Path
import argparse,concurrent.futures,hashlib,json,os,struct,subprocess,sys,time,wave
from decimal import Decimal
a=argparse.ArgumentParser(description="H6D1 720P encoder, fixed 125000-byte spatial budget; use the matching RTL and code tables.")
a.add_argument('--ffmpeg',type=Path,required=True)
a.add_argument('--fps',type=int,choices=[20,30],required=True)
duration_group=a.add_mutually_exclusive_group(required=True)
duration_group.add_argument('--seconds',type=Decimal)
duration_group.add_argument('--frames',type=int)
a.add_argument('--start',type=Decimal,default=Decimal(0))
a.add_argument('--video',type=Path,required=True)
a.add_argument('--audio',type=Path,required=True)
a.add_argument('--output',type=Path,required=True)
args=a.parse_args();fps=args.fps
assert args.start>=0
if args.frames is not None:
 assert args.frames>0
 count=args.frames
else:
 assert args.seconds>0
 exact_count=args.seconds*fps
 assert exact_count==int(exact_count), 'Duration must contain an integer number of target frames'
 count=int(exact_count)
args.seconds=Decimal(count)/fps
samples=count*48000//fps
assert args.video.is_file() and args.audio.is_file()
R=Path(__file__).resolve().parent;W=args.output.resolve()
assert W.drive.upper()=='D:', 'This project writes work and outputs to D: only'
W.mkdir(parents=True,exist_ok=False)
E=R;sys.path.insert(0,str(E))
from repack_codec12_stream import repack
FF=str(args.ffmpeg.resolve());assert args.ffmpeg.is_file();encoder=E/'encode_blocks_experimental.exe';raw=W/'source.rgb565';started=time.time()
(W/'tmp').mkdir(exist_ok=True)
os.environ.update(TEMP=str(W/'tmp'),TMP=str(W/'tmp'),PYTHONDONTWRITEBYTECODE='1')
command=[FF,'-nostdin','-hide_banner','-v','error','-threads','2','-ss',str(args.start),'-i',str(args.video),'-vf',f'fps={fps}:eof_action=pass,scale=1280:720:flags=lanczos','-fps_mode','passthrough','-frames:v',str(count),'-pix_fmt','rgb565le','-f','rawvideo','-n',str(raw)]
subprocess.run(command,check=True);frame_bytes=1843200;assert raw.stat().st_size==count*frame_bytes
workers=min(4,count);bounds=[count*i//workers for i in range(workers+1)]
def encode(i):
 first,last=bounds[i:i+2];p=W/f'part{i}.C12'
 with raw.open('rb')as inp,(W/f'part{i}.log').open('wb')as log:
  child=subprocess.Popen([str(encoder),str(p),'500','8000','125000','15'],stdin=subprocess.PIPE,stderr=log)
  try:
   inp.seek(first*frame_bytes)
   for _ in range(last-first):
    data=inp.read(frame_bytes);assert len(data)==frame_bytes;child.stdin.write(data)
   child.stdin.close();assert child.wait()==0
  finally:
   if child.poll()is None:child.terminate();child.wait()
 with p.open('rb')as f:h=f.read(512)
 length,count=struct.unpack_from('<II',h,12);assert count==last-first
 return dict(index=i,first=first,last=last,length=length)
with concurrent.futures.ThreadPoolExecutor(max_workers=workers)as pool:parts=list(pool.map(encode,range(workers)))
merged=W/'original.C12';packed=W/'original.VID'
with(W/'part0.C12').open('rb')as f:header=bytearray(f.read(512))
length=512+sum(p['length']-512 for p in parts);struct.pack_into('<HII',header,10,fps,length,count)
with merged.open('xb')as out:
 out.write(header)
 for row in parts:
  with(W/f'part{row["index"]}.C12').open('rb')as inp:
   inp.seek(512);out.write(inp.read(row['length']-512))
 out.write(bytes(-length%512))
repack(merged,packed)
subprocess.run([sys.executable,'-X','utf8',str(R/'pack_h6d1.py'),'--input',str(packed),'--output',str(W/f'EXPERIMENTAL_720P{fps}.VID')],check=True)
audio=W/'EXPERIMENTAL_AUDIO.VAU'
subprocess.run([FF,'-nostdin','-hide_banner','-v','error','-ss',str(args.start),'-i',str(args.audio),'-vn','-ac','1','-ar','48000','-af',f'aresample=48000,apad,atrim=end_sample={samples}','-c:a','pcm_s16le','-f','wav',str(audio)],check=True)
with wave.open(str(audio))as w:assert (w.getnchannels(),w.getsampwidth(),w.getframerate(),w.getnframes())==(1,2,48000,samples)
(W/'preparation.json').write_text(json.dumps(dict(fps=fps,frames=count,seconds=float(args.seconds),source_start=float(args.start),encoding_seconds=time.time()-started,parts=parts,command=command,spatial_budget=125000,mode_mask=15,scope='New target-fps frames from original video, same production quantizer, exact H6D1 recoding. Research media only, not copied to SD.'),indent=2))
print('PASS true',fps,'fps H6D1 file',W,flush=True)
