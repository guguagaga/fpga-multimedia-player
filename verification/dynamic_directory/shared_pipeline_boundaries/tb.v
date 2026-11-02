
`timescale 1ns/1ps
module tb;
 reg clk=0; always #5 clk=~clk;
 reg rst=1,scan=0,pause=0,consume=0,dv=0,done=0,err=0;
 reg[7:0]data=0,disk[0:16777215];
 wire req,valid,empty,error,ready,fsbad,geom;
 wire[31:0]addr,lba,vs,va,ls;wire[63:0]ln;wire[5:0] songs;wire[3:0] images;
 wire media_valid;
 integer spc,count,bytes,kind,i,active=0,pos=0,delay=0,base=0,reads=0,cycles=0;
 integer frozen=0;reg [31:0]held;reg[5:0]saved_songs;reg[3:0]saved_images;
 reg[63:0]saved_name;reg[31:0]saved_sector,saved_video,saved_audio;
 fat32_list #(.STREAM_IMAGES(1)) d(.clk(clk),.rst(rst),.scan_start(scan),.sd_init_done(!rst),
 .image_pause(pause),.image_consume(consume),.image_valid(valid),.image_empty(empty),
 .image_error(error),.image_lba(lba),.sd_read_error(err),
 .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),
 .sd_sec_read_data_valid(dv),.sd_sec_read_end(done),.list_ready(ready),
 .song_count(songs),.list_idx(5'd0),.list_name(ln),.list_sector(ls),
 .video_sector_o(vs),.vaudio_sector_o(va),.media_entry_valid(media_valid),
 .image_count_o(images),.filesystem_error_o(fsbad),.geometry_valid_o(geom));
 always @(negedge clk) begin
  cycles=cycles+1;dv=0;done=0;err=0;
  if(!rst)begin
   if(active)begin
    if(delay!=0)delay=delay-1;
    else if(pos<((kind==2 && ready)?101:512))begin
     data=disk[base+pos];dv=1;pos=pos+1;delay=pos%3;
     if(kind==4 && ready && pos==100)err=1;
    end else begin done=1;active=0;delay=6;end
   end else if(delay!=0)delay=delay-1;
   else if(req)begin
    if(addr*512+511>=bytes)$fatal(1,"out of model addr %d",addr);
    base=addr*512;pos=0;active=1;reads=reads+1;
   end
   if(frozen)begin
    if(!ready||!geom||songs!=saved_songs||images!=saved_images||ln!=saved_name||ls!=saved_sector||
       vs!=saved_video||va!=saved_audio||media_valid)$fatal(1,"runtime changed playlist/geometry");
   end
  end
 end
 task take;begin @(negedge clk);consume=1;@(negedge clk);consume=0;end endtask
 initial begin
  if(!$value$plusargs("SPC=%d",spc))$fatal;
  if(!$value$plusargs("COUNT=%d",count))$fatal;
  if(!$value$plusargs("BYTES=%d",bytes))$fatal;
  if(!$value$plusargs("KIND=%d",kind))$fatal;
  $readmemh("disk.hex",disk,0,bytes-1);
  repeat(5)@(negedge clk);rst=0;scan=1;@(negedge clk);scan=0;
  wait(ready);repeat(20)@(negedge clk);
  if(kind==1||kind==3)begin if(!fsbad)$fatal(1,"bad mount accepted");end
  else begin
   if(fsbad||songs!=1||vs==0||va==0)$fatal(1,"mount metadata");
   saved_songs=songs;saved_images=images;saved_name=ln;saved_sector=ls;saved_video=vs;saved_audio=va;frozen=1;
   if(kind==2||kind==4)begin wait(error);if(valid)$fatal;end
   else if(count==0)begin wait(empty);if(error||valid)$fatal;end
   else begin
    for(i=0;i<count*3+1;i=i+1)begin
     wait(valid||error||empty);
     if(!valid||lba!=50+(100+i%count-2)*spc)$fatal(1,"index %d lba %d state %d",i,lba,d.state);
     held=lba;pause=1;
     repeat(7)begin @(negedge clk);if(!valid||lba!=held||req)$fatal(1,"unstable peek");end
     take();repeat(15)@(negedge clk);if(req)$fatal(1,"paused new transaction");pause=0;
     // Pause during an accepted read. It must drain before blocking the next.
     if(i%7==0)begin wait(req);@(negedge clk);pause=1;wait(done);repeat(8)@(negedge clk);pause=0;end
    end
   end
  end
  frozen=0;@(negedge clk);rst=1;active=0;
  repeat(5)@(negedge clk);if(req||valid||ready)$fatal;
  $display("PASS shared count=%0d spc=%0d kind=%0d reads=%0d cycles=%0d",count,spc,kind,reads,cycles);$finish;
 end
 initial begin #500000000; $fatal(1,"timeout state %0d",d.state);end
endmodule
