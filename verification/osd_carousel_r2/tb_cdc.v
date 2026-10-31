`timescale 1ns/1ps
module tb;
reg src=0,dst=0,rst=0; reg [4:0] value=0;wire[4:0] result;
always #5.5 src=~src;
reg run_dst=1;
always begin #6.73;if(run_dst)dst=~dst;end
carousel_status_cdc dut(src,dst,rst,value,result);
integer k;reg [4:0] old_bundle;reg was_busy;
always @(negedge src)begin
 if(!rst && was_busy && dut.bundle!==old_bundle)$fatal(1,"source bundle changed while busy");
 old_bundle=dut.bundle;
 was_busy=!rst && (dut.request_toggle!=dut.ack_sync[1]);
end
task settle;begin repeat(35)@(posedge src);#1;if(result!==value)$fatal(1,"CDC final actual=%h expected=%h",result,value);end endtask
initial begin
 #1 rst=1;#22 rst=0;settle;
 for(k=0;k<32;k=k+1)begin @(negedge src);value=k;settle;end
 repeat(1000)begin @(negedge src);value=$random;end
 settle;
 run_dst=0;repeat(30)begin @(negedge src);value=$random;end
 run_dst=1;settle;
 #3 rst=1;#17 rst=0;value=31;settle;
 $display("PASS mailbox 32 states, 1000 rapid changes, paused destination and reset");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
