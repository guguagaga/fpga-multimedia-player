"""Real SD command/cache state machines, inferred versus actual32K RAM."""
from pathlib import Path
import subprocess,json,hashlib,time,sys,os
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent/'generated/cache32';D.mkdir(parents=True,exist_ok=True);P=R

tb=r'''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,req=0,multi=0,pace=0;reg[31:0]lba=0;
reg ca=0,ce=0,bv=0,ba=0;reg[7:0]bd=0;
wire[1:0]init,dv,de,cq,br,err;wire[7:0]data[0:1],r1[0:1];wire[15:0]div[0:1],len[0:1],nb[0:1];wire[47:0]cmd[0:1];wire[4:0]state[0:1];
integer cycles=0,checks=0,tx=0,commands=0,burst=0,remaining=0,idx=0;reg[31:0]physical_base;reg oldbr=0;reg busy=0;
function[7:0]value;input[31:0]sector;input integer off;begin value=(sector*37)^(off*29)^(off>>3);end endfunction
`define PORTS(I) .clk(clk),.rst(rst),.sd_init_done(init[I]),.sd_sec_read(req),.sd_sec_read_addr(lba),.multi_en(multi),.multi_paced(pace),.sd_sec_read_data(data[I]),.sd_sec_read_data_valid(dv[I]),.sd_sec_read_end(de[I]),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end(),.spi_clk_div(div[I]),.cmd_req(cq[I]),.cmd_req_ack(ca),.cmd_req_error(ce),.cmd(cmd[I]),.cmd_r1(r1[I]),.cmd_data_len(len[I]),.block_read_req(br[I]),.block_read_valid(bv),.block_read_data(bd),.block_read_req_ack(ba),.rd_nb_blk(nb[I]),.block_write_req(),.block_write_data(),.block_write_data_rd(1'b0),.block_write_req_ack(1'b0),.dbg_state(state[I]),.dbg_cmd_err(err[I])
sd_card_sec_read_write #(.PREFETCH_BRAM32(0)) inferred(`PORTS(0));
sd_card_sec_read_write #(.PREFETCH_BRAM32(1)) dut32(`PORTS(1));
always @(posedge clk)begin cycles=cycles+1;
 if(!rst)begin
  if({init[0],dv[0],de[0],cq[0],br[0],div[0],len[0],nb[0],cmd[0],r1[0],state[0],err[0]}!=={init[1],dv[1],de[1],cq[1],br[1],div[1],len[1],nb[1],cmd[1],r1[1],state[1],err[1]})$fatal(1,"SD cache interface cycle mismatch %d",cycles);
  if(dv[1])begin
   if(data[0]!==data[1])$fatal(1,"RAM cycle mismatch");
   if(data[1]!==value(lba,checks%512))$fatal(1,"independent sector data lba=%d offset=%d got=%h",lba,checks%512,data[1]);
   checks=checks+1;
  end
 end
end
// A byte-level card model; command/CRC electrical behavior is not modeled.
always @(negedge clk)begin #1;
 ca=0;bv=0;ba=0;
 if(rst)begin busy=0;oldbr=0;end
 else begin
  if(cq[0])begin ca=1;commands=commands+1;if(cmd[0][47:40]==17||cmd[0][47:40]==18)physical_base=cmd[0][39:8];end
  if(br[0]&&!busy&&!oldbr)begin remaining=nb[0]*512;idx=0;busy=1;burst=burst+1;end
  if(busy && cycles%7!=0)begin
   if(remaining>0)begin bd=value(physical_base+idx/512,idx%512);bv=1;idx=idx+1;remaining=remaining-1;end
   else begin ba=1;busy=0;end
  end
  oldbr=br[0];
 end
end
task read_sector;input[31:0]sector;input m,p;integer prior_checks;begin
 wait(state[0]==17);@(negedge clk);#2;lba=sector;multi=m;pace=p;prior_checks=checks;req=1;tx=tx+1;
 wait(de[1]);@(negedge clk);#2;req=0;
 if(checks-prior_checks!=512)$fatal(1,"short/long sector %d",checks-prior_checks);
 wait(state[0]==17);repeat(3)@(negedge clk);
end endtask
integer j;
initial begin
 repeat(8)@(negedge clk);#2;rst=0;wait(state[0]==17);
 read_sector(100,1,0);
 for(j=1;j<16;j=j+1)read_sector(100+j,j%2,j%3==0);
 for(j=15;j>0;j=j-1)read_sector(100+j,0,j%2);
 read_sector(900,1,1);
 for(j=1;j<16;j=j+1)read_sector(900+j,0,j%2);
 read_sector(700,0,0);read_sector(902,0,1);read_sector(1100,1,0);
 // Reset invalidates cache; a subsequent same LBA must be refetched.
 @(negedge clk);#2;rst=1;repeat(7)@(negedge clk);#2;rst=0;wait(state[0]==17);read_sector(1101,0,0);
 if(burst!=5)$fatal(1,"unexpected physical transfer count %d",burst);
 $display("PASS SD prefetch32 transactions=%d bytes=%d cycles=%d physical_transfers=%d commands=%d",tx,checks,cycles,burst,commands);$finish;
end
initial begin #10000000;$fatal(1,"timeout state=%d bytes=%d tx=%d",state[1],checks,tx);end
endmodule
'''
(D/'tb.v').write_text(tb)
files=[D/'tb.v',P/'rtl/storage/sd_card_sec_read_write.v',P/'rtl/video/video_byte_ram.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_bram32k.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_glbl.v']
(D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.resolve().as_posix()+'}'for f in files)+'\nvsim work.tb work.glbl\nrun -all\nquit -code 0\n')
t=time.time()
with(D/'console.log').open('w')as log:p=subprocess.run([os.environ.get('MODELSIM','vsim'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=p.returncode==0 and'PASS SD prefetch32'in out and'** Fatal'not in out and'** Error'not in out
(D/'sd_prefetch_bram32.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,scope='Production SD controller inferred and actual BRAM32 cache instances, output cycle equivalence and independent data; fill, all15 cached sectors, forward/backward, mixedpaced hits with multi off, cache replacement, CMD17, reset/refetch. Byte-level card model, not SPI electrical or physical SD.',summary=out[-3000:],source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}),indent=2));print(out[-3000:]);assert ok
