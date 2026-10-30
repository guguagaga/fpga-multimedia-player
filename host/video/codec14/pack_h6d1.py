"""Losslessly recode packed Codec12 into experimental H6D1. Requires new RTL."""
from pathlib import Path
import argparse,hashlib,json,mmap,struct,sys,time
from codec14_transforms import transform
from lossless_codec12 import Codec,contexts
R=Path(__file__).resolve().parent
sys.path.insert(0,str(Path(__file__).resolve().parent))
from repack_codec12_stream import unpack_frame

def main():
 a=argparse.ArgumentParser(description=__doc__);a.add_argument('--input',type=Path,required=True);a.add_argument('--output',type=Path,required=True);args=a.parse_args()
 output=args.output.resolve();report_path=output.with_suffix('.json');partial=output.with_suffix('.partial')
 for p in (output,report_path,partial):
  if p.exists():raise FileExistsError(p)
 choice=next(x for x in json.loads((R/'index_residual.json').read_text())['results']if x['color']=='last_word'and x['index']=='vertical')
 lengths=bytes(v for row in choice['lengths']for v in row);codec=Codec(lengths)
 rows=[];tokens=hashlib.sha256();inverse=hashlib.sha256();started=time.time()
 with args.input.open('rb')as inp,mmap.mmap(inp.fileno(),0,access=mmap.ACCESS_READ)as data,partial.open('xb+')as out:
  header=bytearray(data[:512]);assert header[:6]==b'FPGV\x01\x0c'
  width,height,fps,size,count=struct.unpack_from('<HHHII',header,6)
  assert (width,height)==(1280,720)and fps in (15,20,25,30)and 512<size<=len(data)and 0<=len(data)-size<512 and not any(data[size:])
  header[5]=14;header[20:24]=b'H6D1';out.write(header);pos=512
  for i in range(count):
   _,end=unpack_frame(data,pos,size);raw=bytes(data[pos:end])
   if any(c==0 and op==134 for c,op in contexts(raw)):
    raise ValueError('Gradient blocks are disabled in the production RTL; use the validated production mode mask15')
   packed=codec.encode(transform(raw));restored=transform(codec.decode(packed),True)
   assert restored==raw;tokens.update(raw);inverse.update(restored);out.write(packed)
   rows.append(dict(frame=i,original=len(raw),compressed=len(packed)));pos=end
  assert pos==size
  declared=out.tell();assert declared<2**32;out.write(bytes(-declared%512));out.seek(12);out.write(struct.pack('<I',declared))
 # Reopen bytes from disk, checking each encoded frame against independently
 # restored token hashes. This catches write/truncation mistakes as well.
 disk_digest=hashlib.sha256()
 with partial.open('rb')as f:
  check=f.read(512);assert check[5]==14 and check[20:24]==b'H6D1'
  for row in rows:disk_digest.update(transform(codec.decode(f.read(row['compressed'])),True))
  assert not any(f.read())
 assert disk_digest.digest()==tokens.digest()==inverse.digest()
 partial.rename(output)
 with args.input.open('rb')as f:input_sha=hashlib.file_digest(f,'sha256').hexdigest()
 with output.open('rb')as f:output_sha=hashlib.file_digest(f,'sha256').hexdigest()
 report=dict(passed=True,input=str(args.input.resolve()),output=str(output),fps=fps,frames=count,duration_seconds=count/fps,original_payload=sum(x['original']for x in rows),compressed_payload=declared-512,mean_bytes_per_frame=(declared-512)/count,max_frame_bytes=max(x['compressed']for x in rows),mean_video_plus_pcm_bytes_s=(declared-512)/count*fps+96000,input_sha256=input_sha,output_sha256=output_sha,restored_tokens_sha256=disk_digest.hexdigest(),lengths_sha256=hashlib.sha256(lengths).hexdigest(),seconds=time.time()-started,rows=rows,scope='Exact original Codec12 token reconstruction, independent disk reread. No new spatial loss. Experimental H6D1 requires matching frozen-table RTL; not v183 compatible. No board qualification implied.')
 report_path.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items()if k!='rows'},indent=2))

if __name__=='__main__':main()
