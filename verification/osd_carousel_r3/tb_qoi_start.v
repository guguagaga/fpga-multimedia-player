`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,load=0,abortload=0,grant=0,valid=0,ended=0,ack=0;always #5 clk=~clk;
wire req,wreq,ready;wire[31:0]addr;reg[7:0]data=0;
bmp_read #(.SCALING_EN(1)) dut(.clk(clk),.rst(rst),.load_abort(abortload),.sd_grant(grant),
 .bmp_width(16'd640),.bmp_height(16'd480),.scan_start(1'b0),.scan_start2(1'b0),.scan_abort(1'b0),
 .scan_start_sector(32'd0),.scan_start_sector2(32'd0),.scan_max_sector(32'd0),.scan_limited(1'b1),.scan_target_count(3'd4),
 .load_start(load),.load_sector(32'd1434224),.ready(ready),.write_req(wreq),.write_req_ack(ack),.write_almost_full(1'b0),
 .sd_init_done(1'b1),.sd_error(1'b0),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended));
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
 // Switch fixture to QOI320x240, including the registered-start abort window.
 for(i=0;i<512;i=i+1)h[i]=0;
 h[0]="q";h[1]="o";h[2]="i";h[3]="f";h[6]=1;h[7]=64;h[11]=240;h[12]=3;
 resetstart;sector(0);wait(wreq);
 @(negedge clk);ack=1;
 @(negedge clk);ack=0;
 if(dut.q_start_q!==1)$fatal(1,"registered QOI start missing");
 abortload=1;
 repeat(3)@(negedge clk);
 if(dut.q_start_q!==0 || dut.u_qoi.pixel_valid!==0)$fatal(1,"abort leaked QOI start/pixel");
 $display("PASS QOI abort cancels pending registered start");
 resetstart;sector(0);wait(wreq);
 @(negedge clk);ack=1;@(negedge clk);ack=0;
 repeat(2)@(negedge clk);
 if(dut.u_qoi.state!==dut.u_qoi.CLEAR)$fatal(1,"QOI did not enter clear");
 repeat(70)@(negedge clk);
 if(dut.u_qoi.state!==dut.u_qoi.HEADER)$fatal(1,"QOI did not wait for header bytes");
 if(dut.u_qoi.pixel_valid!==0)$fatal(1,"premature QOI pixels");
 $display("PASS QOI restart enters clear then header with no premature pixels");$finish;
end
initial begin #5000000;$fatal(1,"BMP handshake timeout");end
endmodule
