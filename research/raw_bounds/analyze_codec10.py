"""Structural full-film rate analysis; no decoding, no SD/media mutation."""
from pathlib import Path
import argparse,struct,json,hashlib,time,statistics,math
p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('--report',type=Path,required=True);a=p.parse_args();start=time.time()
b=a.input.read_bytes();assert b[:6]==b'FPGV\1\x0a'
w,h,fps=struct.unpack_from('<HHH',b,6);declared,nframes=struct.unpack_from('<II',b,12);blocks=w*h//64
assert w%8==h%8==0 and fps and nframes and 512<declared<=len(b) and len(b)%512==0 and len(b)-declared<512
assert not any(b[declared:]);payload={128:2,129:12,131:128,132:8};pos=512;rows=[];totals={op:dict(tokens=0,blocks=0,bytes=0)for op in [128,129,131,132,133]};runs={}
for fi in range(nframes):
 begin=pos;k=0;counts={op:0 for op in totals};encoded={op:0 for op in totals};run_saved=0
 while k<blocks:
  assert pos<declared;op=b[pos];pos+=1
  if op==133:
   assert pos+3<=declared;count=b[pos]+1;pos+=3;cost=4;runs[count]=runs.get(count,0)+1;run_saved+=3*count-cost
  else:assert op in payload;count=1;cost=1+payload[op];pos+=payload[op]
  assert pos<=declared and k+count<=blocks,(fi,pos,k,op)
  k+=count;counts[op]+=count;encoded[op]+=cost;totals[op]['tokens']+=1;totals[op]['blocks']+=count;totals[op]['bytes']+=cost
 assert b[pos]==255;pos+=1
 rows.append(dict(frame=fi,seconds=fi/fps,bytes=pos-begin,c9_equivalent_bytes=pos-begin+run_saved,blocks=counts,encoded_bytes=encoded))
assert pos==declared
sizes=sorted(r['bytes']for r in rows)
percentile=lambda q:sizes[min(len(sizes)-1,math.ceil(q*len(sizes))-1)]
windows=[]
for n in [1,3,15,60]:
 if n>nframes:continue
 value=sum(r['bytes']for r in rows[:n]);best=value;idx=0
 for i in range(n,nframes):
  value+=rows[i]['bytes']-rows[i-n]['bytes']
  if value>best:best=value;idx=i-n+1
 windows.append(dict(frames=n,start_frame=idx,time_seconds=idx/fps,total_bytes=best,average_bytes_per_frame=best/n,payload_bytes_per_second=best*fps/n))
total_payload=declared-512;c9_payload=sum(r['c9_equivalent_bytes']for r in rows);duration=nframes/fps
physical=[]
for spc in [1,2,4,8,16,32,64,128]:
 batch=min(spc,16)
 # This simple model assumes sector-aligned full batches and one FAT
 # sector per cluster, no cursor-cache reuse. It is not measured latency.
 media_sectors=total_payload/512
 physical.append(dict(sectors_per_cluster=spc,max_cmd18_sectors=batch,video_batches_per_second=media_sectors/duration/batch,upper_model_fat_sectors_per_second=media_sectors/duration/spc))
names={128:'SOLID',129:'PAL2',131:'RAW',132:'QUAD4',133:'SOLID_RUN'}
for op,v in totals.items():v.update(name=names[op],pixel_fraction=v['blocks']/(nframes*blocks),payload_byte_fraction=v['bytes']/total_payload)
audio=[]
for label,rate in [('PCM mono48k',96000),('IMA-XQ mono48k',10163260/422)]:
 # 25MHz SPI raw ceiling is3.125MB/s. Payload alone excludes command,
 # token, CRC, FAT reads, arbitration and decoder/writer backpressure.
 payload_rate=total_payload/duration+rate
 audio.append(dict(audio=label,audio_bytes_per_second=rate,total_media_payload_bytes_per_second=payload_rate,fraction_of_spi25_raw_ceiling=payload_rate/3125000))
out=dict(passed=True,scope='Full Codec10 structural parsing, mode/run statistics and simplified bandwidth accounting only. No pixel-quality metric, no RTL timing/board/endurance claim. FAT transaction estimates are models, not measured.',sha256=hashlib.sha256(b).hexdigest(),width=w,height=h,fps=fps,frames=nframes,duration_seconds=duration,file_bytes=len(b),declared_bytes=declared,payload_bytes=total_payload,c9_equivalent_payload_bytes=c9_payload,lossless_repack_saved_bytes=c9_payload-total_payload,lossless_repack_saved_fraction=1-total_payload/c9_payload,frame_bytes=dict(min=sizes[0],mean=statistics.mean(sizes),p50=percentile(.5),p90=percentile(.9),p95=percentile(.95),p99=percentile(.99),max=sizes[-1]),modes=totals,run_lengths=runs,heaviest_windows=windows,audio_payload_models=audio,cluster_models=physical,seconds=time.time()-start)
a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(json.dumps(out,indent=2),encoding='utf-8');print(json.dumps(out,indent=2))
