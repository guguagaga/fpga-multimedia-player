`timescale 1ns/1ps
module tb;
 reg clk=0;always #5 clk=~clk;
 reg we=0,re=0;reg[12:0]wa=0,ra=0;reg[7:0]data=0;
 wire[7:0]q;reg[7:0]reference[0:8191];
 video_byte_ram #(.AW(13)) dut(.clk(clk),.we(we),.re(re),.wa(wa),.ra(ra),.data(data),.q(q));
 integer i,k,checks=0;reg[31:0]rng=32'h7246ac19;
 task step;
 begin
  @(posedge clk);
  if(we)reference[wa]=data;
  #1;
  if(re)begin if(q!==reference[ra])$fatal(1,"byte RAM address=%d got=%h expected=%h",ra,q,reference[ra]);checks=checks+1;end
  @(negedge clk);
 end endtask
 initial begin
  repeat(10)@(negedge clk);
  // Initialize each adjacent lane independently across all 4KiB boundaries.
  for(i=0;i<8192;i=i+1)begin we=1;wa=i;data=(i*73)^(i>>3);step;end
  we=0;
  for(i=0;i<8192;i=i+1)begin re=1;ra=i;step;end
  for(i=0;i<100000;i=i+1)begin
   rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   we=rng[0];re=rng[1];wa=rng[14:2];ra=rng[27:15];data=rng[31:24];
   // Same-byte simultaneous read/write is intentionally unspecified; a
   // valid FIFO never reads an address being inserted in the same cycle.
   if(ra==wa)ra=ra^13'd1;
   step;
  end
  $display("PASS byte RAM vendor model checks=%d lane preservation, bank switches, randomized concurrent access",checks);$finish;
 end
endmodule
