`timescale 1ns/1ps
module tb;
integer kind;
wire [31:0] stream_address;wire stream_consume;integer stream_count=0;
integer fw,fh,left,top;

parameter EARLY=0;
reg zoom=0;wire[1:0]display_bank,write_bank;reg[1:0]last_bank=0;reg previous_display=0;integer base_fw,base_fh;
integer n=0,txns=0;
reg clk=0;always #5.5 clk=~clk;
reg rst=1,fin=0;wire req,wreq,wen,shown,loading;wire[31:0]addr,wd;wire[15:0]ih;
reg[7:0]data=0;reg valid=0,ended=0,grant=0;wire[3:0]st;
reg reseed=0;wire audio_ready; reg ack=0;integer cycle=0;wire blocked=(cycle%97<21);

wire[7:0]image_data,audio_data;wire image_valid,image_end,image_grant;
wire audio_valid,audio_end,audio_grant,card_req;wire[31:0]card_addr;
reg audio_req=0;integer fifo=6144,min_fifo=8192,audio_tick=0,audio_sectors=0,audio_wait=0,max_audio_wait=0;
reg audio_go=0;reg permission=0;assign audio_ready=permission;
reg img_priority=1;
always @(posedge clk)begin
 if(rst)begin permission<=0;img_priority<=1;end
 else begin permission<=fifo>=6144;img_priority<=!shown || (loading && fifo>=4096);end
end
wire fat_req,fat_valid,fat_end,mounted,stream_valid,stream_empty,stream_error;
wire [31:0]fat_addr;wire[7:0]fat_data;wire[3:0]image_count;reg scan=0;
initial begin wait(!rst);@(negedge clk);scan=1;@(negedge clk);scan=0;end
fat32_list #(.STREAM_IMAGES(1)) directory(.clk(clk),.rst(rst),.scan_start(scan),.sd_init_done(!rst),
 .image_pause(fifo<4096 && audio_req),.image_consume(stream_consume),.image_valid(stream_valid),
 .image_empty(stream_empty),.image_error(stream_error),.image_lba(stream_address),.sd_read_error(1'b0),
 .sd_sec_read(fat_req),.sd_sec_read_addr(fat_addr),.sd_sec_read_data(fat_data),.sd_sec_read_data_valid(fat_valid),
 .sd_sec_read_end(fat_end),.list_ready(mounted),.list_idx(5'd0),.image_count_o(image_count));
function[7:0]filesystem_byte(input integer sector,input integer offset);
 integer entry,pos,c;
 begin filesystem_byte=0;
 if(sector==0)begin case(offset)
 0:filesystem_byte=235;12:filesystem_byte=2;13:filesystem_byte=1;14:filesystem_byte=2;16:filesystem_byte=2;
 32:filesystem_byte=128;33:filesystem_byte=132;34:filesystem_byte=30;36:filesystem_byte=8;44:filesystem_byte=2;
 endcase end
 else if(sector==18)begin
 entry=offset/32;pos=offset%32;c=entry==0?84:9984;
 if(entry<2)case(pos)
 0:filesystem_byte=65+entry;1,2,3,4,5,6,7:filesystem_byte=32;
 8:filesystem_byte=kind==0?66:81;9:filesystem_byte=kind==0?77:79;10:filesystem_byte=kind==0?80:73;
 11:filesystem_byte=32;26:filesystem_byte=c&255;27:filesystem_byte=(c>>8)&255;30:filesystem_byte=16;
 endcase
 end
 end
endfunction
always @(posedge clk)if(!rst && stream_error)$fatal(1,"directory runtime error");
sd_arbiter #(.PREFETCH_AWARE(1),.MAX_DEFER_CYCLES(1400000)) arb(
 .clk(clk),.rst(rst),.defer_audio(1'b0),.img_priority(img_priority),
 .img_sd_sec_read(req),.img_sd_sec_read_addr(addr),.img_sd_sec_read_data(image_data),.img_sd_sec_read_data_valid(image_valid),.img_sd_sec_read_end(image_end),.img_grant(image_grant),
 .wav_sd_sec_read(audio_req),.wav_sd_sec_read_addr(32'd999999),.wav_sd_sec_read_data(audio_data),.wav_sd_sec_read_data_valid(audio_valid),.wav_sd_sec_read_end(audio_end),.wav_grant(audio_grant),
 .fat_sd_sec_read(fat_req),.fat_sd_sec_read_addr(fat_addr),.fat_sd_sec_read_data(fat_data),.fat_sd_sec_read_data_valid(fat_valid),.fat_sd_sec_read_end(fat_end),.vid_sd_sec_read(1'b0),.vid_sd_sec_read_addr(32'd0),
 .sd_sec_read(card_req),.sd_sec_read_addr(card_addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended));
always @(posedge clk)if(!rst)begin
 if(audio_valid)fifo=fifo+1;
 if(audio_go)begin
  audio_tick=audio_tick+1;
  if(audio_tick==470)begin
   audio_tick=0;if(fifo<=0)$fatal(1,"audio underflow");fifo=fifo-1;
  end
  if(fifo<min_fifo)min_fifo=fifo;
 end
 if(fifo>8192)$fatal(1,"audio overflow");
 if(audio_end)begin audio_req=0;audio_sectors=audio_sectors+1;end
 else if(audio_go && fifo<6144)audio_req=1;
 if(audio_req&&!audio_grant)begin audio_wait=audio_wait+1;if(audio_wait>max_audio_wait)max_audio_wait=audio_wait;end
 else audio_wait=0;
end
wire fade_req;reg fadeprev=0,fade_done=0,transition=0;
integer fade_ticks=0;
always @(negedge clk)if(!rst)begin
 fade_done=0;
 if(fade_req!=fadeprev)begin fadeprev=fade_req;fade_ticks=100;transition=1;end
 if(fade_ticks>0)begin fade_ticks=fade_ticks-1;if(fade_ticks==50)fade_done=1;if(fade_ticks==0)transition=0;end
end
integer frames=0,shown_count=0,last_idx=-1,boot_cycle=0,auto_start=0,load_start_cycle=0,first_data_cycle=0;
integer load_count=0,flip1=0,flip2=0,old_pf=0;
reg[1:0]old_load_idx=0;reg previous_wreq=0;
initial begin
 wait(shown_count==3);wait(!transition);repeat(10)@(negedge clk);auto_go_setup;
end
task auto_go_setup;begin audio_go=1;reseed=1;auto_start=cycle;repeat(3)@(negedge clk);reseed=0;$display("AUTO_ARM auto=%b count=%d kicked=%b",dut.auto_on,dut.img_found_count,dut.scan_kicked);if(!dut.auto_on)$fatal(1,"auto command not accepted");end endtask
always @(negedge clk)if(!rst)begin
 if(wreq&&!previous_wreq)begin
  fw=dut.load_zoom_small ? base_fw*3/4 : base_fw;
  fh=dut.load_zoom_small ? base_fh*3/4 : base_fh;
  if(fw<1)fw=1;if(fh<1)fh=1;left=(1280-fw)/2;top=(720-fh)/2;
  if(shown && write_bank==display_bank)$fatal(1,"writes visible bank");
  if(n!=0 && n!=921600)$fatal(1,"partial frame replaced n=%d",n);
  n=0;load_start_cycle=cycle;first_data_cycle=0;load_count=load_count+1;
  $display("EVENT LOAD id=%0d cycle=%0d pf=%0d",dut.load_idx,cycle,dut.pf_state);
 end
 previous_wreq=wreq;
 if(image_valid&&first_data_cycle==0)first_data_cycle=cycle;
 if(dut.pf_state==2 && old_pf!=2)$display("EVENT READY id=%0d cycle=%0d",dut.pf_idx,cycle);
 old_pf=dut.pf_state;
 if(shown&&(!previous_display || display_bank!=last_bank))begin
  previous_display=1;last_bank=display_bank;
  if(frames<shown_count+1)$fatal(1,"display before complete write");
  last_idx=dut.img_idx;shown_count=shown_count+1;
  $display("EVENT DISPLAY id=%0d cycle=%0d since_auto=%0d",last_idx,cycle,cycle-auto_start);
  if(shown_count==1)begin boot_cycle=cycle;zoom=1;end
  if(shown_count==2)zoom=0;
  if(shown_count<=3 && dut.img_idx!=0)$fatal(1,"resize changed current image");
  if(shown_count==2)flip1=cycle-auto_start;
  if(shown_count==4)begin
   flip2=cycle-auto_start;
   if(load_count!=4 || frames!=4)$fatal(1,"duplicate or incomplete loads");
   $display("PASS EARLY=%0d flip1=%0d flip2=%0d min_fifo=%0d max_audio_wait=%0d frames=%0d sectors=%0d",EARLY,flip1,flip2,min_fifo,max_audio_wait,frames,txns);$finish;
  end
 end
end
sd_card_bmp #(.CLK_FREQ_HZ(2000000),.ENABLE_ZOOM(1),.STREAM_IMAGES(1)) dut(.clk(clk),.rst(rst),.zoom_small(zoom),.disp_buf_idx(display_bank),.write_buf_idx(write_bank),
 .stream_valid(stream_valid),.stream_lba(stream_address),.stream_consume(stream_consume),.directory_count(image_count),.directory0(32'd100),.directory1(32'd10000),.directory2(32'd20000),.directory3(32'd0),.directory4(32'd0),.directory5(32'd0),.directory6(32'd0),.directory7(32'd0),
 .key_next(1'b1),.key_auto(1'b1),.bmp_width(16'd640),.bmp_height(16'd480),
 .period_code(4'd0),.auto_period_sec(10'd2),.period_reseed(reseed),
 .display_valid(shown),.img_loading(loading),.scan_start_sector(32'd100),.scan_start_sector2(32'd0),
 .scan_start2(1'b0),.scan_limited(1'b1),.write_finish_toggle(fin),
 .switch_lock(transition),.vid_lock(1'b0),.fade_done_pulse(fade_done),.fade_req_toggle(fade_req),
 .write_req(wreq),.write_req_ack(ack),.write_almost_full(blocked),
 .write_en(wen),.write_data(wd),.img_h_o(ih),.sd_init_done(mounted),.sd_error(1'b0),
 .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(image_data),.sd_sec_read_data_valid(image_valid),
 .sd_sec_read_end(image_end),.sd_grant(image_grant),.state_code(st));
reg[7:0]hdr[0:511];integer w,h,stride,bytes,sh,step,off,b,x,y,sx,sy,delay_finish=0;
reg[23:0]expected;reg request_seen=0;
function[23:0]colour(input integer x,input integer y);begin colour=((x*73)^(y*101)^(x<<12)^(y<<4))&24'hffffff;end endfunction
function[7:0]value(input integer offset);
 integer pos,ix,iy,ch;reg[23:0]v;
 begin
 value=0;
 if(kind==0)begin
  if(offset<54)value=hdr[offset];
  else begin pos=offset-54;iy=pos/stride;ix=(pos%stride)/3;ch=(pos%stride)%3;
   v=colour(ix,iy);if(ix<w&&iy<h)case(ch)0:value=v[7:0];1:value=v[15:8];2:value=v[23:16];endcase
  end
 end else begin
  if(offset<14)value=hdr[offset];
  else if(offset<14+w*h*4)begin pos=(offset-14)/4;ch=(offset-14)%4;v=colour(pos%w,pos/w);
   case(ch)0:value=8'hfe;1:value=v[23:16];2:value=v[15:8];3:value=v[7:0];endcase
  end else if(offset==14+w*h*4+7)value=1;
 end
 end
endfunction
initial begin
 if(!$value$plusargs("W=%d",w)||!$value$plusargs("H=%d",h)||!$value$plusargs("KIND=%d",kind))$fatal(1,"args");
 $readmemh("header.hex",hdr);
 stride=((w*3+3)/4)*4;
 step=kind==0&&w%4==0&&w>=640&&(h==960||h==1440||h==1920)?h/480:1;sh=h/step;
 if(w*720>=h*1280)begin fw=1280;fh=h*1280/w;if(fh<1)fh=1;end
 else begin fh=720;fw=w*720/h;if(fw<1)fw=1;end
 base_fw=fw;base_fh=fh;left=(1280-fw)/2;top=(720-fh)/2;
 repeat(8)@(negedge clk);#1;rst=0;
 forever begin
  @(negedge clk);
  if(card_req)begin
   txns=txns+1;grant=1;off=(card_addr-(card_addr>=20000?20000:card_addr>=10000?10000:100))*512;
   if(off<0 && card_addr!=0 && card_addr!=18)$fatal(1,"wrong sector");
   repeat((txns%23==0)?20000:500)@(negedge clk);
   for(b=0;b<512;b=b+1)begin
    data=(card_addr==0 || card_addr==18)?filesystem_byte(card_addr,b):audio_grant ? 8'h55 : value(off+b);valid=1;@(negedge clk);valid=0;
    repeat(3)@(negedge clk);
   end
   ended=1;@(negedge clk);ended=0;grant=0;
   wait(!card_req);repeat(20)@(negedge clk);
  end
 end
end
always@(negedge clk)if(!rst)begin
 cycle=cycle+1;ack=0;
 if(!wreq)request_seen=0;
 if(wreq&&!request_seen)begin ack=1;request_seen=1;end
 if(wen)begin
  x=n%1280;y=n/1280;expected=0;
  if(x>=left&&x<left+fw&&y>=top&&y<top+fh)begin
   sx=(x-left)*w/fw;sy=((y-top)*sh/fh)*step;expected=colour(sx,sy);
  end
  if(n>=921600||wd!=={expected,8'd0})$fatal(1,"PIXEL n=%d got=%h expected=%h source=%d,%d",n,wd,{expected,8'd0},sx,sy);
  n=n+1;if(n==921600)begin delay_finish=30;frames=frames+1;$display("EVENT WRITTEN id=%0d cycle=%0d load_cycles=%0d",dut.load_idx,cycle,cycle-load_start_cycle);end
 end
 if(delay_finish>1)delay_finish=delay_finish-1;
 else if(delay_finish==1)begin delay_finish=0;fin=~fin;end
 if(cycle%1000000==0)$display("AUTO_STATE auto=%b sec=%d cnt=%d zoom=%b stale=%b lock=%b error=%b pf=%d first=%b",dut.auto_on,dut.sec_cnt,dut.auto_cnt,dut.zoom_reload,dut.zoom_stale_prefetch,transition,dut.image_load_error,dut.pf_state,dut.first_image_committed);
 if(cycle%1000000==0)$display("PROGRESS cycle=%0d n=%0d state=%0d req=%b card_req=%b arb=%0d audio_req=%b fifo=%0d qoi=%0d fit=%0d ack=%b wreq=%b",cycle,n,st,req,card_req,arb.sel,audio_req,fifo,dut.bmp_read_m0.u_qoi.state,dut.u_image_fit.state,ack,wreq);
 if(loading&&cycle-load_start_cycle>6000000)$fatal(1,"load watchdog n=%0d state=%0d qoi=%0d fit=%0d qpos=%0d qhave=%b qpending=%b qvalid=%b sectors=%0d addr=%0d",n,st,dut.bmp_read_m0.u_qoi.state,dut.u_image_fit.state,dut.bmp_read_m0.q_pos,dut.bmp_read_m0.q_have,dut.bmp_read_m0.q_pending,dut.bmp_read_m0.q_valid,txns,addr);
 if(cycle>23000000)$fatal(1,"timeout n=%d state=%d image_error=%b fitstate=%d",n,st,dut.image_load_error,dut.u_image_fit.state);
end
endmodule
