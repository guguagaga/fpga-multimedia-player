"""Sample benchmark, original 1280x720 RGB565LE input. Requires numpy.
Use only controlled research inputs. The decoder is not a hardened media parser.
Each input must contain three frames. Outputs go into --output, not the repository.
"""
from pathlib import Path
import argparse,json,subprocess,struct,hashlib,math
import numpy as np
def rgb(raw):
 a=np.frombuffer(raw,dtype='<u2').reshape(-1,720,1280).astype(np.int32)
 r=(a>>11)&31;g=(a>>5)&63;b=a&31
 return np.stack(((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)),axis=-1).astype(np.float64)
def metrics(decoded,ref):
 residual=decoded-ref;mse=np.mean(residual**2)
 out={'mse':float(mse),'psnr':float(10*np.log10(255**2/mse))}
 for step in [4,8]:
  dx=residual[:,:,step::step]-residual[:,:,step-1:-1:step]
  dy=residual[:,step::step,:]-residual[:,step-1:-1:step,:]
  # Residual gradient counts both introduced seams and lost true edges.
  out[f'grid{step}_gradient_rmse']=float(np.sqrt((np.sum(dx**2)+np.sum(dy**2))/(dx.size+dy.size)))
 return out

def decode(path):
 data=path.read_bytes();assert data[:5]==b'FPGV\x01' and data[5] in (9,11);n=struct.unpack_from('<I',data,16)[0];pos=512;frames=[];counts={}
 yy,xx=np.indices((8,8));weights=np.stack(((8-xx)*(8-yy),xx*(8-yy),(8-xx)*yy,xx*yy),axis=-1)
 for fi in range(n):
  out=np.zeros((720,1280),dtype='<u2')
  for k in range(14400):
   op=data[pos];pos+=1;counts[op]=counts.get(op,0)+1
   size={128:2,129:12,131:128,132:8,134:8}[op];p=data[pos:pos+size];pos+=size
   if op==128:block=np.full((8,8),int.from_bytes(p,'little'),dtype='<u2')
   elif op==131:block=np.frombuffer(p,dtype='<u2').reshape(8,8)
   elif op==129:
    pal=np.frombuffer(p[:4],dtype='<u2');indices=(np.frombuffer(p[4:],dtype='u1')[:,None]>>np.arange(8))&1;block=pal[indices]
   elif op==132:block=np.frombuffer(p,dtype='<u2').reshape(2,2).repeat(4,0).repeat(4,1)
   else:
    pal=np.frombuffer(p,dtype='<u2').astype(np.int32);rr=(weights@(pal>>11)+32)>>6;gg=(weights@((pal>>5)&63)+32)>>6;bb=(weights@(pal&31)+32)>>6;block=(rr<<11)|(gg<<5)|bb
   by,bx=divmod(k,160);out[by*8:by*8+8,bx*8:bx*8+8]=block
  assert data[pos]==255;pos+=1;frames.append(out)
 assert pos==struct.unpack_from('<I',data,12)[0]
 return rgb(np.stack(frames).tobytes())[:,::-1],counts

def main():
 p=argparse.ArgumentParser();p.add_argument('--codec9',required=True);p.add_argument('--gradient11',required=True);p.add_argument('--input-dir',required=True);p.add_argument('--output',required=True);a=p.parse_args()
 src=Path(a.input_dir);out=Path(a.output);out.mkdir(parents=True,exist_ok=True);rows=[]
 for scene in [35,110,210,335]:
  raw=src/f's{scene}.rgb565';data=raw.read_bytes();assert len(data)==1280*720*2*3;ref=rgb(data)
  for budget in [145000,155000,165000]:
   for name,encoder in [('codec9',a.codec9),('gradient11',a.gradient11)]:
    dst=out/f's{scene}_{name}_{budget}.EXPERIMENTAL'
    with raw.open('rb') as inp:subprocess.run([str(Path(encoder).resolve()),str(dst),'500','8000',str(budget),'1'],stdin=inp,check=True)
    dec,counts=decode(dst);encoded=dst.read_bytes();declared=struct.unpack_from('<I',encoded,12)[0]
    rows.append(dict(scene=scene,budget=budget,format=name,declared_bytes=declared,sha256=hashlib.sha256(encoded).hexdigest(),token_counts=counts,**metrics(dec,ref)))
 aggregate=[]
 for budget in [145000,155000,165000]:
  for name in ['codec9','gradient11']:
   r=[x for x in rows if x['budget']==budget and x['format']==name]
   aggregate.append(dict(budget=budget,format=name,psnr=10*math.log10(255**2/np.mean([x['mse'] for x in r])),grid8=float(np.mean([x['grid8_gradient_rmse'] for x in r])),grid4=float(np.mean([x['grid4_gradient_rmse'] for x in r])),mean_frame_bytes=float(np.mean([(x['declared_bytes']-512)/3 for x in r]))))
 (out/'results.json').write_text(json.dumps(dict(results=rows,aggregate=aggregate),indent=2))
 print(json.dumps(aggregate,indent=2))
if __name__=='__main__':main()
