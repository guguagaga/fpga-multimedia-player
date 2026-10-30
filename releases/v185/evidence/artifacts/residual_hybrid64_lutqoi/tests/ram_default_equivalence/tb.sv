`timescale 1ns/1ps
module check #(parameter AW=13)(output reg finished=0);
reg clk=0;always #5 clk=~clk;
reg we=0,re=0;reg[AW-1:0]wa=0,ra=0;reg[7:0]data=0;wire[7:0]a,b;
video_byte_ram #(.AW(AW)) dut(clk,we,re,wa,ra,data,a);
reference_ram #(.AW(AW)) refdut(clk,we,re,wa,ra,data,b);
integer i;reg[7:0] expected[0:(1<<AW)-1];
initial begin
 for(i=0;i<(1<<AW);i=i+1)begin
  @(negedge clk);we=1;wa=i;data=(i^(i>>8));expected[i]=data;
 end
 @(negedge clk);we=0;re=1;
 for(i=0;i<(1<<AW);i=i+1)begin
  ra=i;@(posedge clk);#1;
  if(a!==b||a!==expected[i])$fatal(1,"RAM address/lane mismatch AW=%0d addr=%0d",AW,i);
  @(negedge clk);
 end
 for(i=0;i<2000;i=i+1)begin
  we=$random;re=$random;wa=$random;ra=$random;data=$random;
  @(posedge clk);#1;if(a!==b)$fatal(1,"RAM concurrent/hold mismatch AW=%0d",AW);
  @(negedge clk);
 end
 we=0;re=0;finished=1;
end
endmodule
module tb;
wire[4:0]done;
check #(10)a(done[0]);check #(12)b(done[1]);check #(13)c(done[2]);check #(14)d(done[3]);check #(15)e(done[4]);
initial begin wait(&done);$display("RAM_DEFAULT_EQUIVALENCE_PASS");$finish;end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
