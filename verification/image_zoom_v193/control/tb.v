`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,nextkey=1,autokey=1,reseed=0,allow=0,video=0,lock=0,fade_done=0,fin=0,ack=0,valid=0,ended=0,err=0;
always #5 clk=~clk;
wire req,wreq,wen,shown,loading,fade_req;wire[31:0]addr,wd;wire[1:0]wb,db;
reg zoom=0; sd_card_bmp #(.CLK_FREQ_HZ(2000),.ENABLE_ZOOM(1)) dut(.clk(clk),.rst(rst),.zoom_small(zoom),
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


integer publications=0;reg prevshown=0;reg[1:0]prevbank=0;
always @(negedge clk) begin
 if(dut.load_start_pulse)$display("LOAD t=%0d idx=%0d zoom=%0d pending=%b error=%b",ticks,dut.load_idx,dut.load_zoom_small,dut.next_req_pending,dut.image_load_error);
 if(dut.key_next_press)$display("KEY t=%0d pending=%b error=%b",ticks,dut.next_req_pending,dut.image_load_error);
end
always @(negedge clk)begin
 if(shown && (!prevshown || db!=prevbank))begin
  publications=publications+1;
  $display("PUBLISH t=%0d idx=%0d zoom=%0d bank=%0d",ticks,dut.img_idx,dut.display_zoom_small,db);
 end
 prevshown=shown;prevbank=db;
 if(wen && shown && wb==db)$fatal(1,"writing displayed bank");
end
task settled(input integer expected_idx,input integer expected_zoom);
begin
 wait(shown && !loading && !lock && dut.display_zoom_small==expected_zoom);
 cycles(5);
 if(dut.img_idx!=expected_idx)$fatal(1,"resize changed image index");
end endtask
integer idx,i,oldloads;reg oldbank;
initial begin
 cycles(8);rst=0;settled(0,0);
 zoom=1;settled(0,1);zoom=0;settled(0,0);
 // Completed next-frame cache is discarded before re-rendering current image.
 on;wait(dut.pf_state==2);idx=dut.img_idx;zoom=1;settled(idx,1);
 wait(dut.pf_state==2);idx=dut.img_idx;next;settled((idx+1)%3,1);
 // Toggle while background SD read is in flight; it must drain, not vanish.
 delay_cycles=900;wait(dut.pf_state==1);wait(req);idx=dut.img_idx;zoom=0;
 cycles(15);if(!req)$fatal(1,"zoom withdrew active SD request");settled(idx,0);
 // Rapid switches coalesce to final level. Re-renders never advance index.
 toggle;if(dut.auto_on)$fatal(1,"auto off");delay_cycles=300;
 for(i=0;i<20;i=i+1)begin zoom=~zoom;cycles(35);end
 zoom=1;idx=dut.img_idx;settled(idx,1);oldloads=loads;cycles(1000);
 if(loads!=oldloads)$fatal(1,"reload repeated after settling");
 // Switch while video owns the path; image reload uses final switch on return.
 video=1;cycles(100);zoom=0;cycles(100);if(shown)$fatal(1,"video invalidation");
 video=0;settled(0,0);
 // Failed resize preserves the visible image and does not retry forever.
 zoom=1;wait(req);err=1;wait(!loading);cycles(10);oldloads=loads;
 if(dut.display_zoom_small!=0)$fatal(1,"bad resize published");
 cycles(3000);if(loads!=oldloads)$fatal(1,"resize error retry storm");
 err=0;zoom=0;cycles(20);zoom=1; // same failed mode requires manual recovery
 next;wait(dut.img_idx!=0);settled(1,1);
 $display("PASS resize,current index,prefetch,rapid20,video,error,manual recovery publications=%0d",publications);$finish;
end
initial begin #10000000;$fatal(1,"timeout idx=%0d zoom=%0d pf=%0d busy=%b error=%b",dut.img_idx,dut.display_zoom_small,dut.pf_state,loading,dut.image_load_error);end
endmodule
