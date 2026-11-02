`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,nextkey=1,autokey=1,reseed=0,allow=0,video=0,lock=0,fade_done=0,fin=0,ack=0,valid=0,ended=0,err=0;
always #5 clk=~clk;
wire req,wreq,wen,shown,loading,fade_req;wire[31:0]addr,wd;wire[1:0]wb,db;
reg[3:0]preset=0;wire[3:0]code;wire[9:0]period;wire boundary;
carousel_period_cfg cfg(.clk(clk),.rst(rst),.preset_sel(preset),.boundary(boundary),.preset_code(code),.period_sec(period));
sd_card_bmp #(.CLK_FREQ_HZ(2000),.ENABLE_ZOOM(1)) dut(.clk(clk),.rst(rst),.zoom_small(1'b0),
.directory_count(3'd3),.directory0(32'd100),.directory1(32'd200),.directory2(32'd300),.directory3(32'd0),
.key_next(nextkey),.key_auto(autokey),.period_code(code),.auto_period_sec(period),.cfg_boundary_o(boundary),.period_reseed(reseed),
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


integer i,start_t,period_t,next_code,idx,oldloads;reg checking=0;
always @(posedge clk) if(checking && dut.load_finish && dut.pf_state==2 && boundary)
 $fatal(1,"background completion changed configuration boundary");
initial begin
 cycles(8);rst=0;wait(shown&&!loading);cycles(10);
 for(i=0;i<16;i=i+1)begin
   if(dut.auto_on)toggle;
   preset=i;cycles(4);if(code!=i)$fatal(1,"preset off mode");
   on;start_t=ticks;period_t=period*2000;checking=1;
   wait(dut.pf_state==1);next_code=(i+1)%16;preset=next_code;
   wait(dut.pf_state==2);cycles(5);
   if(code!=i)$fatal(1,"preset applied during prefetch");
   wait(fade_req!=fadeprev); // request, before the model observes it
   if(ticks-start_t<period_t-3 || ticks-start_t>period_t+5)
      $fatal(1,"deadline i=%0d age=%0d expected=%0d",i,ticks-start_t,period_t);
   idx=dut.img_idx;wait(dut.img_idx!=idx);cycles(2);
   if(code!=next_code || dut.sec_cnt!=0 || dut.auto_cnt>4)
      $fatal(1,"publication reset/config i=%0d",i);
   checking=0;$display("PASS preset=%0d period_cycles=%0d new_code=%0d",i,period_t,code);
   cycles(100);
 end
 // Bad background load must not reset dwell or publish a partial image.
 if(dut.auto_on)toggle;preset=0;cycles(5);delay_cycles=3000;on;
 wait(dut.pf_state==1);idx=dut.img_idx;wait(req);err=1;
 wait(!loading);cycles(10);
 if(dut.img_idx!=idx || dut.sec_cnt!=2)$fatal(1,"error reset/publish");
 oldloads=loads;cycles(5000);if(loads!=oldloads)$fatal(1,"error auto retry storm");
 err=0;next;wait(dut.img_idx!=idx);cycles(3);
 if(dut.sec_cnt!=0)$fatal(1,"manual recovery dwell");
 $display("PASS16 presets 2..600s, boundary change, failed prefetch and manual recovery");$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
