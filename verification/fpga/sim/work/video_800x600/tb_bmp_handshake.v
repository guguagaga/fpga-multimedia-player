`timescale 1ns/1ps
module tb_bmp_handshake;
reg clk=0,rst=1,load=0,abortload=0,grant=0,valid=0,ended=0,ack=0;always #5 clk=~clk;
wire req,wreq,ready;wire[31:0]addr;reg[7:0]data=0;
bmp_read #(.SCALING_EN(1)) dut(.clk(clk),.rst(rst),.load_abort(abortload),.sd_grant(grant),
 .bmp_width(16'd640),.bmp_height(16'd480),.scan_start(1'b0),.scan_start2(1'b0),.scan_abort(1'b0),
 .scan_start_sector(32'd0),.scan_start_sector2(32'd0),.scan_max_sector(32'd0),.scan_limited(1'b1),.scan_target_count(3'd4),
 .load_start(load),.load_sector(32'd1434224),.ready(ready),.write_req(wreq),.write_req_ack(ack),.write_almost_full(1'b0),
 .sd_init_done(1'b1),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended));
reg[7:0]h[0:511];integer i,c,waited;
task resetstart;begin
 @(negedge clk);rst=1;load=0;abortload=0;grant=0;valid=0;ended=0;ack=0;
 repeat(6)@(negedge clk);rst=0;load=1;@(negedge clk);load=0;wait(req);@(negedge clk);
end endtask
task sector(input drop);begin
 grant=1;
 for(i=0;i<512;i=i+1)begin valid=1;data=h[i];@(negedge clk);valid=0;repeat(3)@(negedge clk);end
 repeat(8)@(negedge clk);grant=0;ended=!drop;@(negedge clk);ended=0;
end endtask
initial begin
 for(i=0;i<512;i=i+1)h[i]=0;
 h[0]="B";h[1]="M";h[2]=8'h36;h[3]=8'h10;h[4]=8'h0e;
 h[10]=54;h[14]=40;h[18]=8'h80;h[19]=2;h[22]=8'he0;h[23]=1;h[26]=1;h[28]=24;
 resetstart;sector(1);wait(wreq);if(req||dut.state!=dut.ST_LOAD_WAIT)$fatal(1,"lost header end stuck");
 $display("PASS lost header end recovered after ownership release");
 @(negedge clk);ack=1;@(negedge clk);ack=0;wait(req);@(negedge clk);sector(1);
 waited=0;while(req&&waited<60100)begin @(negedge clk);waited=waited+1;end
 if(req||addr!=1434225)$fatal(1,"lost data end did not advance exactly once");
 repeat(10)@(negedge clk);
 if(addr!=1434225)$fatal(1,"recovered end advanced more than one sector");
 $display("PASS lost data end advances exactly one sector, including following cycles");
 resetstart;grant=1;abortload=1;
 repeat(61000)@(negedge clk);if(!req||ready)$fatal(1,"abort prematurely retired active SD request");
 sector(0);repeat(3)@(negedge clk);if(!ready||req||wreq)$fatal(1,"abort did not finish on sector end");
 $display("PASS abort preserves a slow active SD transfer until end");
 resetstart;grant=1;abortload=1;sector(1);
 repeat(60100)@(negedge clk);if(!ready||req||wreq)$fatal(1,"abort stuck after lost end");
 $display("PASS abort plus lost end recovers safely");
 resetstart;sector(0);wait(wreq);abortload=1;repeat(3)@(negedge clk);
 if(!ready||wreq)$fatal(1,"abort waiting for writer stuck");
 $display("PASS writer-ack wait can be cancelled");$finish;
end
initial begin #5000000;$fatal(1,"BMP handshake timeout");end
endmodule
