"""Offline candidate cost survey on deterministically sampled RAW blocks."""
from pathlib import Path
import argparse,struct,hashlib,json,time,collections,math,statistics
from experimental_raw_bounds import encode,decode
p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('--report',type=Path,required=True);a=p.parse_args();t=time.time();b=a.input.read_bytes()
assert b[:6]==b'FPGV\1\x0a';w,h,fps=struct.unpack_from('<HHH',b,6);declared,frames=struct.unpack_from('<II',b,12);pos=512;raw_count=0;sample=[];payload={128:2,129:12,131:128,132:8}
for fi in range(frames):
 k=0
 while k<w*h//64:
  op=b[pos];pos+=1
  if op==133:k+=b[pos]+1;pos+=3;continue
  if op==131:
   # Fixed stride with a nonzero offset, applied to every RAW block in
   # stream order. Includes the entire film; not only the opening scene.
   if raw_count%601==317:sample.append((fi,pos))
   raw_count+=1
  pos+=payload[op];k+=1
 assert b[pos]==255;pos+=1
assert pos==declared
hist=collections.Counter();costs={x:[]for x in ['exact_palette4','channel_bounds8x8','subquad_palette2','channel_bounds4x4','best_new_combined']};beneficial=collections.Counter();frames_sampled=set();roundtrip_bytes=0
for fi,offset in sample:
 px=struct.unpack_from('<64H',b,offset);frames_sampled.add(fi);unique=len(set(px));hist[unique]+=1
 # All candidates are exact relative to decoded RGB565 RAW. Costs include
 # their hypothetical opcode and metadata. No decoder is implemented.
 pal4=25 if unique<=4 else 129
 def bounds(v):
  channels=[[x>>11 for x in v],[(x>>5)&63 for x in v],[x&31 for x in v]]
  bits=sum((max(c)-min(c)).bit_length()for c in channels)
  return 4+math.ceil(len(v)*bits/8) # RGB565 minimum2+bit widths2
 global_bound=min(129,1+bounds(px))
 quads=[tuple(px[(qy*4+y)*8+qx*4+x]for y in range(4)for x in range(4))for qy in range(2)for qx in range(2)]
 qpal=min(129,2+sum(2 if len(set(q))==1 else 6 if len(set(q))<=2 else 32 for q in quads))
 qbound=min(129,2+sum(min(32,bounds(q))for q in quads))
 packet=encode(px);assert len(packet)==qbound and decode(packet)==px;roundtrip_bytes+=len(packet)
 measured=dict(exact_palette4=pal4,channel_bounds8x8=global_bound,subquad_palette2=qpal,channel_bounds4x4=qbound,best_new_combined=min(pal4,global_bound,qpal,qbound))
 for name,cost in measured.items():costs[name].append(cost);beneficial[name]+=cost<129
results={}
for name,v in costs.items():
 results[name]=dict(sample_blocks=len(v),beneficial_blocks=beneficial[name],beneficial_fraction=beneficial[name]/len(v),mean_bytes=statistics.mean(v),min_bytes=min(v),saved_bytes_in_sample=129*len(v)-sum(v),fraction_of_raw_bytes_saved=1-sum(v)/(129*len(v)))
out=dict(passed=True,scope='Offline exact RGB565 RAW cost estimates.4x4 channel-bounds candidate implemented and byte-packed/decoded for every sampled block; all other candidate costs are hypothetical. Deterministic stride sample; not full-film encode, not perceptual-quality metric, not RTL/timing. best_combined optimistic lower envelope.',sha256=hashlib.sha256(b).hexdigest(),fullfilm_frames=frames,total_raw_blocks=raw_count,sample_stride=601,sample_offset=317,sample_blocks=len(sample),sample_roundtrip_pixels=len(sample)*64,sample_encoded_bytes=roundtrip_bytes,distinct_frames_sampled=len(frames_sampled),unique_colors_histogram=hist,candidates=results,seconds=time.time()-t)
a.report.write_text(json.dumps(out,indent=2),encoding='utf-8');print(json.dumps(out,indent=2))
