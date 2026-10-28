`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=0,de=0,vs=1,en=0;reg[23:0]rgb=0;reg[7:0]a=0,b=0,c=0,d=0;reg beat=0;
wire[6:0]a0,b0,c0,d0,a1,b1,c1,d1;wire de0,vs0,de1,vs1;wire[23:0]p0,p1;
spectrum_reference #(.GLOW_EN(0),.BAND_EN(0)) ref0(clk,rst,de,vs,rgb,en,a,a0,b,b0,c,c0,d,d0,beat,de0,vs0,p0);
spectrum_display #(.GLOW_EN(0),.BAND_EN(0)) dut(clk,rst,de,vs,rgb,en,a,a1,b,b1,c,c1,d,d1,beat,de1,vs1,p1);
integer checks=0,i,k,j,x,y,frame,seed=4539;reg[23:0]gc;reg[59:0]terms;reg[7:0]v0,v1,foreground;
always @(posedge clk)begin #1;if(rst)begin
 if({de0,vs0,p0,a0,b0,c0,d0}!=={de1,vs1,p1,a1,b1,c1,d1})$fatal(1,"spectrum differs check=%0d",checks);
 checks=checks+1;
end end
initial begin
 // Exhaust all original index values, backgrounds, channels and fill/edge modes.
 for(i=0;i<128;i=i+1)begin
 gc=ref0.grad_lut((i+(i>>1))&63);terms=dut.grad_terms(i);
 for(k=0;k<6;k=k+1)begin
 case(k%3)0:foreground=gc[23:16];1:foreground=gc[15:8];2:foreground=gc[7:0];endcase
 if(k>=3)foreground=(foreground>>1)+128;
 for(j=0;j<256;j=j+1)begin
 v0=ref0.alpha_blend(foreground,j,12);v1=((terms >> ((5-k)*10))&1023)+j >>2;
 if(v0!==v1)$fatal(1,"palette arithmetic i=%0d k=%0d j=%0d",i,k,j);
 end end end
 repeat(5)@(negedge clk);rst=1;
 // Long lines cover 10-bit X wrap; irregular blanking/reset preserve addresses.
 for(i=0;i<6000;i=i+1)begin
 @(negedge clk);de=1;rgb=$random(seed);en=1;a=$random(seed);b=$random(seed);c=$random(seed);d=$random(seed);
 end
 @(negedge clk);de=0;repeat(6)@(negedge clk);
 for(frame=0;frame<2;frame=frame+1)begin
 vs=1;repeat(8)@(negedge clk);vs=0;
 for(y=0;y<720;y=y+1)begin
 for(x=0;x<1280;x=x+1)begin
 @(negedge clk);de=1;rgb=$random(seed);a=$random(seed);b=$random(seed);c=$random(seed);d=$random(seed);
 en=(frame==0)||(x%97>8);beat=(x==42&&y%51==0);
 end
 @(negedge clk);de=0;repeat(16)@(negedge clk);
 end
 end
 repeat(6)@(negedge clk);rst=0;repeat(3)@(negedge clk);rst=1;repeat(10)@(negedge clk);
 $display("PASS SPECTRUM EQUIVALENCE checks=%0d exhaustive_palette=196608",checks);$finish;
end
endmodule
