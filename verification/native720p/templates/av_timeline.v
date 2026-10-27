`timescale 1ns/1ps
module tb_av_sample_sync;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,enable=0,started=0,paused=0,draining=0,frame=0,valid=0;
 reg [12:0] period=3200;
 wire allow,time_toggle,buffering;
 av_sample_sync #(.LEAD_SAMPLES(1920)) dut(.clk(clk),.rst(rst),.enable_sd(enable),.started_sd(started),
  .paused_sd(paused),.draining_sd(draining),.frame_toggle_sd(frame),
  .samples_per_frame_sd(period),.sample_valid(valid),.sample_allow(allow),
  .time_toggle(time_toggle),.buffering(buffering));
 integer cycles=0,consumed=0,grants=0,ticks=0,pending=0,due=0;
 integer target=12660,p=3200,buffer_cycles=0,pause_cycles=0,pauses=0;
 integer seed=32'h1a215e,delay_cycles=0,expected_ticks=0;
 reg previous_time=0;
 always @(posedge clk)if(!rst && valid)begin
  if(!allow)$fatal(1,"unpermitted PCM consumption");
  consumed=consumed+1;
  if(consumed>grants*p)$fatal(1,"audio led displayed frame budget");
 end
 always @(negedge clk)if(!rst)begin
  cycles=cycles+1;valid=0;
  if(started)begin
   if(time_toggle!=previous_time)begin
    ticks=ticks+1;previous_time=time_toggle;
    expected_ticks=(consumed+((p>1920)?1920:p-240))/p;
    if(ticks!=expected_ticks)$fatal(1,"sample timeline drift %d != %d",ticks,expected_ticks);
    if(pending)$fatal(1,"more than one unpresented credit");
    seed=(seed<<1)^((seed<0)?32'h04c11db7:0);
    delay_cycles=16+(seed&8191);
    // Sporadic long card stalls must cause bounded buffering, not drift.
    if(ticks%97==0)delay_cycles=delay_cycles+40000;
    due=cycles+delay_cycles;pending=1;
   end
   if(pending&&cycles>=due&&!paused)begin
    frame=~frame;grants=grants+1;pending=0;
   end
   if(cycles%200003==0)begin paused=1;pauses=pauses+1;end
   if(paused)begin
    pause_cycles=pause_cycles+1;
    if(cycles%200003==4003)paused=0;
   end
   if(buffering)buffer_cycles=buffer_cycles+1;
   if(allow&&cycles%4==0)valid=1;
   if(grants>=target)begin
    if(buffer_cycles==0||pauses==0)$fatal(1,"stall/pause coverage missing");
    $display("PASS AV timeline: period=%0d displayed_frames=%0d consumed_samples=%0d ticks=%0d buffering_cycles=%0d pauses=%0d",p,grants,consumed,ticks,buffer_cycles,pauses);
    $finish;
   end
   if(cycles>target*p*20)$fatal(1,"timeline deadlock");
  end
 end
 initial begin
  if($value$plusargs("PERIOD=%d",p))begin end
  if($value$plusargs("FRAMES=%d",target))begin end
  period=p;
  repeat(8)@(negedge clk);rst=0;enable=1;
  repeat(20)@(negedge clk);
  if(allow)$fatal(1,"PCM consumed before first video presentation");
  @(posedge clk);#1;frame=1;grants=1;started=1;
 end
endmodule
