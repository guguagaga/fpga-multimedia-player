`timescale 1ns/1ps
module tb_expand;
 reg clk=0,rst=1,start=0,iv=0,blocked=0;
 always #5 clk=~clk;
 reg [23:0] ip=0;
 wire high,overflow,ov; wire [23:0] op;
 image_expand_5_4 dut(clk,rst,start,iv,ip,high,overflow,blocked,ov,op);
 wire rh,ro,rv;wire[23:0]rpixel;
 image_expand_reference ref0(clk,rst,start,iv,ip,rh,ro,blocked,rv,rpixel);
 always @(posedge clk)begin #2;if(!rst&&!start)begin
 if({high,overflow,ov}!=={rh,ro,rv})$fatal(1,"expand control differs cycle=%0d",cycles);
 if(ov&&op!==rpixel)$fatal(1,"expand cycle pixel differs cycle=%0d",cycles);
 end end
 integer sent=0,got=0,burst=0,cycles=0,stall=0,scenario=0,expected,max_count=0;
 reg [31:0] lfsr=32'h7531a249;
 always @(negedge clk) begin
  iv=0;
  if(!rst && !start) begin
   cycles=cycles+1;
   if(cycles%1000000==0)$display("progress cycle=%0d sent=%0d got=%0d state=%0d fifo=%0d qvalid=%b",cycles,sent,got,dut.state,dut.count,dut.qvalid);
   lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
   if(stall>0)begin blocked=1;stall=stall-1;end
   else begin
    blocked=(lfsr[3:0]==0);
    if(lfsr[15:0]==16'h3a7b)stall=5000;
   end
   if(!high && burst==0 && sent<307200)burst=171;
   // A whole in-flight sector keeps arriving after high, even in long stalls.
   if(burst>0 && sent<307200 && (scenario!=1 || cycles%96==0)) begin
    iv=1;ip=sent;sent=sent+1;burst=burst-1;
   end
  end
 end
 always @(posedge clk) begin
  #1;
  if(!rst && !start) begin
   if(dut.count>max_count)max_count=dut.count;
   if(overflow)$fatal(1,"INPUT OVERFLOW sent=%0d count=%0d",sent,dut.count);
   if(ov)begin
    expected=((got/800)*4/5)*640+(got%800)*4/5;
    if(op!==expected[23:0])$fatal(1,"PIXEL scenario=%0d n=%0d got=%h exp=%h",scenario,got,op,expected);
    got=got+1;
    if(got>480000)$fatal(1,"extra output");
   end
  end
 end
 task restart;
 begin
  @(negedge clk);rst=1;iv=0;
  repeat(3)@(negedge clk);
  sent=0;got=0;burst=0;cycles=0;stall=0;max_count=0;
  rst=0;
 end
 endtask
 initial begin
  restart;
  wait(got==480000);repeat(20)@(negedge clk);
  if(sent!=307200)$fatal(1,"wrong input count");
  $display("PASS dense sector bursts + random/5000-cycle stalls pixels=%0d peak_fifo=%0d",got,max_count);
  // Abort while replaying, as can happen on an interrupted prefetch.
  restart;wait(dut.state==3);@(negedge clk);start=1;
  @(negedge clk);sent=0;got=0;burst=0;cycles=0;start=0;
  wait(got==480000);repeat(20)@(negedge clk);
  $display("PASS interrupted image restart: exact full frame, no stale pixels");
  $display("PASS EXPAND EQUIVALENCE fullframes=2 abort=1");
  $finish;
 end
 initial begin #400000000; $fatal(1,"EXPAND TIMEOUT");end
endmodule
