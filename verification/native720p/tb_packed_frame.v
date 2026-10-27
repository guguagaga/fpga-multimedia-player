`timescale 1ns/1ps
module tb_packed_frame;
 reg clk=0,memclk=0,readclk=0,rst=1;
 always #5 clk=~clk;
 always #4 memclk=~memclk;
 always #13.468013 readclk=~readclk; // 37.125MHz raster pixel rate
 reg wreq=0,rreq=0,we=0,re=0;
 wire wack,rack,wfinish,rfinish,high;
 reg [31:0] wd=0;
 wire [31:0] rd,md;
 wire mw,mr;wire[20:0]wa,ra;wire[3:0]dm;
 reg[31:0]memory[0:1382399];
 reg[10:0]rv=0;reg[31:0]rdata[0:10];
 integer i,k,wr=0,reads=0,checked=0,cycles=0;
 integer sc=0;
 always @(posedge clk)begin
  sc=sc+1;
  if(sc%500000==0)$display("PROGRESS PACK720 sc=%d bank=%d p=%d wreq=%b wack=%b high=%b wr=%d reads=%d checked=%d ws=%d rs=%d used=%d",sc,bank,p,wreq,wack,high,wr,reads,checked,dut.frame_fifo_write_m0.state,dut.frame_fifo_read_m0.state,dut.write_usedw);
  if(sc==20000)begin
   $display("DETAIL used=%b rdused=%b wdiff=%b rdiff=%b waddr=%b raddr=%b fiforst=%b",dut.write_usedw,dut.rdusedw,dut.write_buf.wr_addr_diff,dut.write_buf.rd_addr_diff,dut.write_buf.wr_addr,dut.write_buf.rd_addr,dut.write_fifo_aclr);
   if(dut.write_usedw===9'bz)$fatal(1,"occupancy undriven");
  end
 end
 reg[1:0] bank=0;
 reg[31:0] expected;
 reg re_d=0;
 wire stall=(cycles%997)<37;
 function [15:0] color;
  input integer p;
  begin color=(p*73)^(p>>7)^16'h6841;end
 endfunction
 function[31:0]rgbx;
  input[15:0]v;
  begin rgbx={{v[15:11],v[15:13]},{v[10:5],v[10:9]},{v[4:0],v[4:2]},8'd0};end
 endfunction
 frame_read_write #(.PACKED565(1),.FRAME_WIDTH(1280),.FRAME_HEIGHT(720)) dut(
  .rst(rst),.mem_clk(memclk),.Sdr_init_done(1'b1),.Sdr_init_ref_vld(1'b0),.Sdr_busy(stall),
  .App_rd_en(mr),.App_rd_addr(ra),.Sdr_rd_en(rv[10]),.Sdr_rd_dout(rdata[10]),
  .read_clk(readclk),.read_req(rreq),.read_req_ack(rack),.read_finish(rfinish),
  .read_addr_0(21'd0),.read_addr_1(21'd460800),.read_addr_2(21'd921600),.read_addr_3(21'd0),
  .read_addr_index(bank),.read_len(21'd460800),.read_en(re),.read_data(rd),
  .App_wr_en(mw),.App_wr_addr(wa),.App_wr_din(md),.App_wr_dm(dm),
  .write_clk(clk),.write_req(wreq),.write_req_ack(wack),.write_finish(wfinish),.write_almost_full(high),
  .write_addr_0(21'd0),.write_addr_1(21'd460800),.write_addr_2(21'd921600),.write_addr_3(21'd0),
  .write_addr_index(bank),.write_len(21'd460800),.write_img_h(16'd720),.write_top_down(1'b0),
  .write_en(we),.write_data(wd));
 always @(posedge memclk)begin
  cycles=cycles+1;
  if(!rst)begin
   if(mw)begin
    if(wa>=1382400)$fatal(1,"memory overflow %d",wa);
    // Vertical reversal acts on 640 packed words/row; pair order stays intact.
    i=(719-(wr/640))*640+wr%640+bank*460800;
    if(wa!==i)$fatal(1,"packed address wr=%d got=%d exp=%d",wr,wa,i);
    if(md!=={color(2*wr+1),color(2*wr)})$fatal(1,"packed data wr=%d",wr);
    memory[wa]<=md;wr=wr+1;
   end
   if(mr)reads=reads+1;
  end
  rv<={rv[9:0],mr};
  rdata[0]<=memory[ra];
  for(k=1;k<=10;k=k+1)rdata[k]<=rdata[k-1];
 end
 always @(posedge readclk)begin
  re_d=re;
  #1;
  if(re_d&&!rst)begin
   i=(719-checked/1280)*1280+checked%1280;
   expected=rgbx(color(i));
   if(rd!==expected)$fatal(1,"read RGB mismatch pixel=%d got=%h exp=%h",checked,rd,expected);
   checked=checked+1;
  end
 end
 integer p,x,y,b;
 initial begin
  repeat(20)@(negedge clk);rst=0;
  for(b=0;b<3;b=b+1)begin
   bank=b;wr=0;reads=0;checked=0;
   @(negedge clk);wreq=1;
   wait(wack);@(negedge clk);wreq=0;
   $display("WRITE ACK bank=%d",bank);
   repeat(30)@(negedge clk);
   for(p=0;p<921600;p=p+1)begin
    while(high)begin we=0;@(negedge clk);end
    we=1;wd=rgbx(color(p));@(negedge clk);
    if(p%131==0)begin we=0;repeat(3)@(negedge clk);end
   end
   we=0;wait(wfinish);repeat(10)@(negedge clk);
   if(wr!=460800)$fatal(1,"wrong word count %d",wr);
   @(negedge readclk);rreq=1;wait(rack);@(negedge readclk);rreq=0;
   repeat(800)@(negedge readclk);
   for(y=0;y<720;y=y+1)begin
    for(x=0;x<1280;x=x+1)begin re=1;@(negedge readclk);end
    re=0;repeat(370)@(negedge readclk);
   end
   repeat(30)@(negedge readclk);
   if(checked!=921600||reads!=460800)$fatal(1,"read length p=%d words=%d",checked,reads);
   $display("PASS PACKED720 bank=%0d pixels=%0d words=%0d",b,checked,wr);
  end
  $display("PASS packed three-buffer 720p memory path, vendor asynchronous FIFOs, stalls and full-frame orientation");$finish;
 end
 initial begin #500000000;$fatal(1,"timeout");end
endmodule
