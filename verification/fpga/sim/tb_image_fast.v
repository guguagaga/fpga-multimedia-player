`timescale 1ns/1ps
module tb_image_fast;
parameter ENABLE_FAST=1;
defparam dut.bmp_read_m0.FAST_ROW_EN=ENABLE_FAST;
reg clk=0,memclk=0,rst=1;always #5 clk=~clk;always #4 memclk=~memclk;
reg start=0;wire dirreq,dirready;wire[31:0]diraddr;reg[7:0]dirdata=0;reg dirvalid=0,dirend=0;
wire[2:0]ic;wire[31:0]i0,i1,i2,i3;
fat32_list fat(.clk(clk),.rst(rst),.scan_start(start),.sd_init_done(1'b1),.list_idx(5'd0),
 .sd_sec_read(dirreq),.sd_sec_read_addr(diraddr),.sd_sec_read_data(dirdata),.sd_sec_read_data_valid(dirvalid),.sd_sec_read_end(dirend),
 .list_ready(dirready),.image_count_o(ic),.image0_o(i0),.image1_o(i1),.image2_o(i2),.image3_o(i3));
reg[7:0]boot[0:511],root[0:8191];integer di,db;
initial begin
 $readmemh("work/video_800x600/audio/card_boot.hex",boot);$readmemh("work/video_800x600/audio/card_root.hex",root);
 wait(!rst);forever begin
  @(negedge clk);if(dirreq)begin
   db=(diraddr-32768)*512;
   if(diraddr!=0&&(db<0||db>7680))$fatal(1,"directory address");
   for(di=0;di<512;di=di+1)begin dirvalid=1;dirdata=diraddr==0?boot[di]:root[db+di];@(negedge clk);end
   dirvalid=0;repeat(8)@(negedge clk);dirend=1;@(negedge clk);dirend=0;repeat(20)@(negedge clk);
  end
 end
end
reg nextkey=1,autokey=1,lock=0,fade_done=0,fin=0;
wire req,wreq,wen,ack,shown,loading,fadereq;wire[31:0]addr,wd;wire[15:0]ih;wire[1:0]wb,dp;
reg[7:0]data=0;reg valid=0,ended=0;
wire[3:0]st;
reg serving=0;integer txn=0;
reg[7:0]dq=0;reg vq=0,eq=0,gq=0;
always@(posedge clk)begin dq<=data;vq<=valid;eq<=ended;gq<=serving;end
integer wp=0,rp=0,np=0,nf=0,prevnf=0;wire[9:0]used=wp-rp;
wire aclr,mwen,mfin;wire[23:0]maddr;reg[31:0]queue[0:2047];wire cfg_bnd;
integer cycle=0;always@(posedge clk)cycle<=cycle+1;
// At 2M simulated clocks/second, prefetch deadline overlaps loading.
sd_card_bmp #(.CLK_FREQ_HZ(2000000)) dut(.clk(clk),.rst(rst),
 .directory_count(ic),.directory0(32'd100000),.directory1(32'd200000),.directory2(32'd300000),.directory3(32'd400000),
 .key_next(nextkey),.key_auto(autokey),.bmp_width(16'd640),.bmp_height(16'd480),
 .period_code(4'd1),.auto_period_sec(10'd3),.period_reseed(1'b0),.cfg_boundary_o(cfg_bnd),
 .display_valid(shown),.img_loading(loading),.scan_start_sector(32'd32768),.scan_start_sector2(32'd0),
 .scan_start2(1'b0),.scan_limited(1'b1),.write_finish_toggle(fin),.write_buf_idx(wb),.disp_buf_idx(dp),
 .switch_lock(1'b0),.vid_lock(lock),.fade_req_toggle(fadereq),.fade_done_pulse(fade_done),
 .write_req(wreq),.write_req_ack(ack),.write_almost_full(used>=512 || (cycle%1733<73)),
 .write_en(wen),.write_data(wd),.img_h_o(ih),.sd_init_done(dirready),.sd_sec_read(req),.sd_sec_read_addr(addr),
 .sd_sec_read_data(dq),.sd_sec_read_data_valid(vq),.sd_sec_read_end(eq),.sd_grant(gq),.state_code(st));
frame_fifo_write #(.ADDR_BITS(24),.BURST_SIZE(256),.FRAME_WIDTH(800),.FRAME_HEIGHT(600)) writer(
 .rst(rst),.mem_clk(memclk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.App_rd_busy(cycle%37<5),
 .App_wr_en(mwen),.App_wr_addr(maddr),.write_req(wreq),.write_req_ack(ack),.write_finish(mfin),
 .write_addr_0(24'd0),.write_addr_1(24'd480000),.write_addr_2(24'd960000),.write_addr_3(24'd0),
 .write_addr_index(wb),.write_len(24'd480000),.write_img_h(ih),.write_top_down(1'b0),.fifo_aclr(aclr),.rdusedw(used));
always@(posedge clk or posedge aclr)begin
 if(aclr)wp=0;else if(wen)begin
  if(used>=1023)$fatal(1,"image FIFO overflow");queue[wp%2048]=wd;wp=wp+1;
 end
end
integer expected,basebank,framewords=0;
integer ex,ey,iw,ihsrc,flen,sourcex,sourcey,load_cycle,load_txn;
integer load_cycles[0:3],load_sectors[0:3];
function [23:0] color;
 input integer cx,cy;
 begin color={cx[7:0]^cy[11:4],cy[7:0]^cx[11:4],8'(cx+cy)};
 end
endfunction
always @(posedge wreq) begin load_cycle=cycle;load_txn=txn;end

always@(posedge memclk or posedge aclr)begin
 if(aclr)begin rp=0;framewords=0;basebank=wb*480000;end
 else begin
  if(mwen)begin
   if(rp>=wp)$fatal(1,"writer consumed empty FIFO");
   expected=basebank+(599-framewords/800)*800+framewords%800;
   if(maddr!==expected)$fatal(1,"writer address got=%d expected=%d",maddr,expected);
   sourcex=((framewords%800)*4/5)*(dut.load_idx+1);
   sourcey=((framewords/800)*4/5)*(dut.load_idx+1);
   if(queue[rp%2048]!=={color(sourcex,sourcey),8'd0})
    $fatal(1,"pixel mismatch image=%d n=%d got=%h expected=%h xy=%d,%d",dut.load_idx,framewords,queue[rp%2048],color(sourcex,sourcey),sourcex,sourcey);
   rp=rp+1;framewords=framewords+1;
  end
  if(mfin)begin
   if(framewords!=480000)$fatal(1,"frame length %d",framewords);
   fin=~fin;nf=nf+1;
   if(nf<=4)begin
    load_cycles[dut.load_idx]=cycle-load_cycle;load_sectors[dut.load_idx]=txn-load_txn;
    $display("MEASURE image=%0d size=%0dx%0d fast=%0d cycles=%0d sectors=%0d",dut.load_idx,640*(dut.load_idx+1),480*(dut.load_idx+1),ENABLE_FAST,cycle-load_cycle,txn-load_txn);
   end
   $display("WRITTEN frame=%d index=%d cycles=%d",nf,dut.load_idx,cycle);
  end
 end
end
reg fadeprev=0;integer fade_wait=0;
always@(negedge clk)begin
 fade_done=0;
 if(fadereq!=fadeprev)begin fadeprev=fadereq;fade_wait=81;end
 if(fade_wait>0)begin fade_wait=fade_wait-1;if(fade_wait==0)fade_done=1;end
end
reg[7:0]header[0:511];integer j,k,off,ib;
function[7:0]value;
input integer offset;
integer pix,cx,cy;reg[23:0]rgb;
begin
 if(offset<54)begin
  case(offset)
   0:value="B";1:value="M";
   2,3,4,5:value=flen>>((offset-2)*8);
   10:value=54;14:value=40;
   18,19,20,21:value=iw>>((offset-18)*8);
   22,23,24,25:value=ihsrc>>((offset-22)*8);
   26:value=1;28:value=24;
   default:value=0;
  endcase
 end else if(offset<flen)begin
  pix=(offset-54)/3;cx=pix%iw;cy=pix/iw;rgb=color(cx,cy);
  value=rgb>>(((offset-54)%3)*8);
 end else value=0;
end
endfunction
initial begin
 for(j=0;j<512;j=j+1)header[j]=0;
 header[0]="B";header[1]="M";header[2]=8'h36;header[3]=8'h10;header[4]=8'h0e;
 header[10]=54;header[14]=40;header[18]=8'h80;header[19]=2;header[22]=8'he0;header[23]=1;header[26]=1;header[28]=24;
 wait(!rst);forever begin
  @(negedge clk);if(req)begin
   serving=1;txn=txn+1;
   if(addr>=400000)ib=400000;else if(addr>=300000)ib=300000;else if(addr>=200000)ib=200000;else if(addr>=100000)ib=100000;else $fatal(1,"read outside valid directory BMPs addr=%d",addr);
   iw=640*(ib/100000);ihsrc=480*(ib/100000);flen=54+iw*ihsrc*3;
   off=(addr-ib)*512;if(off<0||off>=((flen+511)/512)*512)$fatal(1,"read outside synthetic BMP %d",addr);
   repeat(37)@(negedge clk);
   for(k=0;k<512;k=k+1)begin
    data=value(off+k);valid=1;@(negedge clk);valid=0;repeat(3)@(negedge clk);
   end
   repeat(11)@(negedge clk);ended=(txn!=1 && txn!=3);@(negedge clk);ended=0;serving=0;wait(!req);repeat(20)@(negedge clk);
  end
 end
end
task pressnext;begin nextkey=0;repeat(41000)@(negedge clk);nextkey=1;repeat(41000)@(negedge clk);end endtask
integer n,seen=0,previndex=-1;
always@(negedge clk)if(shown&&!loading&&dut.img_idx!=previndex)begin
 previndex=dut.img_idx;seen=seen+1;$display("DISPLAY index=%d cycle=%d",previndex,cycle);
end
initial begin
 repeat(8)@(negedge clk);rst=0;start=1;@(negedge clk);start=0;
 wait(shown&&!loading);if(ic!=4||nf!=1)$fatal(1,"boot did not use directory");
 for(n=1;n<4;n=n+1)begin pressnext;wait(!loading&&dut.img_idx==n);end
 $display("PASS four resolutions: every 800x600 pixel and write address exact; lost-end recovery");
 if(ENABLE_FAST)begin
  if(load_sectors[1]>4321 || load_sectors[2]>6241 || load_sectors[3]>7681)
    $fatal(1,"row skipping failed to reduce SD transactions");
 end
 if(!ENABLE_FAST)begin $display("PASS baseline performance run");$finish;end
 // Cancel a real in-flight image sector. No req withdrawal before its end.
 pressnext;wait(!serving);wait(serving);lock=1;repeat(200)@(negedge clk);
 if(!req)$fatal(1,"cancel abandoned in-flight sector");
 wait(!loading&&!req);repeat(100)@(negedge clk);if(shown)$fatal(1,"aborted image remains valid");
 lock=0;wait(shown&&!loading);if(dut.img_idx!=0)$fatal(1,"exit failed to reload image");
 $display("PASS in-flight mode handoff and fresh image after exit");
 autokey=0;repeat(41000)@(negedge clk);autokey=1;
 prevnf=nf;wait(dut.img_idx==1&&!loading);wait(dut.img_idx==2&&!loading);
 if(nf-prevnf!=2)$fatal(1,"prefetch duplicated a frame delta=%d",nf-prevnf);
 $display("PASS prefetch two transitions without duplicate load; transactions=%d frames=%d",txn,nf);$finish;
end
initial begin #(64'd6000000000);$fatal(1,"integration timeout state=%d req=%b load=%b pixels=%d frames=%d pf=%d",st,req,loading,framewords,nf,dut.pf_state);end
endmodule
