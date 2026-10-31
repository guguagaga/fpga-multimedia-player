`timescale 1ns/1ps
module tb;
reg sclk=0,vclk=0,rst=0;always #5.5 sclk=~sclk;always #6.73 vclk=~vclk;
reg[3:0]sel=0;reg boundary=0,on=0;wire[3:0]code;wire[9:0]seconds;wire[4:0]status;
carousel_period_cfg cfg(.clk(sclk),.rst(rst),.preset_sel(sel),.boundary(boundary),.preset_code(code),.period_sec(seconds),.preset_sec());
carousel_status_cdc cdc(sclk,vclk,rst,{on,code},status);
integer k,old_code;
integer sec[0:15];
task wait_status;begin repeat(30)@(posedge sclk);#1;if(status!=={on,code})$fatal(1,"effective config CDC mismatch");end endtask
initial begin
sec[0]=2;sec[1]=3;sec[2]=5;sec[3]=8;sec[4]=10;sec[5]=15;sec[6]=20;sec[7]=30;sec[8]=45;sec[9]=60;sec[10]=90;sec[11]=120;sec[12]=180;sec[13]=240;sec[14]=300;sec[15]=600;
#1 rst=1;#25 rst=0;on=1;wait_status;
for(k=0;k<16;k=k+1)begin
 old_code=code;@(negedge sclk);sel=k;boundary=0;wait_status;
 if(code!==old_code || status[3:0]!==old_code)$fatal(1,"pending DIP applied before safe boundary");
 @(negedge sclk);boundary=1;@(negedge sclk);boundary=0;wait_status;
 if(code!==k || seconds!==sec[k])$fatal(1,"effective seconds mismatch");
end
on=0;wait_status;on=1;wait_status;
$display("PASS effective period safe boundary all16, pending DIP never shown, on/off mailbox");$finish;
end
endmodule
