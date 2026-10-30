`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,started=0,toggle=0;always #1 clk=~clk;
wire allow,buffering,time_toggle,req,valid,rd,lrck,bclk,dout;wire[23:0]left,right;reg[7:0]q=0;
integer cycle=0,bytes=0,k=0,delay_cycles=0,expected=1,good=0,gaps=0,last_output=0,min_interval=999999,max_interval=0;
integer grant_period=409600,duplicates=0;
reg old_lrck=0,seen=0;
av_sample_sync #(.LEAD_SAMPLES(1920)) av(.clk(clk),.rst(rst),.enable_sd(1'b1),.started_sd(started),.paused_sd(1'b0),.draining_sd(1'b0),.frame_toggle_sd(toggle),.samples_per_frame_sd(13'd1600),.sample_valid(valid),.sample_allow(allow),.time_toggle(time_toggle),.buffering(buffering));
wav_sample_builder builder(.clk(clk),.rst(rst),.sample_req(req&&allow),.stereo(1'b0),.fifo_rd_en(rd),.fifo_rd_data(q),.fifo_empty(1'b0),.sample_valid(valid),.sample_left(left),.sample_right(right));
i2s_transmitter #(.MAX_BUDGET_HOLD(2)) tx(.hold_budget_gap(buffering),.clk(clk),.rst(rst),.mute(1'b0),.flush(1'b0),.sample_valid(valid),.sample_left(left),.sample_right(right),.sample_req(req),.i2s_bclk(bclk),.i2s_lrck(lrck),.i2s_dout(dout));
always@(posedge clk)if(!rst&&rd)begin
 q<=((bytes/2+1)>>(8*(bytes%2)))&255;bytes=bytes+1;
end
always@(negedge clk)if(!rst)begin
 cycle=cycle+1;
 if(k<30 && cycle==1000+k*grant_period+(k>=3?delay_cycles:0))begin started=1;toggle=~toggle;k=k+1;end
 if(old_lrck&&!lrck)begin
  if(tx.sample_left_reg!=0 || seen)begin
   if(last_output!=0)begin
    if(cycle-last_output<min_interval)min_interval=cycle-last_output;
    if(cycle-last_output>max_interval)max_interval=cycle-last_output;
   end
   last_output=cycle;seen=1;
   if(tx.sample_left_reg==0)gaps=gaps+1;
   else if(expected>1&&tx.sample_left_reg===(((expected-1)&65535)<<8))begin
    if(tx.sample_right_reg!==tx.sample_left_reg||tx.budget_hold_count==0||tx.budget_hold_count>2)$fatal(1,"unbounded or torn repeated pair");
    duplicates=duplicates+1;
   end else begin
    if(tx.sample_left_reg!==((expected&65535)<<8) || tx.sample_right_reg!==tx.sample_left_reg)$fatal(1,"PCM sequence mismatch sample=%0d left=%h right=%h",expected,tx.sample_left_reg,tx.sample_right_reg);
    expected=expected+1;good=good+1;
    if(good==48000)begin
     if(min_interval!=256||max_interval!=256)$fatal(1,"I2S clock period changed");
     if(delay_cycles==0&&gaps!=0)$fatal(1,"Nominal30fps generated I2S gaps=%0d",gaps);
     if(delay_cycles>0&&gaps<700)$fatal(1,"Delayed-frame negative control did not reproduce silence");
     $display("BOUNDED_HOLDS repeats=%0d",duplicates);
     $display("PASS I2S cadence delay=%0d good=%0d silence_frames=%0d period=%0d",delay_cycles,good,gaps,min_interval);$finish;
    end
   end
  end
 end
 old_lrck=lrck;
 if(cycle>14000000)$fatal(1,"timeout good=%0d gaps=%0d grants=%0d",good,gaps,k);
end
initial begin if($value$plusargs("GRANT_PERIOD=%d",grant_period))begin end if($value$plusargs("DELAY=%d",delay_cycles))begin end repeat(8)@(negedge clk);rst=0;end
endmodule
