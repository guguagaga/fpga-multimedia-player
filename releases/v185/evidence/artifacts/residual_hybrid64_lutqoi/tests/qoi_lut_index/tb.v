`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,start=0,dv=0,pr=0;always #5 clk=~clk;
reg[7:0]din=0;wire[1:0]ready,pv,done,error;wire[23:0]pixel0,pixel1;wire[31:0]w0,w1,h0,h1;
qoi_stream #(.BRAM32_INDEX(1)) refdut(.clk(clk),.rst(rst),.start(start),.din(din),.din_valid(dv),.din_ready(ready[0]),.pixel(pixel0),.pixel_valid(pv[0]),.pixel_ready(pr),.done(done[0]),.error(error[0]),.width(w0),.height(h0),.expected_pixels(25'd16384));
qoi_stream #(.BRAM32_INDEX(2)) dut(.clk(clk),.rst(rst),.start(start),.din(din),.din_valid(dv),.din_ready(ready[1]),.pixel(pixel1),.pixel_valid(pv[1]),.pixel_ready(pr),.done(done[1]),.error(error[1]),.width(w1),.height(h1),.expected_pixels(25'd16384));
reg[7:0]encoded[0:6551];reg[23:0]expected[0:16383];integer at=0,seen=0,cycles=0,round=0;reg running=0;
always@(posedge clk)if(running)begin
 cycles=cycles+1;
 if(ready[0]!==ready[1]||pv[0]!==pv[1]||done[0]!==done[1]||error[0]!==error[1])$fatal(1,"control mismatch cycle%0d",cycles);
 if(|error)$fatal(1,"decoder error");
 if(dv&&ready[0])at=at+1;
 if(pv[0]&&pr)begin
  if(seen>=16384||pixel0!==expected[seen]||pixel1!==expected[seen])$fatal(1,"pixel mismatch round%0d n%0d ref%h got%h expected%h",round,seen,pixel0,pixel1,expected[seen]);
  seen=seen+1;
 end
end
always@(negedge clk)begin
 #1;dv=running&&at<=6551&&(cycles%7!=0);din=at<=6551?encoded[at]:0;pr=running&&(cycles%13!=0)&&((cycles%61)>8);
end
initial begin
 $readmemh("input.hex",encoded);$readmemh("pixels.hex",expected);
 repeat(8)@(negedge clk);#2;rst=0;
 for(round=0;round<3;round=round+1)begin
  @(negedge clk);#2;start=1;at=0;seen=0;running=0;
  @(negedge clk);#2;start=0;running=1;
  wait(&done);@(negedge clk);#2;running=0;
  if(seen!=16384||at!=6551+1||w0!=128||h0!=128||w1!=128||h1!=128)$fatal(1,"bad end count");
  repeat(5)@(negedge clk);
 end
 $display("QOI_LUT_PASS pixels=49152 rounds=3 cycles=%0d",cycles);$finish;
end
initial begin #20000000;$fatal(1,"timeout");end
endmodule
