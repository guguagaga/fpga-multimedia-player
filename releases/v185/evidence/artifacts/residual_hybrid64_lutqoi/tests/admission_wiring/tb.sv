`timescale 1ns/1ps
module tb;
reg sd_card_clk=0,rst_all=0,video_engine_play=0,av_started=0;
reg[13:0]fifo_usedw=0;reg[4:0]wav_dbg_sd_state=0;
always #5.5 sd_card_clk=~sd_card_clk;
`include "policy.vh"
integer mode,state,level,checks=0;reg expected;
initial begin
 #1;rst_all=1;#1;if(defer_audio_prefetch!==0)$fatal(1,"async reset");
 @(negedge sd_card_clk);rst_all=0;
 for(mode=0;mode<4;mode=mode+1)begin
  for(state=0;state<32;state=state+1)begin
   for(level=0;level<6;level=level+1)begin
    @(negedge sd_card_clk);
    video_engine_play=mode[0];av_started=mode[1];wav_dbg_sd_state=state;
    case(level)0:fifo_usedw=0;1:fifo_usedw=4095;2:fifo_usedw=4096;
     3:fifo_usedw=4097;4:fifo_usedw=8192;5:fifo_usedw=16383;endcase
    expected=mode==3 && (state==19||state==20||state==23) && level>=2;
    @(posedge sd_card_clk);#1;
    if(defer_audio_prefetch!==expected)$fatal(1,"admission mismatch mode=%0d state=%0d reserve=%0d",mode,state,fifo_usedw);
    checks=checks+1;
   end
  end
 end
 @(negedge sd_card_clk);video_engine_play=1;av_started=1;wav_dbg_sd_state=19;fifo_usedw=8192;
 @(posedge sd_card_clk);#1;if(!defer_audio_prefetch)$fatal(1,"not deferred");
 #1;rst_all=1;#1;if(defer_audio_prefetch!==0)$fatal(1,"reset while deferred");
 $display("ADMISSION_WIRING_PASS checks=%0d",checks);$finish;
end
endmodule
