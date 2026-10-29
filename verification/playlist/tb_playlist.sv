`timescale 1ns/1ps
module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg clear=0,ev=0,ea=0;reg[15:0]prefix;reg[31:0]sector;
reg mode=0,ready_list=0,next=0,prev=0,toggle=0,ended=0,idle=1,ready=1,busy=0;
wire[3:0]available;wire[1:0]index;wire[31:0]video,audio;
wire duplicate,play,select,switching,auto_en,failed;
video_catalog catalog(.clk(clk),.rst(rst),.clear(clear),.entry_valid(ev),.entry_audio(ea),
 .entry_prefix(prefix),.entry_sector(sector),.index(index),.legacy_video(32'd100),.legacy_audio(32'd200),
 .available(available),.selected_video(video),.selected_audio(audio),.duplicate_seen(duplicate));
video_playlist_ctrl #(.SELECT_TIMEOUT(100)) ctrl(.clk(clk),.rst(rst),.mode_video(mode),.list_ready(ready_list),
 .next_req(next),.prev_req(prev),.auto_toggle(toggle),.ended(ended),.io_idle(idle),
 .audio_ready(ready),.audio_busy(busy),.available(available),.index(index),.engine_play(play),
 .audio_select(select),.switching(switching),.auto_enabled(auto_en),.selection_failed(failed));
integer selections=0;
always@(posedge clk)if(select)begin
 selections=selections+1;
 if(play||!idle)$fatal(1,"unsafe selection");
 if(audio!=video+1000)$fatal(1,"paired addresses wrong %0d %0d",video,audio);
end
task tick;begin @(negedge clk);end endtask
task add(input bit a,input[15:0]p,input[31:0]s);
 begin tick();ev=1;ea=a;prefix=p;sector=s;tick();ev=0;end
endtask
task audio_handshake;
 begin
  wait(select);tick();busy=1;repeat(3)tick();ready=0;repeat(5)tick();ready=1;
  repeat(3)tick();if(play)$fatal(1,"started while audio transition busy");
  busy=0;wait(play);tick();
 end
endtask
task move(input bit back,input integer expected_index);
 reg[1:0]old;
 begin
  old=index;tick();idle=0;prev=back;next=!back;tick();prev=0;next=0;
  repeat(9)tick();if(index!=old || play)$fatal(1,"identity changed before SD drain");
  idle=1;audio_handshake();
  if(index!=expected_index)$fatal(1,"wrong index got%0d expected%0d",index,expected_index);
 end
endtask
integer k;
initial begin
 repeat(3)tick();rst=0;repeat(3)tick();
 if(available!=1)$fatal(1,"single legacy fallback");
 // Deliberately interleave/reverse audio and video directory order.
 add(1,"V4",1400);add(0,"M1",100);add(0,"M4",400);add(1,"V1",1100);
 add(0,"M2",200); // missing VAU: skipped
 add(0,"M5",500);add(1,"V5",1500); // out of range: ignored
 add(0,"M1",999); // duplicate: first entry must win
 repeat(4)tick();if(available!=4'b1001||!duplicate)$fatal(1,"catalog identity masks");
 ready_list=1;mode=1;audio_handshake();if(index!=0||video!=100)$fatal(1,"first selection");
 move(0,3);move(0,0);move(1,3);move(1,0);
 for(k=0;k<24;k=k+1)move(k%2,k%2?0:3);
 // Natural EOF is consumed once; source must clear EOF when stopped.
 tick();ended=1;tick();ended=0;audio_handshake();if(index!=3)$fatal(1,"automatic next");
 tick();toggle=1;tick();toggle=0;ended=1;repeat(6)tick();ended=0;
 if(!play||index!=3||auto_en)$fatal(1,"disabled automatic mode");
 // Selection timeout stays stopped and user exit remains possible.
 tick();next=1;tick();next=0;wait(select);repeat(110)tick();
 if(!failed||play)$fatal(1,"missing bounded audio selection failure");
 mode=0;repeat(3)tick();if(failed||switching||play)$fatal(1,"exit from failure");
 // List invalidation while entering prevents stale selected media.
 mode=1;ready_list=0;repeat(3)tick();if(play||select)$fatal(1,"played before directory ready");
 mode=0;clear=1;tick();clear=0;repeat(3)tick();if(duplicate)$fatal(1,"rescan did not clear duplicate");
 // The current real card has only slot1. Previous/next/EOF must all restart it.
 add(0,"M1",100);add(1,"V1",1100);repeat(4)tick();
 ready_list=1;mode=1;audio_handshake();if(index!=0)$fatal(1,"single movie entry");
 move(0,0);move(1,0);move(0,0);move(1,0);
 if(!auto_en)begin tick();toggle=1;tick();toggle=0;end
 tick();ended=1;tick();ended=0;audio_handshake();if(index!=0)$fatal(1,"single movie auto repeat");
 $display("PASS catalog pairing, partial/duplicate files, 32 manual switches, multi/single-file auto EOF, disabled auto, audio timeout, exit/rescan; selections=%0d",selections);
 $finish;
end
initial begin #100000;$fatal(1,"test timeout state=%0d",ctrl.state);end
endmodule
