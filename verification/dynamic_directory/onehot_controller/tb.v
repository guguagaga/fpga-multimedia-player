`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,nextkey=1,autokey=1,reseed=0,allow=0,video=0,lock=0,fade_done=0,fin=0,ack=0,valid=0,ended=0,err=0;
always #5 clk=~clk;
wire req,wreq,wen,shown,loading,fade_req;wire[31:0]addr,wd;wire[1:0]wb,db;
wire iv,ic,failed,dr,ie,ix;wire[31:0]ilba,da;
reg ddv=0,de=0;reg[7:0]dd=0;integer j;
reg scan=0;wire mounted;wire[3:0]mount_count;
initial begin wait(!rst);@(negedge clk);scan=1;@(negedge clk);scan=0;end
fat32_list #(.STREAM_IMAGES(1)) iterator(.clk(clk),.rst(rst),.scan_start(scan),.sd_init_done(!rst),
 .image_pause(video),.image_consume(ic),.image_valid(iv),.image_empty(ie),.image_error(ix),.image_lba(ilba),
 .sd_read_error(1'b0),.sd_sec_read(dr),.sd_sec_read_addr(da),.sd_sec_read_data(dd),
 .sd_sec_read_data_valid(ddv),.sd_sec_read_end(de),.list_ready(mounted),.list_idx(5'd0),.image_count_o(mount_count));
function[7:0]boot_byte(input integer off);
begin boot_byte=0;case(off)
0:boot_byte=235;12:boot_byte=2;13:boot_byte=1;14:boot_byte=2;16:boot_byte=2;
32:boot_byte=8'h80;33:boot_byte=8'h84;34:boot_byte=8'h1e;36:boot_byte=8;44:boot_byte=2;
endcase end endfunction
function[7:0]directory_byte(input integer off);
integer entry,field;begin
 entry=off/32;field=off%32;directory_byte=0;
 if(entry<9)case(field)
  0:directory_byte="I";8:directory_byte="B";9:directory_byte="M";10:directory_byte="P";
  11:directory_byte=32;26:directory_byte=100+entry;29:directory_byte=4;
 endcase
end endfunction
initial begin
 wait(!rst);
 forever begin
  @(negedge clk);
  if(dr)begin
    if(da!=18 && da!=0)$fatal(1,"directory wrong addr %d",da);
    for(j=0;j<512;j=j+1)begin dd=da==0 ? boot_byte(j) : directory_byte(j);ddv=1;@(negedge clk);end
    ddv=0;de=1;@(negedge clk);de=0;repeat(4)@(negedge clk);
  end
 end
end
reg zoom=0; sd_card_bmp #(.CLK_FREQ_HZ(2000),.ENABLE_ZOOM(1),.STREAM_IMAGES(1)) dut(.clk(clk),.rst(rst),.zoom_small(zoom),
.stream_valid(iv),.stream_lba(ilba),.stream_consume(ic),.stream_failed(failed),
.directory_count(mount_count),.directory0(32'd100),.directory1(32'd200),.directory2(32'd300),.directory3(32'd400),.directory4(32'd500),.directory5(32'd600),.directory6(32'd700),.directory7(32'd800),
.key_next(nextkey),.key_auto(autokey),.period_code(4'd0),.auto_period_sec(10'd2),.period_reseed(reseed),
.bmp_width(16'd640),.bmp_height(16'd480),.display_valid(shown),.img_loading(loading),
.scan_start_sector(32'd100),.scan_start_sector2(32'd0),.scan_start2(1'b0),.scan_limited(1'b1),
.write_finish_toggle(fin),.write_buf_idx(wb),.disp_buf_idx(db),.switch_lock(lock),.vid_lock(video),
.fade_req_toggle(fade_req),.fade_done_pulse(fade_done),.write_req(wreq),.write_req_ack(ack),.write_almost_full(1'b0),.write_en(wen),.write_data(wd),
.sd_init_done(mounted),.sd_error(err),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(8'd0),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),.sd_grant(req));
integer delay_cycles=100; integer ticks=0,service=0,np=0,frames=0,loads=0,wait_fin=0;reg request_seen=0,fadeprev=0;integer ft=0;
always @(negedge clk)begin
 ticks=ticks+1;ack=0;valid=0;ended=0;fade_done=0;
 if(!wreq)request_seen=0;
 if(wreq&&!request_seen)begin ack=1;request_seen=1;np=0;loads=loads+1;if(shown&&wb==db)$fatal(1,"writing displayed bank");end
 if(req)begin service=service+1;if(service>=delay_cycles&&service<delay_cycles+8)valid=1;if(service==delay_cycles+10)ended=1;end
 else service=0;
 if(wen)begin np=np+1;if(np==8)wait_fin=8;if(np>8)$fatal(1,"duplicate pixels");end
 if(wait_fin>1)wait_fin=wait_fin-1;else if(wait_fin==1)begin fin=~fin;wait_fin=0;frames=frames+1;end
 if(fade_req!=fadeprev)begin fadeprev=fade_req;ft=60;lock=1;end
 if(ft>0)begin ft=ft-1;if(ft==30)fade_done=1;if(ft==0)lock=0;end
end
task cycles(input integer n);repeat(n)@(negedge clk);endtask
task on;begin reseed=1;cycles(2);reseed=0;end endtask
task next;begin nextkey=0;cycles(65);nextkey=1;cycles(65);end endtask
task toggle;begin autokey=0;cycles(65);autokey=1;cycles(65);end endtask




integer consumes=0,publications=0,last_lba=0,load_lba=0,fail_lba=-1;
reg fault_all=0;reg last_shown=0;reg[1:0]last_bank=0;
always @(posedge clk) if(!rst)begin
 if(ic)begin
   if(!iv)$fatal(1,"consumed unavailable result");
   if(!dut.stream_skip && !dut.image_publish)$fatal(1,"advance before publish");
   if(ilba!=116+consumes%9)$fatal(1,"skip/duplicate consume %d lba %d",consumes,ilba);
   consumes=consumes+1;
 end
end
always @(negedge clk)begin
 err=req && (fault_all || addr==fail_lba);
 if(dut.load_start_pulse)load_lba=dut.load_sector;
 if(shown&&(!last_shown||db!=last_bank))begin
   publications=publications+1;last_lba=load_lba;
   if(last_lba<116||last_lba>124)$fatal(1,"wrong media address %d",last_lba);
 end
 last_shown=shown;last_bank=db;
 if(ix)$fatal(1,"unexpected directory error");
end
integer before_c,before_p,keep;
initial begin
 cycles(8);rst=0;wait(shown&&!loading);on;
 wait(consumes==28);toggle;wait(!loading&&!lock);cycles(100);
 // Prepare an unpublished next image, then zoom. No directory consume.
 on;wait(dut.pf_state==2);toggle;
 before_c=consumes;keep=dut.current_sector;before_p=publications;
 zoom=1;wait(publications>before_p);cycles(100);
 if(consumes!=before_c||dut.current_sector!=keep||!dut.display_zoom_small)$fatal(1,"zoom advanced cursor");
 next;wait(consumes==before_c+1);wait(!loading&&!lock);
 // Enter video during a real pending image transaction; abort must drain.
 on;wait(dut.pf_state==1 && req);before_c=consumes;keep=dut.current_sector;
 video=1;cycles(200);if(consumes!=before_c)$fatal(1,"video abort consumed next");
 video=0;wait(shown&&!loading);cycles(100);
 if(consumes!=before_c||dut.current_sector!=keep)$fatal(1,"video return skipped image");
 toggle;wait(!loading&&!lock);
 // A rejected next file is skipped, and a later valid file still publishes.
 wait(iv);fail_lba=ilba;before_c=consumes;before_p=publications;
 next;wait(consumes>=before_c+2);wait(!loading&&!lock);
 if(publications!=before_p+1)$fatal(1,"bad file was published or recovery missing");
 fail_lba=-1;
 // All following files fail: stop after one finite directory round.
 before_c=consumes;fault_all=1;next;wait(failed);cycles(2000);
 if(consumes!=before_c+9||loading)$fatal(1,"bad-file loop did not stop %d",consumes-before_c);
 $display("PASS iterator+controller 9 images 3 wraps; prefetch/zoom/video drain; bad-file skip and finite all-bad stop; consumes=%d publications=%d",consumes,publications);
 $finish;
end
initial begin #20000000;$fatal(1,"timeout consumes=%d pub=%d pf=%d busy=%d valid=%d blocked=%d",consumes,publications,dut.pf_state,loading,iv,failed);end
endmodule
