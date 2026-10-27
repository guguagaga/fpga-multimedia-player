"""Exercise legacy default compatibility and production block-only selection."""
from pathlib import Path
import subprocess,json,hashlib,time,os
R=Path(__file__).resolve().parents[2];P=R/'rtl/video';D=Path(__file__).resolve().parent/'generated';D.mkdir(exist_ok=True)
old=Path(__file__).resolve().parent/'video_player_reference.v'
(D/'reference.v').write_text(old.read_text(encoding='utf-8').replace('module video_player #(', 'module video_reference #('))
tb=r'''
`timescale 1ns/1ps
module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,play=0,pause=0;reg[7:0] data=0;reg valid=0,done=0;
 reg[7:0] card[0:1023];integer code=0,i,j,k,n,cycles=0,checks=0,cases=0;
 wire[2:0]req,wreq,pe,active,disp;wire[31:0]addr[0:2],pixel[0:2];wire[3:0]state[0:2];
 reg[2:0]ack=0,finish=0;reg[31:0] expected[0:511];integer count[0:2];
 wire full=(cycles%29<4);integer mode=0;
`define PORTS(ID) .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_error(1'b0),.present_enable(1'b1),.timeline_run(1'b1),.audio_frame_tick(1'b0),.audio_clock_active(1'b0),.audio_frame_samples(),.play(play),.pause(pause),.start_sector(32'd1),.img_disp_buf(2'd0),.sd_sec_read(req[ID]),.sd_sec_read_addr(addr[ID]),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),.sd_grant(req[ID]),.write_almost_full(full),.write_req(wreq[ID]),.write_req_ack(ack[ID]),.write_finish_toggle(finish[ID]),.pix_en(pe[ID]),.pix_data(pixel[ID]),.img_h_o(),.vsync_tick(1'b0),.wr_buf_idx(),.dp_buf_idx(),.active(active[ID]),.disp_ok(disp[ID]),.dbg_state(state[ID])
 video_reference #(.FRAME_PIXELS(512),.FRAME_H(8)) refdut(`PORTS(0));
 video_player #(.FRAME_PIXELS(512),.FRAME_H(8)) compatible(`PORTS(1));
 video_player #(.LEGACY_CODECS(0),.FRAME_PIXELS(512),.FRAME_H(8)) production(`PORTS(2));
 function[31:0]rgb;input[15:0]c;begin rgb={{c[15:11],c[15:13]},{c[10:5],c[10:9]},{c[4:0],c[4:2]},8'd0};end endfunction
 always@(negedge clk)begin
  cycles=cycles+1;pause=(cycles%83<7);
  for(k=0;k<3;k=k+1)ack[k]=wreq[k]&&(count[k]<512);
  if(!rst)begin
   if({req[0],wreq[0],pe[0],active[0],disp[0],state[0]}!=={req[1],wreq[1],pe[1],active[1],disp[1],state[1]})$fatal(1,"default handshake mismatch code=%d",code);
   if(req[0]&&addr[0]!==addr[1])$fatal(1,"default request address");
   if(pe[0]&&pixel[0]!==pixel[1])$fatal(1,"default pixel mismatch");
   if(code>=8&&mode==0)begin
    if({req[0],wreq[0],pe[0],active[0],disp[0],state[0]}!=={req[2],wreq[2],pe[2],active[2],disp[2],state[2]})$fatal(1,"block handshake mismatch");
    if(pe[0]&&pixel[0]!==pixel[2])$fatal(1,"block pixel mismatch");
   end
   for(k=0;k<3;k=k+1)if(pe[k])begin
    if(count[k]>=512)$fatal(1,"extra pixels");
    if(k==2&&code>=8)begin
     if(pixel[k]!==expected[count[k]])$fatal(1,"production pixel code=%d mode=%d index=%d got=%h expected=%h",code,mode,count[k],pixel[k],expected[count[k]]);
     checks=checks+1;
    end
    count[k]=count[k]+1;
    if(count[k]==512)finish[k]=~finish[k];
   end
  end
 end
 task put;input[7:0]v;begin card[n]=v;n=n+1;end endtask
 task sector;input integer a;integer b;begin
  wait(req[0]&&addr[0]==a);@(negedge clk);
  for(b=0;b<512;b=b+1)begin data=card[(a-1)*512+b];valid=1;@(negedge clk);end
  valid=0;done=1;@(negedge clk);done=0;repeat(8)@(negedge clk);
 end endtask
 task run_case;input integer c,m;integer v,x,y,b,z;reg[15:0]color;begin
  rst=1;play=0;valid=0;done=0;finish=0;code=c;mode=m;
  for(v=0;v<3;v=v+1)count[v]=0;
  for(v=0;v<1024;v=v+1)card[v]=0;
  card[0]="F";card[1]="P";card[2]="G";card[3]="V";card[4]=1;card[5]=c;card[6]=64;card[8]=8;card[10]=15;card[13]=4;
  n=512;
  if(c>=8)begin
   for(v=0;v<512;v=v+1)expected[v]=0;
   if(m==1)put(8'hff);
   else if(m==2)put(8'h82);
   else if(c==10)begin
    put(8'h85);put(7);put(8'h1f);put(8'hf8);
    for(v=0;v<512;v=v+1)expected[v]=rgb(16'hf81f);put(8'hff);
   end else begin
    for(b=0;b<8;b=b+1)begin
     color=16'h07e0+b;put(8'h80);put(color[7:0]);put(color[15:8]);
     for(y=0;y<8;y=y+1)for(x=0;x<8;x=x+1)expected[y*64+b*8+x]=rgb(color);
    end
    put(8'hff);
   end
  end else begin
   // Exercise RUN plus historical COPY_UP / APPROX_RUN branches.
   for(b=0;b<8;b=b+1)begin
    if(b!=0&&(c==5||c==6))begin put(8'hfb);put(8'hc3);end
    else begin
     if(c==7)begin put(8'hfc);put(63);end else put(8'h3f);
     put(8'h1f);if(c!=2&&c!=5)put(8'hf8);
    end
   end
   put(8'hff);
  end
  repeat(8)@(negedge clk);#1;rst=0;play=1;
  sector(1);
  if(c<8)begin
   repeat(16)@(negedge clk);
   if(state[2]!=8||active[2]||wreq[2]||count[2]!=0)$fatal(1,"legacy must be rejected by block-only build");
  end
  sector(2);
  wait(disp[0]&&disp[1]&&(c<8||disp[2]));repeat(8)@(negedge clk);
  if(count[0]!=512||count[1]!=512||(c>=8&&count[2]!=512))$fatal(1,"incomplete pixel count");
  cases=cases+1;$display("CHECK specialization code=%0d mode=%0d",c,m);
  rst=1;play=0;repeat(8)@(negedge clk);
 end endtask
 initial begin
  run_case(1,0);run_case(2,0);run_case(5,0);run_case(6,0);run_case(7,0);
  run_case(8,0);run_case(9,0);run_case(10,0);
  run_case(10,1);run_case(10,2);
  $display("PASS video specialization cases=%0d production_pixels=%0d cycles=%0d",cases,checks,cycles);$finish;
 end
 initial begin #100000000;$fatal(1,"specialization timeout code=%d mode=%d counts=%d/%d/%d states=%d/%d/%d",code,mode,count[0],count[1],count[2],state[0],state[1],state[2]);end
endmodule
'''
(D/'tb.v').write_text(tb)
files=[D/'tb.v',D/'reference.v',P/'video_player.v',P/'video_byte_ram.v',P/'video_codec8_block_decoder.v',P/'video_codec8_raster.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_bram32k.v',Path(os.environ['TD_SIM_DIR'])/'eg_phy_glbl.v']
(D/'run.do').write_text('onerror {quit -code 1}\nvlib work\nvlog -sv '+' '.join('{'+f.resolve().as_posix()+'}'for f in files)+'\nvsim work.tb work.glbl\nrun -all\nquit -code 0\n')
t=time.time()
with(D/'console.log').open('w')as log:c=subprocess.run([os.environ.get('MODELSIM','vsim'),'-c','-do','run.do'],cwd=D,stdout=log,stderr=subprocess.STDOUT)
out=(D/'console.log').read_text(errors='replace');ok=c.returncode==0 and 'PASS video specialization'in out and '** Fatal'not in out and '** Error'not in out
(D/'video_specialization.json').write_text(json.dumps(dict(passed=ok,seconds=time.time()-t,scope='10 small-frame cases. New module default=1 versus v35 cycle/pixel comparison; production=0 matches accepted block frames, rejects legacy headers, pads short/invalid frames. Pauses and FIFO stalls included. Not full video throughput.',summary=out[-6000:],source_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files}),indent=2))
print(out[-4000:]);assert ok
