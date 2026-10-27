"""Independent packet fixture/reference versus isolated research RTL."""
from pathlib import Path
import random,struct,json,hashlib,subprocess,time,os
from experimental_raw_bounds import encode,decode
W=Path(__file__).resolve().parent;D=W/'generated/rtl';D.mkdir(parents=True,exist_ok=True)
rng=random.Random(20261027);cases=[]
for n in range(1000):
 px=[rng.randrange(65536)for _ in range(64)]
 for qy in range(2):
  for qx in range(2):
   lows=[rng.randrange(32),rng.randrange(64),rng.randrange(32)];spans=[rng.randrange(limit-lo+1)for limit,lo in zip([31,63,31],lows)]
   if n%7==0:spans=[0,0,0]
   if n%11==0:continue
   for y in range(4):
    for x in range(4):
     c=[lo+rng.randrange(span+1)for lo,span in zip(lows,spans)];px[(qy*4+y)*8+qx*4+x]=(c[0]<<11)|(c[1]<<5)|c[2]
 packet=encode(px);assert decode(packet)==tuple(px);cases.append((packet,px))
cases.extend((bytes([0x83])+struct.pack('<64H',*([c]*64)),[c]*64)for c in [0,65535,0x7bef])
bad=[b'\x82',b'\x86\x02',b'\x86\x08'+bytes(32),b'\x86\x01'+struct.pack('<HH',0,6),b'\x86\x01'+struct.pack('<HH',0,7<<3),b'\x86\x01'+struct.pack('<HH',0,6<<6),b'\x86\x01'+struct.pack('<HH',0,512),b'\x86\x01'+struct.pack('<HH',0xf800,1)+b'\xff\xff']
packets=[p for p,_ in cases]+bad;data=b''.join(packets);offsets=[];pos=0
for p in packets:offsets.append(pos);pos+=len(p)
for name,values,digits in [('bytes',data,2),('offset',offsets,8),('length',[len(p)for p in packets],8),('pixels',[x for _,px in cases for x in px],4)]:
 (D/(name+'.hex')).write_text(''.join(f'{v:0{digits}x}\n'for v in values))
tb=r'''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,start=0,cancel=0,pause=0,valid=0,ready=0;reg[7:0]din=0;
wire ir,pv,done,fault;wire[15:0]pixel;
experimental_raw_bounds_decoder dut(.clk(clk),.rst(rst),.start(start),.cancel(cancel),.pause(pause),.din(din),.din_valid(valid),.din_ready(ir),.pixel(pixel),.pixel_valid(pv),.pixel_ready(ready),.done(done),.fault(fault));
reg[7:0]bytes[0:BYTECOUNT-1];reg[31:0]offset[0:CASECOUNT-1],length[0:CASECOUNT-1];reg[15:0]reference[0:GOODCOUNT*64-1];
integer cycles=0,c=0,sent=0,pixels=0,checks=0,aborts=0,oplimit=0;reg abort_mode=0;
always@(negedge clk)begin
 cycles=cycles+1;
 pause=(cycles%41<5);ready=(cycles%17>3);valid=0;
 if(!rst&&!start&&!cancel&&sent<length[c]&&cycles%7!=0)begin valid=1;din=bytes[offset[c]+sent];end
end
always@(posedge clk)if(!rst&&!start&&!cancel)begin
 if(valid&&ir)sent=sent+1;
 if(pv&&ready)begin
  if(c>=GOODCOUNT||pixels>=64||pixel!==reference[c*64+pixels])$fatal(1,"pixel mismatch c=%d pixel=%d got=%h",c,pixels,pixel);
  pixels=pixels+1;checks=checks+1;
 end
end
task run_case;input integer n,abort_after;integer limit;begin
 @(negedge clk);#2;c=n;sent=0;pixels=0;start=1;valid=0;
 @(negedge clk);#2;start=0;limit=0;
 while(!done&&!fault&&limit<5000&&(abort_after==0||sent<abort_after))begin @(negedge clk);#2;limit=limit+1;end
 if(abort_after!=0)begin cancel=1;aborts=aborts+1;@(negedge clk);#2;cancel=0;repeat(3)@(negedge clk);if(done||fault||pv)$fatal(1,"cancel did not clear session");end
 else if(n<GOODCOUNT)begin if(!done||fault||pixels!=64||sent!=length[c])$fatal(1,"normal outcome c=%d sent=%d pixels=%d",c,sent,pixels);end
 else if(!fault||done||pixels!=0)$fatal(1,"malformed outcome c=%d",c);
end endtask
integer i;
initial begin
 $readmemh("bytes.hex",bytes);$readmemh("offset.hex",offset);$readmemh("length.hex",length);$readmemh("pixels.hex",reference);
 repeat(8)@(negedge clk);#2;rst=0;
 for(i=0;i<CASECOUNT;i=i+1)begin run_case(i,0);if(i<100)begin run_case(i,1+i%(length[i]-1));run_case(i,0);end end
 $display("PASS experimental bounds cases=%d pixels=%d aborts=%d cycles=%d",CASECOUNT,checks,aborts,cycles);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
'''.replace('BYTECOUNT',str(len(data))).replace('CASECOUNT',str(len(packets))).replace('GOODCOUNT',str(len(cases)))
(D/'tb.v').write_text(tb);rtl=W/'experimental_raw_bounds_decoder.v';t=time.time()
c=subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012','-s','tb','-o',str(D/'sim.vvp'),str(D/'tb.v'),str(rtl)],capture_output=True,text=True);assert c.returncode==0,c.stderr
c=subprocess.run([os.environ.get('VVP','vvp'),str(D/'sim.vvp')],cwd=D,capture_output=True,text=True,timeout=90);out=c.stdout+c.stderr
passed=c.returncode==0 and'PASS experimental bounds'in out
report=dict(passed=passed,scope='Isolated proposed0x86/RAW research decoder,1003 valid packets,8malformed,100cancel/restart cases, deterministic input gaps/pause/output backpressure, pixel-exact Python reference. Not production integration, synthesis, timing or movie throughput.',seconds=time.time()-t,summary=out,source_sha256={str(p):hashlib.sha256(p.read_bytes()).hexdigest()for p in [rtl,W/'experimental_raw_bounds.py',D/'tb.v']})
(D/'result.json').write_text(json.dumps(report,indent=2));print(out);assert passed
