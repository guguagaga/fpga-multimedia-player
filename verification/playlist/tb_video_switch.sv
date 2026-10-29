`timescale 1ns/1ps
module tb;
reg clk=0;always #5.5 clk=~clk;
reg rst=1,mode=0,next_req=0,prev_req=0,paused=0;
wire play,select,switching,auto_en,failed;wire[1:0]idx;
reg ready=1,busy=0;integer selection_delay=0,selections=0;
wire req,grant;wire[31:0]addr;
wire last,ended,present,empty,allow,time_toggle;
wire[31:0]base=1000+idx*64;
video_playlist_ctrl #(.SELECT_TIMEOUT(100000)) ctrl(.clk(clk),.rst(rst),.mode_video(mode),.list_ready(1'b1),
 .next_req(next_req),.prev_req(prev_req),.auto_toggle(1'b0),.ended(ended),.io_idle(!req&&!grant),
 .audio_ready(ready),.audio_busy(busy),.available(4'b1111),.index(idx),.engine_play(play),
 .audio_select(select),.switching(switching),.auto_enabled(auto_en),.selection_failed(failed));
always@(posedge clk)begin
 if(select)begin busy<=1;selection_delay<=15;selections<=selections+1;end
 if(selection_delay>0)begin
  selection_delay<=selection_delay-1;
  if(selection_delay==12)ready<=0;
  if(selection_delay==3)ready<=1;
  if(selection_delay==1)busy<=0;
 end
end
wire[7:0]data;wire valid,done;
wire ar_req;wire[31:0]ar_addr;
wire[7:0]ar_data;wire ar_valid,ar_done;
sd_arbiter arb(.clk(clk),.rst(rst),.img_sd_sec_read(1'b0),.img_sd_sec_read_addr(0),
 .wav_sd_sec_read(1'b0),.wav_sd_sec_read_addr(0),.fat_sd_sec_read(1'b0),.fat_sd_sec_read_addr(0),
 .vid_sd_sec_read(req),.vid_sd_sec_read_addr(addr),.vid_sd_sec_read_data(data),
 .vid_sd_sec_read_data_valid(valid),.vid_sd_sec_read_end(done),.vid_grant(grant),.img_priority(1'b0),
 .sd_sec_read(ar_req),.sd_sec_read_addr(ar_addr),.sd_sec_read_data(ar_data),.sd_sec_read_data_valid(ar_valid),.sd_sec_read_end(ar_done));
wire preq;wire[31:0]pa;reg[7:0]pd=0;reg pv=0,pend=0;wire map_error;
fat32_sector_mapper #(.IO_TIMEOUT(100000)) mapper(.clk(clk),.rst(rst),.invalidate(1'b0),.mounted(1'b1),
 .fat_start_lba(32'd16),.data_start_lba(32'd1000),.cluster_shift(4'd0),.max_cluster(28'd500),
 .req(ar_req),.owner(2'd3),.virtual_lba(ar_addr),.file_base_lba(base),.multi(1'b0),.pace(1'b0),
 .data(ar_data),.valid(ar_valid),.done(ar_done),.error(map_error),.sd_req(preq),.sd_lba(pa),
 .sd_data(pd),.sd_valid(pv),.sd_done(pend));
function[15:0]color(input integer n);begin
 case(n)0:color=16'hf800;1:color=16'h07e0;2:color=16'h001f;default:color=16'hffff;endcase
end endfunction
function[7:0]cardbyte(input integer lba,input integer off);
 integer c,k;reg[31:0]v;reg[15:0]rgb;begin
 cardbyte=0;
 if(lba>=16&&lba<20)begin
  c=(lba-16)*128+off/4;v=32'h0fffffff;
  for(k=0;k<4;k=k+1)if(c==2+k*64)v=300+k;
  cardbyte=v>>(8*(off%4));
 end else if(lba>=1000&&lba<=1192&&(lba-1000)%64==0)begin
  case(off)
   0:cardbyte="F";1:cardbyte="P";2:cardbyte="G";3:cardbyte="V";
   4:cardbyte=1;5:cardbyte=12;6:cardbyte=16;8:cardbyte=8;10:cardbyte=15;
   12:cardbyte=10;13:cardbyte=2;16:cardbyte=2;
  endcase
 end else if(lba>=1298&&lba<=1301)begin
  rgb=color(lba-1298);
  if(off<10)case(off%5)
   0:cardbyte=8'h85;1:cardbyte=1;2:cardbyte=rgb[7:0];3:cardbyte=rgb[15:8];4:cardbyte=255;
  endcase
 end
end endfunction
integer b,held_lba,transactions=0;
reg[1:0]held_idx;
initial begin wait(!rst);forever begin
 @(negedge clk);if(preq)begin
  held_lba=pa;held_idx=idx;transactions=transactions+1;
  repeat(20)@(negedge clk);
  for(b=0;b<512;b=b+1)begin
   if(idx!=held_idx)$fatal(1,"identity changed during physical read");
   pd=cardbyte(held_lba,b);pv=1;@(negedge clk);pv=0;@(negedge clk);
  end
  pend=1;@(negedge clk);pend=0;wait(!preq);repeat(4)@(negedge clk);
 end
end end
reg tick=0,finish=0;wire ack,wreq,pe,disp_ok;wire[31:0]pixel;wire[1:0]wb,db;
reg memclk=0;always #4 memclk=~memclk;
wire aclr,pack_valid,mwrite,mfinish;wire[31:0]pack_data;wire[20:0]maddr;
reg[31:0]queue[0:511];integer wp=0,rp=0,frames=0;wire[9:0]used=wp-rp;
rgb565_pair_pack pack(.clk(clk),.clear(rst|aclr),.pixel_valid(pe),.pixel_rgbx(pixel),.word_valid(pack_valid),.word_data(pack_data));
frame_fifo_write #(.ADDR_BITS(21),.BURST_SIZE(8),.FRAME_WIDTH(8),.FRAME_HEIGHT(8)) writer(
 .rst(rst),.mem_clk(memclk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(1'b0),.App_rd_busy(1'b0),
 .App_wr_en(mwrite),.App_wr_addr(maddr),.write_req(wreq),.write_req_ack(ack),.write_finish(mfinish),
 .write_addr_0(21'd0),.write_addr_1(21'd64),.write_addr_2(21'd128),.write_addr_3(21'd0),
 .write_addr_index(wb),.write_len(21'd64),.write_img_h(16'd8),.write_top_down(1'b0),.fifo_aclr(aclr),.rdusedw(used));
always@(posedge clk or posedge aclr)begin
 if(aclr)wp=0;
 else if(!rst&&pack_valid)begin
  if(wp-rp>=512)$fatal(1,"pixel FIFO overflow");queue[wp%512]=pack_data;wp=wp+1;
 end
end
always@(posedge aclr)rp=0;
always@(posedge memclk)begin
 if(!rst&&mwrite)begin
  if(rp==wp)$fatal(1,"pixel FIFO underflow");rp=rp+1;
 end
 if(!rst&&mfinish)begin frames=frames+1;finish=~finish;end
end
wire[12:0]period;reg started=0,toggle=0,observed=0;reg[1:0]observed_buf=0;
reg sample=0,time_q=0;integer cycles=0,pixels=0,grants=0,consumed=0,completed=0;
assign present=play&&disp_ok&&tick&&(!observed||observed_buf!=db);
av_sample_sync #(.LEAD_SAMPLES(1920)) sync(.clk(clk),.rst(rst),.enable_sd(play),.started_sd(started),
 .paused_sd(paused),.draining_sd(1'b0),.frame_toggle_sd(toggle),.samples_per_frame_sd(period),
 .sample_valid(sample),.sample_allow(allow),.time_toggle(time_toggle),.buffering(empty));
video_eof_guard guard(.clk(clk),.rst(rst),.enable(play),.paused(paused),.last_committed(last),
 .frame_presented(present),.budget_empty(empty),.ended(ended));
video_player #(.PLAYLIST_SUPPORT(1),.LEGACY_CODECS(0),.FRAME_PIXELS(128),.FRAME_H(8),.BF_AW(10),.BF_HI(16'd600),.AV_SYNC(1),.AUDIO_MASTER(1)) decoder(
 .clk(clk),.rst(rst),.play(play),.pause(paused),.present_enable(ready&&!busy),.timeline_run(started),
 .audio_frame_tick(time_toggle!=time_q),.audio_clock_active(1'b1),.audio_frame_samples(period),
 .sd_error(map_error),.sd_init_done(1'b1),.start_sector(base),.img_disp_buf(2'd0),
 .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),.sd_grant(grant),
 .write_almost_full(1'b0),.write_req(wreq),.write_req_ack(ack),.write_finish_toggle(finish),
 .pix_en(pe),.pix_data(pixel),.vsync_tick(tick),.wr_buf_idx(wb),.dp_buf_idx(db),.disp_ok(disp_ok),.movie_last_shown(last));
reg old_wreq=0,old_play=0,old_end=0;reg[15:0]rgb;reg[31:0]rgbx;
always@(negedge clk)begin
 cycles=cycles+1;tick=(cycles%500==0);sample=play&&started&&allow&&!paused&&(cycles%2==0);
 if(!play)begin pixels=0;end
 else if(pe)begin
  rgb=color(idx);rgbx={{rgb[15:11],rgb[15:13]},{rgb[10:5],rgb[10:9]},{rgb[4:0],rgb[4:2]},8'd0};
  if(pixel!==rgbx)$fatal(1,"old/wrong pixels index=%d got=%h expected=%h",idx,pixel,rgbx);
  pixels=pixels+1;if(pixels==128)pixels=0;
 end
 if(map_error||failed)$fatal(1,"mapper/controller failure");
end
always@(posedge clk)begin
 time_q<=time_toggle;old_play<=play;old_end<=ended;
 if(!play)begin started<=0;observed<=0;grants<=0;consumed<=0;end
 else begin
  if(present)begin started<=1;observed<=1;observed_buf<=db;toggle<=~toggle;grants<=grants+1;end
  if(sample)consumed<=consumed+1;
  if(ended&&!old_end)begin
   if(grants!=2||consumed!=6400)$fatal(1,"premature EOF grants=%d samples=%d",grants,consumed);
   completed<=completed+1;
  end
 end
end
task press(input integer back);begin
 @(negedge clk);prev_req=back;next_req=!back;
 @(negedge clk);prev_req=0;next_req=0;
 wait(!play);wait(play);
end endtask
integer k;reg[1:0]old_idx;
initial begin
 repeat(8)@(negedge clk);rst=0;mode=1;wait(play);
 // Interrupt actual SD reads and verify the FAT cursor changes to the new file.
 for(k=0;k<12;k=k+1)begin
  if(k%2)wait(grant&&pe);else wait(grant&&preq);
  old_idx=idx;press(k%2);
  if(idx!==(k%2?old_idx-2'd1:old_idx+2'd1))$fatal(1,"manual selection wrong");
 end
 wait(completed==12);mode=0;repeat(2000)@(negedge clk);
 if(play)$fatal(1,"exit failed");
 $display("PASS actual decoder/arbiter/fragmented FAT playlist: 12 manual active-read interruptions, 12 complete automatic movies, frames=%d selections=%d SD_transactions=%d",frames,selections,transactions);$finish;
end
initial begin #20000000;$fatal(1,"timeout idx=%d ctrl=%d decoder=%d grants=%d consumed=%d completed=%d",idx,ctrl.state,decoder.state,grants,consumed,completed);end
endmodule
