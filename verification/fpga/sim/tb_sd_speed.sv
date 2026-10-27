`timescale 1ns/1ps
module tb_sd_speed;
parameter LEGACY=0;
reg clk=0,rst=1;always #5 clk=~clk;
reg[3:0] req=0;reg[31:0]addr[0:3];
wire[7:0] data[0:3];wire[3:0]valid,ended;
wire shared_req,shared_end,shared_valid,wgrant,igrant,vgrant,initdone;
wire[31:0]shared_addr;wire[7:0]shared_data;
wire cs,sck,mosi,miso;wire[4:0]debug_state;
integer token_delay=0,stop_tail=540;reg fail_read=0;
sd_arbiter arb(.clk(clk),.rst(rst),.img_priority(1'b0),
 .img_sd_sec_read(req[0]),.img_sd_sec_read_addr(addr[0]),.img_sd_sec_read_data(data[0]),.img_sd_sec_read_data_valid(valid[0]),.img_sd_sec_read_end(ended[0]),
 .wav_sd_sec_read(req[1]),.wav_sd_sec_read_addr(addr[1]),.wav_sd_sec_read_data(data[1]),.wav_sd_sec_read_data_valid(valid[1]),.wav_sd_sec_read_end(ended[1]),
 .fat_sd_sec_read(req[2]),.fat_sd_sec_read_addr(addr[2]),.fat_sd_sec_read_data(data[2]),.fat_sd_sec_read_data_valid(valid[2]),.fat_sd_sec_read_end(ended[2]),
 .vid_sd_sec_read(req[3]),.vid_sd_sec_read_addr(addr[3]),.vid_sd_sec_read_data(data[3]),.vid_sd_sec_read_data_valid(valid[3]),.vid_sd_sec_read_end(ended[3]),
 .wav_grant(wgrant),.img_grant(igrant),.vid_grant(vgrant),
 .sd_sec_read(shared_req),.sd_sec_read_addr(shared_addr),.sd_sec_read_data(shared_data),.sd_sec_read_data_valid(shared_valid),.sd_sec_read_end(shared_end));
sd_card_top dut(.clk(clk),.rst(rst),.SD_nCS(cs),.SD_DCLK(sck),.SD_MOSI(mosi),.SD_MISO(miso),
 .sd_init_done(initdone),.sd_sec_read(shared_req),.sd_sec_read_addr(shared_addr),.sd_sec_read_data(shared_data),.sd_sec_read_data_valid(shared_valid),.sd_sec_read_end(shared_end),
 .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_read_multi(vgrant),.dbg_sd_state(debug_state));
sd_spi_model card(.rst(rst),.ncs(cs),.sck(sck),.mosi(mosi),.miso(miso),.token_delay(token_delay),.stop_tail(stop_tail),.fail_read(fail_read));
integer count[0:3],expected[0:3],end_count[0:3];
integer cycle=0,c,n,last_cycle,old18,old12,oldbytes;
always @(posedge clk)begin
 cycle=cycle+1;
 if(!rst)for(integer k=0;k<4;k=k+1)begin
  if(valid[k])begin
   if(count[k]>=512)$fatal(1,"too many bytes client=%0d",k);
   if(data[k]!==card.payload(addr[k],count[k]))$fatal(1,"byte mismatch client=%0d lba=%0d off=%0d got=%h expected=%h",k,addr[k],count[k],data[k],card.payload(addr[k],count[k]));
   count[k]=count[k]+1;
  end
  if(ended[k])begin
   if(count[k]!=expected[k])$fatal(1,"end length client=%0d count=%0d expected=%0d",k,count[k],expected[k]);
   end_count[k]=end_count[k]+1;
  end
 end
end
task automatic read_sector(input integer client,input integer lba);
integer ec;
begin
 @(negedge clk);addr[client]=lba;count[client]=0;ec=end_count[client];req[client]=1;
 wait(ended[client]);@(negedge clk);req[client]=0;
 repeat(40)@(negedge clk);
 if(end_count[client]!=ec+1)$fatal(1,"missing/duplicate end client=%0d",client);
end endtask
task automatic measure_single(input integer delay_bytes,input integer lba);
integer startcycle,startbytes,startstop;
begin
 token_delay=delay_bytes;startcycle=cycle;startbytes=card.selected_bytes;startstop=card.cmd12_count;
 read_sector(0,lba);
 if(card.cmd12_count-startstop!=LEGACY)$fatal(1,"CMD17 stop command policy");
 $display("MEASURE legacy=%0d token_delay=%0d cycles=%0d spi_bytes=%0d",LEGACY,delay_bytes,cycle-startcycle,card.selected_bytes-startbytes);
end endtask
initial begin
 for(c=0;c<4;c=c+1)begin addr[c]=0;count[c]=0;expected[c]=512;end_count[c]=0;end
 repeat(10)@(negedge clk);rst=0;
 wait(initdone);repeat(50000)@(negedge clk);
 if(debug_state!=17)$fatal(1,"init not complete state=%0d",debug_state);
 $display("PASS real SPI initialization with 200 kHz divider");
 measure_single(0,101);measure_single(33,102);measure_single(1024,103);
 // Simultaneous audio/image requests and sector ownership handoffs.
 token_delay=71;
 fork read_sector(0,120);read_sector(1,700);read_sector(2,4);join
 $display("PASS image/audio/directory arbitration: exact bytes and one end per request");
 // Video still uses the established 16-block path; audio must not corrupt its cache.
 token_delay=19;old18=card.cmd18_count;old12=card.cmd12_count;
 read_sector(3,1000);
 if(card.cmd18_count!=old18+1||card.cmd12_count!=old12+1)$fatal(1,"CMD18 cleanup changed");
 read_sector(1,800);
 old18=card.cmd18_count;
 for(n=1001;n<1016;n=n+1)read_sector(3,n);
 if(card.cmd18_count!=old18)$fatal(1,"video cache should hit");
 stop_tail=0;read_sector(3,2000);read_sector(0,121);
 $display("PASS CMD18 stop/drain and all 15 cached sectors across an audio read");
 // Cancellation must not release an in-flight sector before its true completion.
 @(negedge clk);addr[0]=122;count[0]=0;req[0]=1;
 wait(igrant);repeat(100)@(negedge clk);req[0]=0;
 wait(ended[0]);repeat(40)@(negedge clk);
 if(count[0]!=512)$fatal(1,"cancelled request lost sector bytes");
 $display("PASS cancelled client request finishes the held sector");
 // Command error releases ownership; subsequent valid read recovers.
 fail_read=1;expected[0]=0;read_sector(0,123);
 fail_read=0;expected[0]=512;read_sector(0,124);
 $display("PASS command error followed by successful fresh CMD17");
 $display("PASS SD speed regression legacy=%0d CMD17=%0d CMD18=%0d CMD12=%0d",LEGACY,card.cmd17_count,card.cmd18_count,card.cmd12_count);
 $finish;
end
initial begin #500000000;$fatal(1,"timeout sd=%0d cmd=%0d spi=%0d",debug_state,dut.sd_card_cmd_m0.state,dut.spi_master_m0.state);end
endmodule

module tb_sd_cmd_tail;
parameter LEGACY=0;
reg clk=0,rst=1;always #5 clk=~clk;
reg cmd_req=0,read_req=0;reg[47:0]cmd=0;reg[15:0]nb=1;
wire cmd_ack,cmd_error,rd_ack,valid,cs,sck,mosi,miso,sreq,sack;wire[7:0]data,tx,rx;wire[15:0]div;
integer token_delay=7,stop_tail=540;
sd_card_cmd ctl(.sys_clk(clk),.rst(rst),.spi_clk_div(16'd0),.cmd_req(cmd_req),.cmd_req_ack(cmd_ack),.cmd_req_error(cmd_error),
 .cmd(cmd),.cmd_r1(8'd0),.cmd_data_len(16'd0),.block_read_req(read_req),.block_read_valid(valid),.block_read_data(data),.block_read_req_ack(rd_ack),
 .block_write_req(1'b0),.block_write_data(8'd0),.nCS_ctrl(cs),.clk_div(div),.spi_wr_req(sreq),.spi_wr_ack(sack),.spi_data_in(tx),.spi_data_out(rx),.nb_blk_in(nb));
spi_master spi(.sys_clk(clk),.rst(rst),.DCLK(sck),.MOSI(mosi),.MISO(miso),.CPOL(1'b1),.CPHA(1'b1),.nCS_ctrl(cs),.clk_div(div),.wr_req(sreq),.wr_ack(sack),.data_in(tx),.data_out(rx));
sd_spi_model card(.rst(rst),.ncs(cs),.sck(sck),.mosi(mosi),.miso(miso),.token_delay(token_delay),.stop_tail(stop_tail),.fail_read(1'b0));
integer got=0,lba_now=0,total=0,stop_before;
always@(posedge clk)if(!rst&&valid)begin
 if(data!==card.payload(lba_now+got/512,got%512))$fatal(1,"command payload mismatch byte %0d",got);
 got=got+1;
end
task automatic transact(input integer id,input integer blocks,input integer lba);
begin
 @(negedge clk);cmd={8'(id),32'(lba),8'hff};nb=blocks;got=0;lba_now=lba;cmd_req=1;stop_before=card.cmd12_count;
 wait(cmd_ack);if(cmd_error)$fatal(1,"command failed");@(negedge clk);cmd_req=0;
 repeat(4)@(negedge clk);read_req=1;
 wait(rd_ack);@(negedge clk);read_req=0;
 repeat(20)@(negedge clk);
 if(got!=blocks*512)$fatal(1,"length %0d wanted %0d",got,blocks*512);
 if(card.cmd12_count-stop_before!=(id==18?1:LEGACY))$fatal(1,"wrong stop policy CMD%0d blocks=%0d",id,blocks);
 $display("PASS command CMD%0d blocks=%0d exact bytes=%0d stop_commands=%0d",id,blocks,got,card.cmd12_count-stop_before);
end endtask
initial begin
 repeat(10)@(negedge clk);rst=0;wait(ctl.state==1);
 transact(17,1,20);transact(18,1,30);transact(17,1,40);transact(18,16,50);transact(17,1,70);
 $display("PASS command-tail regression legacy=%0d",LEGACY);$finish;
end
initial begin #100000000;$fatal(1,"command-tail timeout state=%0d",ctl.state);end
endmodule
