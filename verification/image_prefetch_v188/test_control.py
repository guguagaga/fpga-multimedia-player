from pathlib import Path
import subprocess,json,re
R=Path(__file__).resolve().parent;P=R/'candidate/project';T=R/'tests/control';T.mkdir(exist_ok=True)
src=(P/'user_source/hdl_source/SD/bmp_read.v').read_text();header=src[src.index('module bmp_read'):src.index(');')+2]
model=header+'''
reg busy=0,aborting=0;integer pixels=0;
assign ready=!busy;
assign bmp_data_wr_en=busy&&sd_sec_read&&sd_sec_read_data_valid&&!aborting&&!load_abort;
assign bmp_data=24'h112233;assign img_h_o=1;assign img_w_o=8;
assign source_top_down=1;assign scan_sector_o=0;
always @(posedge clk)begin
 if(rst||!sd_init_done)begin busy<=0;aborting<=0;write_req<=0;sd_sec_read<=0;load_error<=0;scan_done<=0;scan_found_valid<=0;scan_found_total<=0;scan_found_sector<=0;state_code<=0;aspect_h_o<=1;end
 else begin
  if(load_start&&!busy)begin busy<=1;write_req<=1;load_error<=0;aborting<=0;sd_sec_read_addr<=load_sector;end
  if(busy&&write_req&&write_req_ack)begin write_req<=0;sd_sec_read<=1;end
  if(busy&&load_abort)begin aborting<=1;if(!sd_sec_read)begin busy<=0;write_req<=0;end end
  if(sd_sec_read&&sd_sec_read_end)begin busy<=0;sd_sec_read<=0;load_error<=sd_error;end
 end
end
endmodule
module image_fit_720p(input clk,rst,frame_start,input[15:0]src_w,src_h,aspect_h,input in_valid,input[23:0]in_pixel,output high,overflow,input out_blocked,output out_valid,output[23:0]out_pixel);
assign high=out_blocked;assign overflow=0;assign out_valid=in_valid&&!frame_start;assign out_pixel=in_pixel;
endmodule
'''
(T/'models.v').write_text(model)
tb='''`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,nextkey=1,autokey=1,reseed=0,allow=0,video=0,lock=0,fade_done=0,fin=0,ack=0,valid=0,ended=0,err=0;
always #5 clk=~clk;
wire req,wreq,wen,shown,loading,fade_req;wire[31:0]addr,wd;wire[1:0]wb,db;
sd_card_bmp #(.CLK_FREQ_HZ(2000),.EARLY_PREFETCH_EN(1)) dut(.clk(clk),.rst(rst),
.directory_count(3'd3),.directory0(32'd100),.directory1(32'd200),.directory2(32'd300),.directory3(32'd0),
.key_next(nextkey),.key_auto(autokey),.period_code(4'd0),.auto_period_sec(10'd2),.period_reseed(reseed),.prefetch_audio_ready(allow),
.bmp_width(16'd640),.bmp_height(16'd480),.display_valid(shown),.img_loading(loading),
.scan_start_sector(32'd100),.scan_start_sector2(32'd0),.scan_start2(1'b0),.scan_limited(1'b1),
.write_finish_toggle(fin),.write_buf_idx(wb),.disp_buf_idx(db),.switch_lock(lock),.vid_lock(video),
.fade_req_toggle(fade_req),.fade_done_pulse(fade_done),.write_req(wreq),.write_req_ack(ack),.write_almost_full(1'b0),.write_en(wen),.write_data(wd),
.sd_init_done(!rst),.sd_error(err),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(8'd0),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),.sd_grant(req));
integer ticks=0,service=0,np=0,frames=0,loads=0,wait_fin=0;reg request_seen=0,fadeprev=0;integer ft=0;
always @(negedge clk)begin
 ticks=ticks+1;ack=0;valid=0;ended=0;fade_done=0;
 if(!wreq)request_seen=0;
 if(wreq&&!request_seen)begin ack=1;request_seen=1;np=0;loads=loads+1;if(shown&&wb==db)$fatal(1,"writing displayed bank");end
 if(req)begin service=service+1;if(service>=100&&service<108)valid=1;if(service==110)ended=1;end
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
integer oldloads,oldidx,i,request_cycle;
initial begin
 cycles(8);rst=0;wait(shown&&!loading);cycles(3);
 oldloads=loads;on;allow=0;cycles(1000);if(loads!=oldloads)$fatal(1,"early start without reserve");
 allow=1;wait(dut.pf_state==1);allow=0;oldidx=dut.img_idx;wait(dut.pf_state==2);cycles(5);
 if(dut.img_idx!=oldidx || dut.sec_cnt!=0)$fatal(1,"prepared image switched before deadline");
 toggle;if(dut.auto_on!==0)$fatal(1,"auto off failed");oldloads=loads;next;cycles(200);
 if(dut.img_idx==oldidx||loads!=oldloads)$fatal(1,"manual did not consume ready frame exactly once");
 $display("PASS low-water admission and auto-off/manual consumes prepared frame");
 // Cancel a prefetch while its transaction is owned; ownership must drain.
 allow=1;on;wait(dut.pf_state==1);wait(req);cycles(15);video=1;cycles(20);if(!req)$fatal(1,"video switch withdrew active SD request");
 wait(!req);cycles(10);if(shown||dut.pf_state!=0)$fatal(1,"stale prefetch after video lock");video=0;
 wait(shown&&!loading);cycles(5);
 $display("PASS active-transfer video cancel and fresh image recovery");
 // Low reserve eventually uses original half-period fallback.
 toggle;if(dut.auto_on)toggle;allow=0;oldloads=loads;on;request_cycle=ticks;
 wait(loads>oldloads);if(ticks-request_cycle<1900)$fatal(1,"fallback too early");wait(dut.pf_state==2);cycles(5);
 wait(dut.img_idx!=0);$display("PASS low-water half-period fallback and deadline switch");
 // A failed prefetched image must not be published; a manual retry recovers.
 allow=1;wait(dut.pf_state==1);wait(req);oldidx=dut.img_idx;err=1;
 wait(!loading);cycles(5);
 if(dut.img_idx!=oldidx || dut.pf_state!=0)$fatal(1,"failed prefetch became visible");
 err=0;next;wait(dut.img_idx!=oldidx);cycles(100);
 $display("PASS failed prefetch is not displayed and manual retry recovers");
 for(i=0;i<40;i=i+1)begin
  allow=i%2;next;cycles(180);
  if(i%4==0)toggle;
 end
 cycles(10000);if(!shown)$fatal(1,"lost display after repeated controls");
 $display("PASS40 manual actions and10 toggles no displayed-bank overwrite frames=%0d loads=%0d",frames,loads);$finish;
end
initial begin #3000000;$fatal(1,"timeout pf=%0d state=%0d shown=%b load=%b",dut.pf_state,dut.state_code,shown,loading);end
endmodule
'''
(T/'tb.v').write_text(tb)
subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s','tb','-o',str(T/'sim.vvp'),str(T/'tb.v'),str(T/'models.v'),str(P/'user_source/hdl_source/SD/sd_card_bmp.v')],check=True,cwd=T)
p=subprocess.run(['C:/iverilog/bin/vvp.exe',str(T/'sim.vvp')],cwd=T,capture_output=True,text=True)
(T/'console.log').write_text(p.stdout+p.stderr);print(p.stdout,flush=True)
ok=p.returncode==0 and 'PASS40'in p.stdout
(T/'result.json').write_text(json.dumps({'passed':ok,'scope':'Actual sd_card_bmp control/debounce; abstract8-pixel reader/scaler for fast control-state stress. Full pixels and real reader/scaler checked separately.'},indent=2));assert ok
