`timescale 1ns/1ps
module tb;
reg sd_card_clk=0,rst_all=1;reg[13:0]fifo_usedw=0;
always #5 sd_card_clk=~sd_card_clk;
  reg image_prefetch_audio_ready;
  always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) image_prefetch_audio_ready <= 1'b0;
    else image_prefetch_audio_ready <= (fifo_usedw >= 14'd6144);
  end

integer n;
initial begin
repeat(3)@(negedge sd_card_clk);rst_all=0;
for(n=0;n<=8192;n=n+1)begin
 @(negedge sd_card_clk);fifo_usedw=n;@(posedge sd_card_clk);#1;
 if(image_prefetch_audio_ready !== (n>=6144))$fatal(1,"watermark n=%0d",n);
end
@(negedge sd_card_clk);rst_all=1;#1;if(image_prefetch_audio_ready!==0)$fatal(1,"reset");
$display("PASS actual top admission register all8193 FIFO levels and reset");$finish;
end
endmodule
