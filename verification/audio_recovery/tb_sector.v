`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,restart=0,cancel=0,enable=1,iv=0,ended=0,grant=0,ready=0;reg[7:0]data=0;
wire req,error,ov,busy;wire[31:0]addr;wire[7:0]out;
sector_byte_source #(.TIMEOUT_CYCLES(64)) dut(clk,rst,restart,cancel,enable,32'd1234,req,addr,data,iv,ended,grant,out,ov,ready,busy,error);
integer n,got=0;
always@(posedge clk)if(ov&&ready)begin
 if(out!==(got&255))$fatal(1,"byte mismatch %0d %h",got,out);got=got+1;
end
task boot;begin
 rst=1;restart=0;cancel=0;grant=0;iv=0;ended=0;ready=0;got=0;
 repeat(3)@(negedge clk);rst=0;restart=1;@(negedge clk);restart=0;wait(req);
end endtask
task send(input integer count,input integer final_with_data);begin
 @(negedge clk);grant=1;
 for(n=0;n<count;n=n+1)begin
  @(negedge clk);data=n;iv=1;
  if(final_with_data&&n==count-1)ended=1;
  @(negedge clk);iv=0;ended=0;
 end
 if(!final_with_data)begin ended=1;@(negedge clk);ended=0;end
 grant=0;
end endtask
initial begin
 boot;repeat(200)@(negedge clk);
 if(error||addr!=1234||!req)$fatal(1,"waiting for grant falsely rejected");
 send(100,0);repeat(2)@(negedge clk);
 if(ov||error||addr!=1234)$fatal(1,"short sector leaked or LBA advanced");
 wait(req);send(511,0);wait(req);
 if(ov||error||addr!=1234)$fatal(1,"second short retry changed position");
 send(512,1);ready=1;wait(got==512);@(negedge clk);ready=0;
 if(error||addr!=1235)$fatal(1,"retry did not recover at same LBA");
 $display("PASS ungranted wait, two short sectors, exact data recovery, simultaneous last-byte/end");
 boot;send(0,0);wait(req);send(40,0);wait(req);send(511,0);repeat(20)@(negedge clk);
 if(!error||ov||req||addr!=1234)$fatal(1,"retry exhaustion leaked/reissued");
 $display("PASS bounded retry exhaustion; no partial data published");
 boot;grant=1;repeat(70)@(negedge clk);
 if(!error||!req)$fatal(1,"timeout must preserve in-flight ownership");
 send(512,0);repeat(20)@(negedge clk);
 if(ov||req)$fatal(1,"timed-out transaction published/reissued");
 $display("PASS owned timeout and late completion");
 boot;grant=1;cancel=1;send(100,0);repeat(20)@(negedge clk);
 if(req||ov||error)$fatal(1,"cancel reissued or leaked");
 $display("PASS cancelled short sector remains cancelled");
 boot;send(512,0);ready=1;wait(got==512);$display("PASS restart clears prior failure");
 $display("PASS SECTOR RECOVERY");$finish;
end
initial begin #200000;$fatal(1,"timeout");end
endmodule
