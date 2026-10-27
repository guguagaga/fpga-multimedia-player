"""Offline exact repacking survey; no playable movie or SD writes.

Every existing RAW block is actually packed, decoded, and compared. Other
tokens remain unchanged. Payload sizes describe a proposed, unsupported
format; they do not measure FPGA throughput or original-source quality.
"""
from pathlib import Path
import argparse, struct, json, hashlib, time, statistics
from experimental_raw_bounds import encode, decode

p=argparse.ArgumentParser();p.add_argument('input',type=Path)
p.add_argument('--report',type=Path,required=True);a=p.parse_args()
start=time.time();b=a.input.read_bytes();assert b[:6]==b'FPGV\1\x0a'
w,h,fps=struct.unpack_from('<HHH',b,6);declared,frames=struct.unpack_from('<II',b,12)
pos=512;rows=[];raw=0;changed=0;saved=0;hist={};payload={128:2,129:12,131:128,132:8}
for fi in range(frames):
 begin=pos;k=0;fsaved=0;fraw=0
 while k<w*h//64:
  op=b[pos];pos+=1
  if op==133:k+=b[pos]+1;pos+=3;continue
  assert op in payload
  if op==131:
   px=struct.unpack_from('<64H',b,pos);packet=encode(px)
   assert decode(packet)==px,(fi,k)
   delta=129-len(packet);assert delta>=0
   raw+=1;fraw+=1;changed+=delta>0;saved+=delta;fsaved+=delta
   hist[len(packet)]=hist.get(len(packet),0)+1
  pos+=payload[op];k+=1
 assert b[pos]==255;pos+=1
 rows.append(dict(frame=fi,original_bytes=pos-begin,candidate_bytes=pos-begin-fsaved,raw_blocks=fraw,saved_bytes=fsaved))
 if fi%100==0:print(f'frame={fi}/{frames} raw={raw} saved={saved} elapsed={time.time()-start:.1f}s',flush=True)
assert pos==declared
def summary(key):
 sizes=sorted(r[key]for r in rows)
 return dict(mean=statistics.mean(sizes),p99=sizes[(99*len(sizes)+99)//100-1],max=sizes[-1])
windows=[]
for count in [1,3,15,60]:
 for key in ['original_bytes','candidate_bytes']:
  value=sum(r[key]for r in rows[:count]);best=value;idx=0
  for i in range(count,frames):
   value+=rows[i][key]-rows[i-count][key]
   if value>best:best=value;idx=i-count+1
  windows.append(dict(frames=count,encoding=key,start_frame=idx,total_bytes=best,payload_bytes_per_second=best*fps/count))
out=dict(passed=True,scope='Full-film existing RAW blocks actually packed and decoded pixel-exactly; all other tokens unchanged in size accounting. Offline proposed opcode0x86 only: productionRTL rejects it. No playable candidate movie, hardware decoder, original-source quality improvement or throughput/STA claim.',input_sha256=hashlib.sha256(b).hexdigest(),frames=frames,width=w,height=h,fps=fps,raw_blocks=raw,roundtrip_pixels=raw*64,beneficial_blocks=changed,raw_bytes_saved=saved,raw_saving_fraction=saved/(raw*129),full_payload_saving_fraction=saved/(declared-512),original_payload_bytes=declared-512,candidate_payload_bytes=declared-512-saved,packet_length_histogram=hist,original_frame_bytes=summary('original_bytes'),candidate_frame_bytes=summary('candidate_bytes'),heaviest_windows=windows,per_frame=rows,seconds=time.time()-start)
a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(out,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in out.items()if k!='per_frame'},indent=2))
