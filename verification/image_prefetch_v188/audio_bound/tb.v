`timescale 1ns/1ps
module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg img_req=1,wav_req=0;wire sd_req,ig,wg;wire[31:0]addr;reg[7:0]data=8'h55;reg valid=0,ended=0;
wire[7:0]wd,id;wire wv,we,iv,ie;
integer fifo=6144,min_fifo=8192,ticks=0,seq=0,age=0,abytes=0,wait_audio=0,max_wait=0,images=0,audios=0;
reg current_audio=0,active=0;reg[31:0]held_addr;
sd_arbiter #(.PREFETCH_AWARE(1)) dut(.clk(clk),.rst(rst),.defer_audio(1'b0),.img_priority(fifo>=8192),
.img_sd_sec_read(img_req),.img_sd_sec_read_addr(32'd100),.img_sd_sec_read_data(id),.img_sd_sec_read_data_valid(iv),.img_sd_sec_read_end(ie),.img_grant(ig),
.wav_sd_sec_read(wav_req),.wav_sd_sec_read_addr(32'd200),.wav_sd_sec_read_data(wd),.wav_sd_sec_read_data_valid(wv),.wav_sd_sec_read_end(we),.wav_grant(wg),
.fat_sd_sec_read(1'b0),.fat_sd_sec_read_addr(32'd0),.vid_sd_sec_read(1'b0),.vid_sd_sec_read_addr(32'd0),
.sd_sec_read(sd_req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended));
always @(posedge clk)if(!rst)begin
 ticks=ticks+1;
 if(ticks%470==0)begin if(fifo==0)$fatal(1,"audio underflow");fifo=fifo-1;end
 if(wv)fifo=fifo+1;
 if(fifo<min_fifo)min_fifo=fifo;
 if(fifo>8192)$fatal(1,"audio overflow");
 if(we)begin wav_req<=0;audios=audios+1;end else if(fifo<6144)wav_req<=1;
 if(wav_req&&!wg)begin wait_audio=wait_audio+1;if(wait_audio>max_wait)max_wait=wait_audio;end else wait_audio=0;
 if(sd_req&&active&&addr!==held_addr)$fatal(1,"ownership changed mid transaction");
 if(ie)images=images+1;
 if(images==12)begin
  if(audios==0||max_wait>1425000)$fatal(1,"unbounded audio admission");
  $display("PASS modeled12 long image transactions max1.4M cycles, continuous48kstereo drain min_fifo=%0d max_audio_wait=%0d audio_sectors=%0d",min_fifo,max_wait,audios);$finish;
 end
end
always @(negedge clk)begin
 valid=0;ended=0;
 if(rst)begin active=0;age=0;end
 else if(!active&&sd_req)begin active=1;age=0;current_audio=wg;held_addr=addr;end
 else if(active)begin
  age=age+1;
  if(current_audio)begin if(age>=64&&age<576)valid=1;if(age==580)ended=1;end
  else begin if(age>=1400000&&age<1400512)valid=1;if(age==1400516)ended=1;end
  if(!sd_req)active=0;
 end
end
initial begin repeat(8)@(negedge clk);rst=0;end
initial begin #200000000;$fatal(1,"timeout");end
endmodule
