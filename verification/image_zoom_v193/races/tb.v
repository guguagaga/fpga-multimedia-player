`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,nextkey=1,autokey=1,reseed=0,allow=0,video=0,lock=0,fade_done=0,fin=0,ack=0,valid=0,ended=0,err=0;
always #5 clk=~clk;
wire req,wreq,wen,shown,loading,fade_req;wire[31:0]addr,wd;wire[1:0]wb,db;
reg zoom=1; sd_card_bmp #(.CLK_FREQ_HZ(2000),.ENABLE_ZOOM(1)) dut(.clk(clk),.rst(rst),.zoom_small(zoom),
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



integer pubs=0;reg ps=0;reg[1:0]pb=0;integer expected_idx,oldloads;
always @(negedge clk)begin
 if(shown&&(!ps||db!=pb))begin pubs=pubs+1;$display("DISPLAY idx=%0d mode=%b pubs=%0d",dut.img_idx,dut.display_zoom_small,pubs);end
 ps=shown;pb=db;
 if(wen&&shown&&wb==db)$fatal(1,"writes visible buffer");
end
task settle(input integer idx,input integer mode);begin
 wait(shown&&!loading&&!lock&&dut.display_zoom_small==mode&&dut.img_idx==idx);cycles(5);
end endtask
initial begin
 cycles(8);rst=0;settle(0,1);
 // A manual key during current-image resize is queued exactly once.
 delay_cycles=700;zoom=0;wait(req);next;
 settle(1,0);oldloads=loads;cycles(1000);
 if(loads!=oldloads)$fatal(1,"queued next duplicated");
 // Finish acknowledged fade, then apply newest zoom without changing index.
 zoom=1;wait(lock);zoom=0;settle(1,0);oldloads=loads;cycles(1000);
 if(loads!=oldloads)$fatal(1,"fade reloaded repeatedly");
 // Prepared next image already fading: next image commits, then resizes.
 delay_cycles=100;on;wait(dut.pf_state==2);nextkey=0;
 wait(dut.pf_flip_pend);zoom=1;nextkey=1;
 settle(2,1);toggle;cycles(100);
 // Mode toggles twice while SD prefetch is active; final original mode wins.
 on;delay_cycles=900;wait(dut.pf_state==1);wait(req);zoom=0;cycles(30);zoom=1;
 wait(dut.pf_state==2);cycles(10);
 if(dut.img_idx!=2||dut.load_zoom_small!=1)$fatal(1,"prefetch mode identity");
 video=1;cycles(80);zoom=0;cycles(80);video=0;settle(0,0);
 $display("PASS boot small,queued key,fade toggles,prefetch flip,double toggle,video recovery pubs=%0d",pubs);$finish;
end
initial begin #20000000;$fatal(1,"timeout idx=%0d mode=%b pf=%0d auto=%b",dut.img_idx,dut.display_zoom_small,dut.pf_state,dut.auto_on);end
endmodule
