`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;reg rst=1,scan=0;reg[7:0]data=0;reg valid=0,se=0;
wire req,ready,geom,bad;wire[31:0]addr,base,fat,vid,vau,sec;wire[27:0]maxc;wire[3:0]shift;wire[5:0]count;wire[63:0]name;reg[4:0]idx=0;
wire[2:0]images;wire[31:0]im0,im1,im2,im3;
wire ev,ea,dup;wire[15:0]ep;wire[31:0]es,sv,sa;wire[3:0]mask;reg[1:0]slot=0;
video_catalog catalog(.clk(clk),.rst(rst),.clear(1'b0),.entry_valid(ev),.entry_audio(ea),.entry_prefix(ep),.entry_sector(es),.index(slot),.legacy_video(vid),.legacy_audio(vau),.available(mask),.selected_video(sv),.selected_audio(sa),.duplicate_seen(dup));
integer events=0;always@(posedge clk)if(!rst&&ev)events=events+1;
fat32_list dut(.media_entry_valid(ev),.media_entry_audio(ea),.media_entry_prefix(ep),.media_entry_sector(es),.clk(clk),.rst(rst),.scan_start(scan),.sd_init_done(1'b1),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(se),.list_ready(ready),.song_count(count),.list_idx(idx),.list_name(name),.list_sector(sec),.data_start_o(base),.video_sector_o(vid),.vaudio_sector_o(vau),.image_count_o(images),.image0_o(im0),.image1_o(im1),.image2_o(im2),.image3_o(im3),.fat_start_o(fat),.cluster_shift_o(shift),.max_cluster_o(maxc),.geometry_valid_o(geom),.filesystem_error_o(bad));
reg[7:0]disk[0:1999999];integer bytes,spc,part,active,expect_bad,j,lba,transactions=0;reg[31:0]held;
initial begin
 if(!$value$plusargs("BYTES=%d",bytes)||!$value$plusargs("SPC=%d",spc)||!$value$plusargs("PART=%d",part)||!$value$plusargs("ACTIVE=%d",active)||!$value$plusargs("BAD=%d",expect_bad))$fatal(1,"args");
 $readmemh("disk.hex",disk,0,bytes-1);repeat(8)@(negedge clk);rst=0;scan=1;@(negedge clk);scan=0;
 wait(ready);repeat(14)@(negedge clk);
 if(bad!==expect_bad[0])$fatal(1,"filesystem error %d expected %d",bad,expect_bad);
 if(!expect_bad)begin
  if(!geom||base!=part+18||fat!=part+2+active*8||maxc!=((2000-18)/spc)+1)$fatal(1,"geometry base=%d fat=%d max=%d",base,fat,maxc);
  if(count!=2||vid!=base+(30-2)*spc||vau!=base+(43-2)*spc||images!=1||im0!=base+(50-2)*spc)$fatal(1,"fragment root metadata count=%d vid=%d vau=%d images=%d im=%d",count,vid,vau,images,im0);
  if(mask!==4'b1011 || !dup || events!=10)$fatal(1,"catalog mask=%b dup=%b events=%d",mask,dup,events);
  slot=0;repeat(8)@(negedge clk);if(sv!=base+28*spc||sa!=base+38*spc)$fatal(1,"pair1");
  slot=1;repeat(8)@(negedge clk);if(sv!=base+29*spc||sa!=base+39*spc)$fatal(1,"pair2");
  slot=2;repeat(8)@(negedge clk);if(sv!=0||sa!=0)$fatal(1,"incomplete pair");
  slot=3;repeat(8)@(negedge clk);if(sv!=base+31*spc||sa!=base+41*spc)$fatal(1,"pair4");
  idx=0;repeat(12)@(negedge clk);if(name!==64'h534f4e4741202020||sec!=base+8*spc)$fatal(1,"song A");
  idx=1;repeat(12)@(negedge clk);if(name!==64'h534f4e4742202020||sec!=base+18*spc)$fatal(1,"song B");
 end
 $display("PASS fragmented root spc=%d partition=%d active_fat=%d bad=%d transactions=%d",spc,part,active,expect_bad,transactions);$finish;
end
initial begin wait(!rst);forever begin
 @(negedge clk);if(req)begin
  held=addr;transactions=transactions+1;if(held*512+511>=bytes)$fatal(1,"out of disk %d",held);
  repeat(4)@(negedge clk);
  for(j=0;j<512;j=j+1)begin data=disk[held*512+j];valid=1;@(negedge clk);valid=0;if(j%5==0)repeat(2)@(negedge clk);end
  se=1;@(negedge clk);se=0;repeat(5)@(negedge clk);
 end
end end
initial begin #20000000;$fatal(1,"root scan timeout");end
endmodule
