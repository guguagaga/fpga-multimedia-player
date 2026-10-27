"""Independent token parser/decoder; supports the deployed Codec8/Codec9 modes."""
from pathlib import Path
import struct,hashlib,argparse,json,math
PAYLOAD={128:2,129:12,131:128,132:8}
def validate(path,budget=55000,raw_output=None,start_frame=0,count=None):
 path=Path(path);b=path.read_bytes()
 if b[:5]!=b'FPGV\x01' or b[5] not in (8,9):raise ValueError('not FPGV v1 codec8/9')
 codec=b[5];w,h,fps=struct.unpack_from('<HHH',b,6);declared,frames=struct.unpack_from('<II',b,12)
 if (w,h) not in ((800,600),(1280,720)) or fps not in (15,20,25,30) or not frames or not 512<declared<=len(b):raise ValueError('unsupported geometry or bad file header')
 if len(b)%512 or len(b)-declared>511 or any(b[declared:]):raise ValueError('invalid sector padding')
 end=frames if count is None else start_frame+count
 if not 0<=start_frame<end<=frames:raise ValueError('bad frame range')
 f=Path(raw_output).open('wb') if raw_output else None
 pos=512;sizes=[];offsets=[512];tokens={k:0 for k in PAYLOAD}
 try:
  for fi in range(frames):
   begin=pos;frame=bytearray(w*h*2) if f and start_frame<=fi<end else None
   for k in range(w*h//64):
    if pos>=declared:raise ValueError('truncated token')
    t=b[pos];pos+=1
    if t not in PAYLOAD or (codec==8 and t==132):raise ValueError('invalid token %s frame %s'%(t,fi))
    n=PAYLOAD[t]
    if pos+n>declared:raise ValueError('truncated block')
    payload=b[pos:pos+n];pos+=n;tokens[t]+=1
    if frame is not None:
     if t==128:block=payload*64
     elif t==129:
      pal=[payload[:2],payload[2:4]];block=b''.join(pal[(payload[4+i//8]>>(i%8))&1] for i in range(64))
     elif t==132:
      pal=[payload[2*i:2*i+2] for i in range(4)];block=b''.join(pal[(y//4)*2+x//4] for y in range(8) for x in range(8))
     else:block=payload
     by,bx=divmod(k,w//8)
     for y in range(8):
      off=((by*8+y)*w+bx*8)*2;frame[off:off+16]=block[y*16:y*16+16]
   if pos>=declared or b[pos]!=255:raise ValueError('missing frame end')
   pos+=1;size=pos-begin
   if size>budget:raise ValueError('frame exceeds budget')
   sizes.append(size);offsets.append(pos)
   if frame is not None:f.write(frame)
  if pos!=declared:raise ValueError('frame_count/file_bytes mismatch')
 finally:
  if f:f.close()
 return dict(passed=True,file=str(path),codec=codec,width=w,height=h,fps=fps,frames=frames,duration_seconds=frames/fps,bytes=len(b),declared_bytes=declared,max_frame_bytes=max(sizes),token_counts=tokens,sha256=hashlib.sha256(b).hexdigest(),frame_offsets=offsets)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('movie',type=Path);p.add_argument('--budget',type=int,default=55000);p.add_argument('--raw-out',type=Path);p.add_argument('--start-frame',type=int,default=0);p.add_argument('--frames',type=int);p.add_argument('--report',type=Path);a=p.parse_args()
 r=validate(a.movie,a.budget,a.raw_out,a.start_frame,a.frames);r.pop('frame_offsets')
 if a.report:a.report.write_text(json.dumps(r,indent=2),encoding='utf-8')
 print(json.dumps(r,indent=2))
