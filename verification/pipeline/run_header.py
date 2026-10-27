"""Valid/invalid complete BMP/QOI sector decisions compared cycle by cycle."""
from pathlib import Path
import struct,subprocess,json,hashlib,time,sys,os
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent/'generated/header';D.mkdir(parents=True,exist_ok=True)
H=R/'rtl/image';old=D.parents[1]/'bmp_reference_source.v';new=H/'bmp_read.v'

cases=[]
def bmp(w=640,h=480,length=None,offset=54,bits=24,compression=0,magic=b'BM'):
 if length is None:length=(offset+((w&65535)*(h&65535)*3))&0xffffffff
 b=bytearray(512);b[:2]=magic;struct.pack_into('<I',b,2,length);struct.pack_into('<I',b,10,offset);struct.pack_into('<II',b,18,w,h);struct.pack_into('<H',b,28,bits);struct.pack_into('<I',b,30,compression)
 return b,dict(kind='bmp',w=w,h=h,length=length,offset=offset,bits=bits,compression=compression,magic=magic.decode('latin1'))
def qoi(w=640,h=480,ch=3,space=0,magic=b'qoif'):
 b=bytearray(512);b[:14]=magic+struct.pack('>II',w,h)+bytes([ch,space]);return b,dict(kind='qoi',w=w,h=h,ch=ch,space=space,magic=magic.decode('latin1'))
for w in [0,1,639,640,641,4095,4096,4097,0x80000000,0xffffffff]:cases.append(bmp(w=w));cases.append(qoi(w=w))
for h in [0,1,479,480,481,4095,4096,4097,0x80000000,0xffffffff]:cases.append(bmp(h=h));cases.append(qoi(h=h))
for kw in [dict(length=0),dict(length=53),dict(length=54),dict(length=921653),dict(length=921654),dict(length=0xffffffff),dict(offset=0),dict(offset=53),dict(offset=55),dict(offset=0xffffffff),dict(bits=16),dict(bits=32),dict(compression=1),dict(magic=b'BX')]:cases.append(bmp(**kw))
for ch in [0,1,2,3,4,5,255]:
 for space in [0,1,2,255]:cases.append(qoi(ch=ch,space=space))
cases.append(qoi(magic=b'qoiX'))
(D/'headers.hex').write_text(''.join(f'{x:02x}\n'for b,_ in cases for x in b))
(D/'reference.v').write_text(old.read_text(encoding='utf-8').replace('module bmp_read','module bmp_reference'),encoding='utf-8')
tb=r'''`timescale 1ns/1ps
module tb;
parameter SCALE=1;
reg clk=0;always #5 clk=~clk;
reg rst=1,scan=0,load=0,valid=0,ended=0;reg[7:0]data=0;
wire[1:0]ready,done,found,wr,req,pe,topdown,err;wire[31:0]addr[0:1],sector[0:1],progress[0:1];wire[2:0]total[0:1];wire[3:0]state[0:1];wire[23:0]pixel[0:1];wire[15:0]iw[0:1],ih[0:1];
reg seen=0;integer n,j,mode,cycles=0,totalcases;reg[7:0]headers[0:65535],expected[0:255];
`define PORTS(I) .clk(clk),.rst(rst),.load_abort(1'b0),.sd_error(1'b0),.sd_grant(1'b1),.ready(ready[I]),.scan_start(scan),.scan_abort(1'b0),.scan_start_sector(32'd100),.scan_max_sector(32'd100),.scan_target_count(3'd1),.scan_limited(1'b1),.scan_start_sector2(32'd100),.scan_start2(1'b0),.scan_done(done[I]),.scan_found_valid(found[I]),.scan_found_sector(sector[I]),.scan_found_total(total[I]),.load_start(load),.load_sector(32'd100),.sd_init_done(1'b1),.state_code(state[I]),.bmp_width(16'd640),.bmp_height(16'd480),.write_req(wr[I]),.write_req_ack(1'b0),.write_almost_full(1'b0),.sd_sec_read(req[I]),.sd_sec_read_addr(addr[I]),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),.bmp_data_wr_en(pe[I]),.bmp_data(pixel[I]),.img_h_o(ih[I]),.source_top_down(topdown[I]),.load_error(err[I]),.img_w_o(iw[I]),.scan_sector_o(progress[I])
bmp_reference #(.SCALING_EN(SCALE),.SCAN_INIT_BUDGET(1)) refdut(`PORTS(0));
bmp_read #(.SCALING_EN(SCALE),.SCAN_INIT_BUDGET(1)) dut(`PORTS(1));
always @(posedge clk)begin #1;cycles=cycles+1;
 if(!rst)begin
  if({ready[0],done[0],found[0],wr[0],req[0],pe[0],topdown[0],err[0],addr[0],sector[0],progress[0],total[0],state[0],pixel[0],iw[0],ih[0]}!=={ready[1],done[1],found[1],wr[1],req[1],pe[1],topdown[1],err[1],addr[1],sector[1],progress[1],total[1],state[1],pixel[1],iw[1],ih[1]})$fatal(1,"header external mismatch n=%d mode=%d cycle=%d",n,mode,cycles);
  if(found[1])seen=1;
 end
end
initial begin
 if(!$value$plusargs("N=%d",totalcases))$fatal(1,"N missing");
 $readmemh("headers.hex",headers,0,totalcases*512-1);$readmemh("expected.hex",expected,0,totalcases-1);
 for(mode=0;mode<2;mode=mode+1)for(n=0;n<totalcases;n=n+1)begin
  @(negedge clk);#1;rst=1;scan=0;load=0;valid=0;ended=0;seen=0;repeat(5)@(negedge clk);#1;rst=0;
  @(negedge clk);#1;scan=(mode==0);load=(mode==1);@(negedge clk);#1;scan=0;load=0;
  wait(req[1]);repeat(2)@(negedge clk);
  for(j=0;j<512;j=j+1)begin
   @(negedge clk);#1;data=headers[n*512+j];valid=1;
   if(n%2)begin @(negedge clk);#1;valid=0;end
  end
  @(negedge clk);#1;valid=0;ended=1;@(negedge clk);#1;ended=0;repeat(10)@(negedge clk);#1;
  if(mode==0 && seen!==expected[n][0])$fatal(1,"independent header scan decision n=%d got=%d expected=%d",n,seen,expected[n]);
  if(mode==1 && wr[1]!==expected[n][0])$fatal(1,"independent header load decision n=%d got=%d expected=%d",n,wr[1],expected[n]);
 end
 $display("PASS image header pipeline scaling=%d cases=%d decisions=%d cycles=%d",SCALE,totalcases,totalcases*2,cycles);$finish;
end
initial begin #20000000;$fatal(1,"timeout");end
endmodule
'''
(D/'tb.v').write_text(tb)
files=[D/'tb.v',D/'reference.v',new,H/'qoi_stream.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_bram32k.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_glbl.v']
results=[];t=time.time()
for scale in [0,1]:
 expect=[]
 for _,c in cases:
  ok=c['w']>=640 and c['w']<=4096 and c['h']>=1 and c['h']<=(4096 if scale else 480)
  if c['kind']=='qoi':ok=ok and c['magic']=='qoif' and c['ch']in[3,4] and c['space']<=1
  else:ok=ok and c['magic']=='BM' and c['offset']>=54 and c['length']>=c['offset'] and c['length']-c['offset']>=((c['w']&65535)*(c['h']&65535)*3)&0xffffffff and c['bits']==24 and c['compression']==0
  expect.append(int(ok))
 (D/'expected.hex').write_text(''.join(f'{x:02x}\n'for x in expect))
 (D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.resolve().as_posix()+'}'for f in files)+f'\nvsim -gSCALE={scale} work.tb work.glbl +N={len(cases)}\nrun -all\nquit -code 0\n')
 with(D/f'console_{scale}.log').open('w')as log:p=subprocess.run([os.environ.get('MODELSIM','vsim'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
 out=(D/f'console_{scale}.log').read_text(errors='replace');print(out[-2500:],flush=True);ok=p.returncode==0 and'PASS image header pipeline'in out and'** Fatal'not in out and'** Error'not in out
 results.append(dict(scaling=scale,passed=ok,output=out[-2500:]));assert ok
(D/'image_header_pipeline.json').write_text(json.dumps(dict(passed=True,seconds=time.time()-t,scope=f'{len(cases)} BMP/QOI complete header sectors, scaling0/1, scan/load, continuous/gapped bytes; external outputs cycle-compared with v48 and independent Python accept/reject decisions. Does not decode full images.',results=results,source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}),indent=2))
