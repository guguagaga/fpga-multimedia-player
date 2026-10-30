`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg[10:0]addr=0;reg[7:0]cjk=0;wire[7:0]old_logo,new_logo;wire[15:0]old_cjk,new_cjk;
old_rom old(.clk(clk),.cjk_addr(cjk),.cjk_dout(old_cjk),.logo_addr(addr),.logo_dout(old_logo));
osd_brand_rom dut(.clk(clk),.cjk_addr(cjk),.cjk_dout(new_cjk),.logo_addr(addr),.logo_dout(new_logo));
integer i;
initial begin
 for(i=0;i<2048;i=i+1)begin
  @(negedge clk);addr=i;cjk=i%144;@(posedge clk);#1;
  if(old_logo!==new_logo||old_cjk!==new_cjk||(^new_logo)===1'bx)$fatal(1,"ROM mismatch address%0d",i);
 end
 $display("LOGO_EQUIVALENCE_PASS addresses=2048");$finish;
end
endmodule
