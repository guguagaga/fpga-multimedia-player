`timescale 1ns/1ps
module tb;
reg clk=0,we=0,re=0;always #5 clk=~clk;
reg[14:0]wa=0,ra=0;reg[7:0]data=0;wire[7:0]reference,hybrid;
video_byte_ram #(.AW(15),.DEPTH_BYTES(32768),.HYBRID_TAIL_9K(0)) refdut(clk,we,re,wa,ra,data,reference);
video_byte_ram #(.AW(15),.DEPTH_BYTES(32768),.HYBRID_TAIL_9K(1)) dut(clk,we,re,wa,ra,data,hybrid);
reg[7:0]mem[0:32767];reg[7:0]expected=0;integer i,checks=0;
task step;begin
 if(we)mem[wa]=data;
 if(re)expected=mem[ra];
 @(posedge clk);#1;
 if(hybrid!==reference||hybrid!==expected)$fatal(1,"RAM mismatch i=%0d wa=%0d ra=%0d we=%0d re=%0d hybrid=%h vendor=%h expected=%h",i,wa,ra,we,re,hybrid,reference,expected);
 checks=checks+1;@(negedge clk);
end endtask
initial begin
 // All bytes are written before use, as required by valid-sector guarding.
 for(i=0;i<32768;i=i+1)begin @(negedge clk);we=1;wa=i;data=i^(i>>8);mem[i]=data;end
 @(negedge clk);we=0;re=1;
 for(i=0;i<32768;i=i+1)begin ra=i;step;end
 for(i=0;i<100000;i=i+1)begin
  we=$random;re=$random;data=$random;wa=$urandom_range(0,32767);ra=$urandom_range(0,32767);
  case(i%5)0:ra=wa;1:ra=wa^1;2:begin wa=28672+(i%4096);ra=wa;end 3:begin wa=28671;ra=28672;end endcase
  step;
 end
 $display("HYBRID_RAM_PASS operations=%0d",checks);$finish;
end
endmodule
