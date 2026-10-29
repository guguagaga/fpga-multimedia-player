"""Lossless solid-run packing for experimental format12. No production files are edited."""
from pathlib import Path
import struct,argparse,json,hashlib

SIZES={0x80:3,0x81:13,0x83:129,0x84:9,0x86:9,0x87:6,0x88:25}
def frames(data):
 if len(data)<512 or data[:6]!=b'FPGV\x01\x0c':raise ValueError('Expected experimental format12 header')
 end=struct.unpack_from('<I',data,12)[0];count=struct.unpack_from('<I',data,16)[0]
 if not 512<=end<=len(data) or any(data[end:]):raise ValueError('Invalid declared length/padding')
 pos=512;out=[]
 for fi in range(count):
  tokens=[]
  while pos<end and data[pos]!=255:
   op=data[pos]
   if op==0x85:
    if pos+4>end:raise ValueError('Truncated run')
    tokens.extend([bytes([0x80])+data[pos+2:pos+4]]*(data[pos+1]+1));pos+=4
   elif op in SIZES:
    size=SIZES[op]
    if pos+size>end:raise ValueError('Truncated token')
    tokens.append(data[pos:pos+size]);pos+=size
   else:raise ValueError('Unknown opcode')
   if len(tokens)>14400:raise ValueError('Too many blocks')
  if len(tokens)!=14400 or pos>=end or data[pos]!=255:raise ValueError('Incomplete frame')
  pos+=1;out.append(tokens)
 if pos!=end:raise ValueError('Extra data')
 return out

def repack(src,dst):
 data=Path(src).read_bytes();original=frames(data);out=bytearray(data[:512]);sizes=[]
 for tokens in original:
  begin=len(out);i=0
  while i<len(tokens):
   token=tokens[i];n=1
   if token[0]==0x80:
    while n<256 and i+n<len(tokens) and tokens[i+n]==token:n+=1
   if n>1:out.extend(bytes([0x85,n-1])+token[1:])
   else:out.extend(token)
   i+=n
  out.append(255);sizes.append(len(out)-begin)
 struct.pack_into('<I',out,12,len(out));declared=len(out);out.extend(bytes((-len(out))%512))
 assert frames(out)==original,'Canonical mismatch'
 Path(dst).write_bytes(out)
 return dict(passed=True,input_bytes=len(data),output_bytes=len(out),input_declared=struct.unpack_from('<I',data,12)[0],output_declared=declared,frame_bytes=sizes,sha256=hashlib.sha256(out).hexdigest(),scope='Exact block-token canonical equivalence including all modes; changes only solid runs, length and sector padding')

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('source');p.add_argument('destination');a=p.parse_args();print(json.dumps(repack(a.source,a.destination),indent=2))
