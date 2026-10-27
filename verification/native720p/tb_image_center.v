`timescale 1ns/1ps
module tb_image_center;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,disable_image=0,req=0,valid=0,blocked=0;
 reg[31:0]data=0;wire high,ov;wire[31:0]od;
 integer cycles=0,out_count=0,src_count=0,frames=0,n,x,y,si;
 reg[31:0]expected;
 image_center_720p dut(.clk(clk),.rst(rst),.disable_image(disable_image),.write_req(req),
  .source_valid(valid),.source_data(data),.source_high(high),.sink_high(blocked),.out_valid(ov),.out_data(od));
 function[31:0]sample;input integer p;reg[23:0]v;begin v=(p*17)^(p>>8);sample={v,8'd0};end endfunction
 always @(negedge clk)begin
  cycles=cycles+1;
  blocked=(cycles%113<17 || cycles%8191<128);
 end
 always @(posedge clk)if(!rst&&ov)begin
  x=out_count%1280;y=out_count/1280;
  if(x>=240&&x<1040&&y>=60&&y<660)begin
   si=(y-60)*800+x-240;expected=sample(si);
  end else expected=0;
  if(od!==expected)$fatal(1,"image pad pixel=%d got=%h exp=%h",out_count,od,expected);
  out_count=out_count+1;
 end
 initial begin
  repeat(5)@(negedge clk);rst=0;
  // Abort a partial load, then restart from a clean frame.
  req=1;repeat(5)@(negedge clk);req=0;
  repeat(20)begin valid=1;data=sample(0);@(negedge clk);end
  valid=0;disable_image=1;repeat(3)@(negedge clk);disable_image=0;
  for(frames=0;frames<3;frames=frames+1)begin
   out_count=0;req=1;repeat(7)@(negedge clk);req=0;
   for(n=0;n<480000;n=n+1)begin
    while(high)begin valid=0;@(negedge clk);end
    valid=1;data=sample(n);@(negedge clk);
    if(n%127==0)begin valid=0;repeat(3)@(negedge clk);end
   end
   valid=0;
   wait(out_count==921600);repeat(5)@(negedge clk);
   if(dut.used!=0)$fatal(1,"image source not drained");
   $display("PASS image pad frame=%d pixels=%d",frames,out_count);
  end
  $display("PASS720 image centering, black margins, random stalls, three loads and abort/restart");$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
