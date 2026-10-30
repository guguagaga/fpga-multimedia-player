`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,mute=0,flush=0,hold_gap=0,valid=0;always #5 clk=~clk;
reg[23:0]left=0,right=0;integer checks=0;
i2s_transmitter #(.MAX_BUDGET_HOLD(2)) dut(.clk(clk),.rst(rst),.mute(mute),.flush(flush),
 .hold_budget_gap(hold_gap),.sample_valid(valid),.sample_left(left),.sample_right(right));
task frame;
 input[23:0]l,r;
 begin
 // Check the pair only at the real left-channel publication boundary.
 @(negedge clk);while(!(dut.i2s_bclk&&dut.bit_cnt==63&&dut.i2s_lrck))@(negedge clk);
 @(posedge clk);#1;
 if(dut.sample_left_reg!==l||dut.sample_right_reg!==r)$fatal(1,"unexpected pair got=%h/%h exp=%h/%h",dut.sample_left_reg,dut.sample_right_reg,l,r);
 checks=checks+1;
 end
endtask
task supply;
 input[23:0]l,r;begin @(negedge clk);left=l;right=r;valid=1;@(negedge clk);valid=0;end
endtask
initial begin
 repeat(5)@(negedge clk);rst=0;hold_gap=1;
 frame(0,0); // No last sample exists at startup.
 supply(24'h123400,24'habcd00);frame(24'h123400,24'habcd00);
 frame(24'h123400,24'habcd00);frame(24'h123400,24'habcd00);
 frame(0,0);frame(0,0); // Strict two-sample bound, no indefinite stale DC.
 hold_gap=0;supply(24'h567800,24'h876500);frame(24'h567800,24'h876500);frame(0,0);
 hold_gap=1;supply(24'h010200,24'h030400);frame(24'h010200,24'h030400);
 mute=1;frame(0,0);mute=0;frame(0,0); // Mute clears repeat history.
 supply(24'h050600,24'h070800);frame(24'h050600,24'h070800);
 @(negedge clk);flush=1;@(negedge clk);flush=0;frame(0,0);
 supply(24'h112200,24'h334400);frame(24'h112200,24'h334400);frame(24'h112200,24'h334400);
 supply(24'h556600,24'h778800);frame(24'h556600,24'h778800);frame(24'h556600,24'h778800);
 $display("HOLD_CONTROLS_PASS checks=%0d",checks);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
