from pathlib import Path
import numpy as np
import struct
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
 data=path.read_bytes();assert data[:5]==b'FPGV\x01' and data[5] in (9,11,12);n=struct.unpack_from('<I',data,16)[0];pos=512;frames=[];counts={}
 yy,xx=np.indices((8,8));weights=np.stack(((8-xx)*(8-yy),xx*(8-yy),(8-xx)*yy,xx*yy),axis=-1)
 for fi in range(n):
  out=np.zeros((720,1280),dtype='<u2')
  for k in range(14400):
   op=data[pos];pos+=1;counts[op]=counts.get(op,0)+1
   size={128:2,129:12,131:128,132:8,134:8,135:5,136:24}[op];p=data[pos:pos+size];pos+=size
   if op==128:block=np.full((8,8),int.from_bytes(p,'little'),dtype='<u2')
   elif op==131:block=np.frombuffer(p,dtype='<u2').reshape(8,8)
   elif op==129:
    pal=np.frombuffer(p[:4],dtype='<u2');indices=(np.frombuffer(p[4:],dtype='u1')[:,None]>>np.arange(8))&1;block=pal[indices]
   elif op==132:block=np.frombuffer(p,dtype='<u2').reshape(2,2).repeat(4,0).repeat(4,1)
   elif op==135:
    direction=p[0]>>5;threshold=p[0]&31
    ax=[1,0,1,1,2,2,1,1][direction];ay=[0,1,1,-1,1,-1,2,-2][direction]
    projection=ax*xx+ay*yy-min(0,ay*7)
    pal=np.frombuffer(p[1:],dtype='<u2');block=pal[(projection>=threshold).astype(np.int32)]
   elif op==136:
    pal=np.frombuffer(p[:8],dtype='<u2');packed=np.frombuffer(p[8:],dtype='u1')
    ix=((packed[:,None]>>(2*np.arange(4)))&3).reshape(8,8);block=pal[ix]
   else:
    pal=np.frombuffer(p,dtype='<u2').astype(np.int32);rr=(weights@(pal>>11)+32)>>6;gg=(weights@((pal>>5)&63)+32)>>6;bb=(weights@(pal&31)+32)>>6;block=(rr<<11)|(gg<<5)|bb
   by,bx=divmod(k,160);out[by*8:by*8+8,bx*8:bx*8+8]=block
  assert data[pos]==255;pos+=1;frames.append(out)
 assert pos==struct.unpack_from('<I',data,12)[0]
 return rgb(np.stack(frames).tobytes())[:,::-1],counts
