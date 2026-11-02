`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,nextkey=1,autokey=1,reseed=0,allow=0,video=0,lock=0,fade_done=0,fin=0,ack=0,valid=0,ended=0,err=0;
always #5 clk=~clk;
wire req,wreq,wen,shown,loading,fade_req;wire[31:0]addr,wd;wire[1:0]wb,db;
sd_card_bmp #(.CLK_FREQ_HZ(2000),.ENABLE_ZOOM(1)) dut(.clk(clk),.rst(rst),.zoom_small(1'b0),
.directory_count(3'd3),.directory0(32'd100),.directory1(32'd200),.directory2(32'd300),.directory3(32'd0),
.key_next(nextkey),.key_auto(autokey),.period_code(4'd0),.auto_period_sec(10'd2),.period_reseed(reseed),
.bmp_width(16'd640),.bmp_height(16'd480),.display_valid(shown),.img_loading(loading),
.scan_start_sector(32'd100),.scan_start_sector2(32'd0),.scan_start2(1'b0),.scan_limited(1'b1),
.write_finish_toggle(fin),.write_buf_idx(wb),.disp_buf_idx(db),.switch_lock(lock),.vid_lock(video),
.fade_req_toggle(fade_req),.fade_done_pulse(fade_done),.write_req(wreq),.write_req_ack(ack),.write_almost_full(1'b0),.write_en(wen),.write_data(wd),
.sd_init_done(!rst),.sd_error(err),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(8'd0),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),.sd_grant(req));
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


task reset_edge;
begin
 @(negedge clk);reseed=1;
 @(posedge clk);#1;
 if(dut.sec_cnt!==0 || dut.auto_cnt!==0 || dut.auto_due_q!==0)
  $fatal(1,"reset priority at timer boundary sec=%0d phase=%0d",dut.sec_cnt,dut.auto_cnt);
 @(negedge clk);reseed=0;
end
endtask
integer start_t,idx;reg f;
initial begin
 cycles(8);rst=0;wait(shown&&!loading);cycles(5);on;
 wait(dut.auto_tick);reset_edge;
 wait(dut.auto_due_q);f=fade_req;idx=dut.img_idx;reset_edge;start_t=ticks;
 cycles(3990);
 if(fade_req!=f || dut.img_idx!=idx)$fatal(1,"stale deadline survived reseed");
 wait(dut.img_idx!=idx);
 if(ticks-start_t<4000)$fatal(1,"early publication");
 $display("PASS exact second-tick reset and stale deadline cancellation");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
