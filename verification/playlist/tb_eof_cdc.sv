`timescale 1ns/1ps
module tb;
reg clk=0,aclk=0;always #5.5 clk=~clk;always #40.69 aclk=~aclk;
reg rst=1,enable=0,started=0,last=0,present=0,toggle=0,paused=0;
wire empty,allow,ended;reg sample=0;reg[1:0]empty_sync=0;
integer phase=0,consumed=0;
av_sample_sync #(.LEAD_SAMPLES(1920)) av(.clk(aclk),.rst(rst),.enable_sd(enable),.started_sd(started),
 .paused_sd(paused),.draining_sd(1'b0),.frame_toggle_sd(toggle),.samples_per_frame_sd(13'd3200),
 .sample_valid(sample),.sample_allow(allow),.buffering(empty));
always@(posedge clk)if(rst)empty_sync<=0;else empty_sync<={empty_sync[0],empty};
video_eof_guard guard(.clk(clk),.rst(rst),.enable(enable),.paused(paused),.last_committed(last),
 .frame_presented(present),.budget_empty(empty_sync[1]),.ended(ended));
always@(negedge aclk)begin
 sample=0;
 if(!rst)begin phase=(phase+1)%256;if(phase==0&&enable&&started&&allow&&!paused)sample=1;end
end
always@(posedge aclk)if(!rst&&sample)consumed=consumed+1;
always@(negedge clk)if(ended&&consumed!=6400)$fatal(1,"early cross-domain EOF samples=%d",consumed);
task display_frame;begin @(negedge clk);present=1;toggle=~toggle;@(negedge clk);present=0;end endtask
initial begin
 repeat(10)@(negedge clk);rst=0;enable=1;repeat(100)@(negedge clk);
 started=1;display_frame();wait(consumed==3200);wait(empty_sync[1]);
 last=1;repeat(500)@(negedge clk);if(ended)$fatal(1,"committed is not displayed");
 display_frame();wait(consumed==4000);paused=1;repeat(1000)@(negedge clk);
 if(ended)$fatal(1,"EOF during pause");paused=0;
 wait(ended);if(consumed!=6400)$fatal(1,"wrong final count");
 $display("PASS actual 90.9MHz/12.288MHz EOF CDC, 6400 PCM samples, starved previous budget and final pause/resume");$finish;
end
initial begin #200000000;$fatal(1,"timeout");end
endmodule
