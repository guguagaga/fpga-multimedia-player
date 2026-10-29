`timescale 1ns/1ps
module tb;
reg clk=0;always #5.5 clk=~clk;
reg rst=1,enable=0,paused=0,last=0,present=0,empty=1;
wire ended;
video_eof_guard dut(.clk(clk),.rst(rst),.enable(enable),.paused(paused),
 .last_committed(last),.frame_presented(present),.budget_empty(empty),.ended(ended));
task tick;begin @(negedge clk);end endtask
task start;begin enable=0;last=0;present=0;paused=0;empty=1;repeat(4)tick();enable=1;end endtask
task display_last;begin present=1;tick();present=0;end endtask
integer k;
initial begin
 repeat(3)tick();rst=0;
 // Slow decoding: previous frame's credit is already empty at final commit.
 start();last=1;repeat(200)tick();if(ended)$fatal(1,"EOF before display");
 display_last();repeat(40)tick();if(ended)$fatal(1,"EOF before credit crosses domains");
 empty=0;repeat(80)tick();if(ended)$fatal(1,"EOF before final PCM");
 empty=1;repeat(3)tick();if(!ended)$fatal(1,"missing EOF");
 // A paused final frame must neither switch early nor lose the eventual EOF.
 start();last=1;paused=1;display_last();empty=0;repeat(100)tick();
 if(ended)$fatal(1,"EOF during pause");paused=0;repeat(10)tick();
 paused=1;empty=1;repeat(20)tick();if(ended)$fatal(1,"EOF during final pause");
 paused=0;repeat(3)tick();if(!ended)$fatal(1,"EOF after resume missing");
 // Stop/exit cancels any pending final-frame state; no stale EOF on re-entry.
 for(k=0;k<40;k=k+1)begin
  start();last=1;display_last();repeat(k+1)tick();enable=0;repeat(3)tick();
  if(ended)$fatal(1,"stale EOF after stop");enable=1;last=0;repeat(90)tick();
  if(ended)$fatal(1,"stale EOF after re-entry");
 end
 $display("PASS final-frame guard: slow decode, delayed display/CDC, pause/resume, 40 interrupted final frames");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
