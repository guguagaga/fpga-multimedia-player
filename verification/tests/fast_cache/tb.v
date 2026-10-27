`timescale 1ns/1ps
// Real image controller + scaler/expand + SD arbiter + CMD18 cache + writer.
// The card model begins at the command/block interface, not physical SPI pins.
module tb_image_native_cache;
 reg clk=0,memclk=0,rst=1; always #5 clk=~clk;always #4 memclk=~memclk;
 integer scale=1,multi=1,byte_cycles=32,card_latency=29000;
 integer width,height,filelen,cycles=0,started=0,first_pixel=0,completed=0;
 integer cmd17=0,cmd18=0,bytes_wire=0,hits=0,peak_expand=0,peak_source=0;
 integer audio_sectors=0,audio_bytes=0,audio_wait=0,audio_maxwait=0;
 reg wavreq=0,fin=0;wire wavgrant;wire[7:0]wavdata;wire wavvalid,wavend;
 integer audio_deadline=533333;
 wire init,imgreq,imggrant,wreq,ack,wen,shown,loading;
 wire[31:0]imgaddr,wd;wire[15:0]ih;wire[1:0]wb,dp;
 wire[7:0]imgdata;wire imgvalid,imgend;
 wire req;wire[31:0]addr;wire[7:0]data;wire valid,ended;
 wire[4:0]sdstate;
 reg[7:0]dq=0;reg vq=0,eq=0,gq=0;
 always@(posedge clk)begin dq<=imgdata;vq<=imgvalid;eq<=imgend;gq<=imggrant;end
 wire[9:0]used;wire almostfull=(used>=512)||(cycles%25000<1200);
 sd_card_bmp #(.CLK_FREQ_HZ(100000000)) image(
  .clk(clk),.rst(rst),.directory_count(3'd1),.directory0(32'd100),.directory1(0),.directory2(0),.directory3(0),
  .key_next(1'b1),.key_auto(1'b1),.period_code(4'd0),.auto_period_sec(10'd2),.period_reseed(1'b0),
  .bmp_width(16'd640),.bmp_height(16'd480),.display_valid(shown),.img_loading(loading),
  .scan_start_sector(0),.scan_start_sector2(0),.scan_start2(1'b0),.scan_limited(1'b1),
  .write_finish_toggle(fin),.write_buf_idx(wb),.disp_buf_idx(dp),.switch_lock(1'b0),.vid_lock(1'b0),
  .fade_done_pulse(1'b0),.write_req(wreq),.write_req_ack(ack),.write_almost_full(almostfull),
  .write_en(wen),.write_data(wd),.img_h_o(ih),.sd_init_done(init),
  .sd_sec_read(imgreq),.sd_sec_read_addr(imgaddr),.sd_sec_read_data(dq),
  .sd_sec_read_data_valid(vq),.sd_sec_read_end(eq),.sd_grant(gq));
 sd_arbiter arb(.clk(clk),.rst(rst),.img_sd_sec_read(imgreq),.img_sd_sec_read_addr(imgaddr),
  .img_sd_sec_read_data(imgdata),.img_sd_sec_read_data_valid(imgvalid),.img_sd_sec_read_end(imgend),
  .wav_sd_sec_read(wavreq),.wav_sd_sec_read_addr(32'd100000),.wav_sd_sec_read_data(wavdata),
  .wav_sd_sec_read_data_valid(wavvalid),.wav_sd_sec_read_end(wavend),.wav_grant(wavgrant),.img_grant(imggrant),
  .fat_sd_sec_read(1'b0),.fat_sd_sec_read_addr(0),.vid_sd_sec_read(1'b0),.vid_sd_sec_read_addr(0),
  .img_priority(!shown),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),
  .sd_sec_read_data_valid(valid),.sd_sec_read_end(ended));
 wire cmdreq,brreq;wire[47:0]cmd;wire[15:0]nb;
 reg cmdack=0,brvalid=0,brack=0;reg[7:0]brdata=0;
 sd_card_sec_read_write sd(.clk(clk),.rst(rst),.sd_init_done(init),.sd_sec_read(req),.sd_sec_read_addr(addr),
  .multi_en((multi!=0)&&imggrant&&loading),.multi_paced(imggrant),
  .sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),
  .sd_sec_write(1'b0),.sd_sec_write_addr(0),.sd_sec_write_data(8'd0),
  .cmd_req(cmdreq),.cmd_req_ack(cmdack),.cmd_req_error(1'b0),.cmd(cmd),
  .block_read_req(brreq),.block_read_valid(brvalid),.block_read_data(brdata),.block_read_req_ack(brack),
  .rd_nb_blk(nb),.block_write_data_rd(1'b0),.block_write_req_ack(1'b0),.dbg_state(sdstate));
 // Synthetic command/data latency, matching logical SDHC block addressing.
 integer cmddelay=0,cmdwaiting=0,blockactive=0,blockwaiting=0,phase=0,index=0,total=0,lba=0,delayleft=0;
 function[7:0]cardbyte;input integer sector,offset;integer pos,pix;begin
  if(sector==100000) cardbyte=(offset^8'h5a)&255;
  else begin
   pos=(sector-100)*512+offset;
   if(pos<54)begin
    case(pos)
     0:cardbyte="B";1:cardbyte="M";
     2,3,4,5:cardbyte=(filelen>>((pos-2)*8))&255;
     10:cardbyte=54;14:cardbyte=40;
     18,19,20,21:cardbyte=(width>>((pos-18)*8))&255;
     22,23,24,25:cardbyte=(height>>((pos-22)*8))&255;
     26:cardbyte=1;28:cardbyte=24;default:cardbyte=0;
    endcase
   end else if(pos<filelen) begin pix=(pos-54)/3;cardbyte=(pix>>(((pos-54)%3)*8))&255;end
   else cardbyte=8'ha5;
  end
 end endfunction
 always@(negedge clk)begin
  cmdack=0;brvalid=0;brack=0;
  if(!rst)begin
   cycles=cycles+1;
   if(cmdreq&&!cmdwaiting)begin cmdwaiting=1;cmddelay=9;end
   if(cmdwaiting&&cmddelay>0)begin cmddelay=cmddelay-1;if(cmddelay==0)begin
    cmdack=1;lba=cmd[39:8];
    if(cmd[47:40]==17)cmd17=cmd17+1;
    if(cmd[47:40]==18)cmd18=cmd18+1;
   end end
   if(!cmdreq)cmdwaiting=0;
   if(brreq&&!blockwaiting&&!blockactive)begin
    blockwaiting=1;blockactive=1;phase=0;index=0;total=nb*512;delayleft=card_latency;
   end
   if(!brreq)blockwaiting=0;
   if(blockactive)begin
    if(delayleft>0)delayleft=delayleft-1;
    else if(phase==byte_cycles-1)begin
     phase=0;brvalid=1;brdata=cardbyte(lba+index/512,index%512);index=index+1;bytes_wire=bytes_wire+1;
     if(index==total)begin blockactive=0;brack=1;end
     else if(index%512==0)delayleft=96; // token/CRC gap in a CMD18 stream
    end else phase=phase+1;
   end
   if(cycles>=audio_deadline&&!wavreq)begin wavreq=1;audio_bytes=0;audio_wait=0;end
   if(wavreq)begin audio_wait=audio_wait+1;if(audio_wait>audio_maxwait)audio_maxwait=audio_wait;end
   if(sdstate==25)hits=hits+1; // diagnostic only; exact enum not used for correctness
   if(image.u_expand.count>peak_expand)peak_expand=image.u_expand.count;
   if(image.px_fifo_count>peak_source)peak_source=image.px_fifo_count;
   if(image.u_expand.overflow)$fatal(1,"image expansion overflow");
   if(image.px_fifo_full && image.bmp_data_wr_en)$fatal(1,"image source FIFO overflow");
  end
 end
 always@(posedge clk)if(!rst)begin
  if(wavvalid)begin
   if(wavdata!==((audio_bytes^8'h5a)&255))$fatal(1,"audio data changed");
   audio_bytes=audio_bytes+1;
  end
  if(wavend)begin
   if(audio_bytes!=512)$fatal(1,"audio length %d",audio_bytes);
   wavreq=0;audio_sectors=audio_sectors+1;audio_deadline=audio_deadline+533333;
  end
 end
 wire aclr,mwen,mfin;wire[23:0]maddr;
 reg[31:0]queue[0:2047];integer wp=0,rp=0,pixels=0,bank=0;assign used=wp-rp;
 frame_fifo_write #(.ADDR_BITS(24),.BURST_SIZE(256),.FRAME_WIDTH(800),.FRAME_HEIGHT(600)) writer(
  .rst(rst),.mem_clk(memclk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),
  .App_rd_busy(cycles%37<5),.App_wr_en(mwen),.App_wr_addr(maddr),.write_req(wreq),.write_req_ack(ack),
  .write_finish(mfin),.write_addr_0(24'd0),.write_addr_1(24'd480000),.write_addr_2(24'd960000),
  .write_addr_3(24'd0),.write_addr_index(wb),.write_len(24'd480000),.write_img_h(ih),.write_top_down(1'b0),.fifo_aclr(aclr),.rdusedw(used));
 always@(posedge clk or posedge aclr)begin
  if(aclr)wp=0;else if(wen)begin
   if(wp-rp>=1023)$fatal(1,"writer FIFO overflow");
   if(!first_pixel)first_pixel=cycles;
   queue[wp%2048]=wd;wp=wp+1;
  end
  if(wreq&&!started)started=cycles;
 end
 integer x,y,expected,expectedaddr;
 always@(posedge memclk or posedge aclr)begin
  if(aclr)begin rp=0;pixels=0;bank=wb;end
  else begin
   if(mwen)begin
    x=(pixels%800)*4/5;y=(pixels/800)*4/5;
    expected=y*(height/480)*width+x*(width/640);
    expectedaddr=bank*480000+(599-pixels/800)*800+pixels%800;
    if(maddr!==expectedaddr[23:0])$fatal(1,"writer address %d expected %d",maddr,expectedaddr);
    if(rp>=wp)$fatal(1,"writer underflow");
    if(queue[rp%2048]!=={expected[23:0],8'd0})$fatal(1,"pixel %d got %h expected %h",pixels,queue[rp%2048],{expected[23:0],8'd0});
    rp=rp+1;pixels=pixels+1;
   end
   if(mfin)begin
    if(pixels!=480000)$fatal(1,"frame size %d",pixels);
    fin=~fin;completed=cycles;
   end
  end
 end
 initial begin
  if($value$plusargs("SCALE=%d",scale))begin end
  if($value$plusargs("MULTI=%d",multi))begin end
  if($value$plusargs("BYTE_CYCLES=%d",byte_cycles))begin end
  if($value$plusargs("LATENCY=%d",card_latency))begin end
  width=1280;height=960;filelen=54+width*height*3;
  repeat(25)@(negedge clk);rst=0;
  wait(shown);repeat(50)@(negedge clk);
  if(!completed||pixels!=480000||audio_sectors<1)$fatal(1,"coverage missing");
  $display("PASS fast image SD cache scale=%0d multi=%0d cycles=%0d load_cycles=%0d first_pixel=%0d cmd17=%0d cmd18=%0d wire_bytes=%0d audio_sectors=%0d audio_max_wait=%0d peak_expand=%0d peak_source=%0d pixels=%0d",scale,multi,completed,completed-started,first_pixel,cmd17,cmd18,bytes_wire,audio_sectors,audio_maxwait,peak_expand,peak_source,pixels);
  $finish;
 end
 initial begin #2000000000;$fatal(1,"image SD timeout cycles=%d pixels=%d sdstate=%d",cycles,pixels,sdstate);end
endmodule
