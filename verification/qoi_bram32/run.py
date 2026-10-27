from pathlib import Path
import subprocess,json,hashlib,random,struct,time,sys,os
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent/'generated';D.mkdir(exist_ok=True);rng=random.Random(20261027)
ops=bytearray();pixels=[];index=[(0,0,0,0)]*64;prev=(0,0,0,255);hist=[0]*7
while len(pixels)<8192:
 kind=rng.randrange(7);hist[kind]+=1;n=1
 if kind==0:
  p=tuple(rng.randrange(256)for _ in range(4));ops.extend([255,*p])
 elif kind==1:
  p=tuple(rng.randrange(256)for _ in range(3))+(prev[3],);ops.extend([254,*p[:3]])
 elif kind==2:
  ds=[rng.randrange(-2,2)for _ in range(3)];p=tuple((a+b)%256 for a,b in zip(prev[:3],ds))+(prev[3],)
  ops.append(0x40|((ds[0]+2)<<4)|((ds[1]+2)<<2)|(ds[2]+2))
 elif kind==3:
  dg=rng.randrange(-32,32);dr=rng.randrange(-8,8);db=rng.randrange(-8,8)
  p=((prev[0]+dg+dr)%256,(prev[1]+dg)%256,(prev[2]+dg+db)%256,prev[3]);ops.extend([0x80|dg+32,((dr+8)<<4)|db+8])
 elif kind in [4,6]:
  ix=rng.randrange(64);p=index[ix];ops.append(ix)
 else:
  n=min(rng.randrange(1,63),8192-len(pixels));p=prev;ops.append(0xc0|n-1)
 for _ in range(n):
  pixels.append(p[:3]);index[(3*p[0]+5*p[1]+7*p[2]+11*p[3])%64]=p
 prev=p
q=b'qoif'+struct.pack('>II',128,64)+bytes([4,0])+ops+bytes([0]*7+[1])
(D/'bytes.hex').write_text(''.join(f'{v:02x}\n'for v in q));(D/'pixels.hex').write_text(''.join(bytes(p).hex()+'\n'for p in pixels))
tb=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,start=0,iv=0,pr=0;reg[7:0]din=0;
wire ir,pv,done,error,ri,rv,rd,re;wire[23:0]pixel,rp;wire[31:0]w,h,rw,rh;
qoi_stream #(.BRAM32_INDEX(1))dut(clk,rst,start,din,iv,ir,pixel,pv,pr,done,error,w,h,25'd0);
qoi_stream refdut(clk,rst,start,din,iv,ri,rp,rv,pr,rd,re,rw,rh,25'd0);
reg[7:0]bytes[0:65535];reg[23:0]pixels[0:8191];integer nb,sent=0,sink=0,cycle=0,checks=0,k;
always@(negedge clk)if(!rst)begin
 if({ir,pv,done,error,w,h}!=={ri,rv,rd,re,rw,rh})$fatal(1,"QOI dual-port handshake mismatch");
 if(pv&&pixel!==rp)$fatal(1,"QOI dual-port reference mismatch");checks=checks+1;
end
task run_case;input integer abort_after;begin
 rst=1;start=0;iv=0;pr=0;sent=0;sink=0;repeat(8)@(negedge clk);#1;rst=0;start=1;@(negedge clk);#1;start=0;
 while(!done&&!error&&sink<abort_after)begin
  iv=sent<nb&&cycle%7!=0;din=bytes[sent];pr=cycle%11>3;
  @(posedge clk);if(iv&&ir)sent=sent+1;
  if(pv&&pr)begin if(pixel!==pixels[sink])$fatal(1,"independent QOI pixel%0d",sink);sink=sink+1;end
  @(negedge clk);#1;cycle=cycle+1;
 end
 if(error)$fatal(1,"QOI unexpected error");
 if(abort_after==8193&&(!done||sink!=8192))$fatal(1,"incomplete QOI");
 $display("CHECK QOI BRAM32 abort_limit=%0d pixels=%0d",abort_after,sink);rst=1;repeat(4)@(negedge clk);
end endtask
initial begin
 if(!$value$plusargs("BYTES=%d",nb))$fatal(1,"bytes");$readmemh("bytes.hex",bytes,0,nb-1);$readmemh("pixels.hex",pixels);
 run_case(8193);run_case(177);run_case(8193);
 $display("PASS QOI BRAM32 full_frames=2 abort_restart=1 total_checked_pixels=16561 cycle_comparisons=%0d",checks);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
'''
(D/'tb.v').write_text(tb);rtl=R/'rtl/image/qoi_stream.v'
files=[D/'tb.v',rtl,Path(os.environ['TD_SIM_DIR'])/'eg_phy_bram32k.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_glbl.v']
(D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.resolve().as_posix()+'}'for f in files)+f'\nvsim work.tb work.glbl +BYTES={len(q)}\nrun -all\nquit -code 0\n');t=time.time()
with(D/'console.log').open('w')as log:c=subprocess.run([os.environ.get('MODELSIM','vsim'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=c.returncode==0 and 'PASS QOI BRAM32'in out and '** Fatal'not in out and '** Error'not in out
(D/'qoi_bram32.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,scope='Actual EG4 BRAM32K primitive versus inferred32-bit memory, cycle equality and independent Python QOI pixels. Two8192-pixel images plus177-pixel abort and restart, all opcodes, alpha hash/collisions, stalls/gaps. No external card/presentation.',opcode_histogram=hist,summary=out[-5000:],source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}),indent=2));print(out[-3500:]);assert ok
