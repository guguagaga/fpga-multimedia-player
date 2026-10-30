`timescale 1ns/1ps
module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg req=0,inv=0;reg[1:0]owner=3;reg[31:0]virtual_lba=1000,base_lba=1000;
wire[7:0]data,raw_data;wire valid,done,err,sdreq,sdmulti,raw_valid,raw_done,init;
wire[31:0]lba;wire[3:0]error_code;
fat32_sector_mapper #(.PHYSICAL_PREFETCH_BLOCKS(64),.IO_TIMEOUT(1000000)) mapper(
 .clk(clk),.rst(rst),.invalidate(inv),.mounted(1'b1),.fat_start_lba(32'd10),.data_start_lba(32'd1000),.cluster_shift(4'd4),.max_cluster(28'd31),
 .req(req),.owner(owner),.virtual_lba(virtual_lba),.file_base_lba(base_lba),.multi(owner==3),.pace(1'b0),
 .data(data),.valid(valid),.done(done),.error(err),.error_code(error_code),.sd_req(sdreq),.sd_lba(lba),.sd_multi(sdmulti),
 .sd_data(raw_data),.sd_valid(raw_valid),.sd_done(raw_done));
wire cmdreq,brreq;wire[47:0]cmd;wire[15:0]blocks;
reg cmdack=0,brvalid=0,brack=0;reg[7:0]brdata=0;
sd_card_sec_read_write #(.PREFETCH_BLOCKS(64),.PREFETCH_BRAM32(1)) sd(
 .clk(clk),.rst(rst),.sd_init_done(init),.sd_sec_read(sdreq),.sd_sec_read_addr(lba),.multi_en(sdmulti),.multi_paced(1'b0),
 .sd_sec_read_data(raw_data),.sd_sec_read_data_valid(raw_valid),.sd_sec_read_end(raw_done),
 .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
 .cmd_req(cmdreq),.cmd_req_ack(cmdack),.cmd_req_error(1'b0),.cmd(cmd),
 .block_read_req(brreq),.block_read_valid(brvalid),.block_read_data(brdata),.block_read_req_ack(brack),.rd_nb_blk(blocks),
 .block_write_data_rd(1'b0),.block_write_req_ack(1'b0));
integer cycles=0,cmd_wait=0,cmd_delay=0,waiting=0,active=0,at=0,total=0,start_lba=0;
integer multi_count=0,single_count=0,checks=0,requests=0;
function[31:0]fat;input integer c;begin
 case(c)2:fat=5;5:fat=3;3:fat=30;30:fat=31;31:fat=32'h0fffffff;
 10:fat=11;11:fat=9;9:fat=32'h0fffffff;default:fat=32'h0fffffff;endcase
end endfunction
function[7:0]byte_at;input integer sector,offset;reg[31:0]entry;begin
 if(sector==10)begin entry=fat(offset/4);byte_at=entry>>(8*(offset%4));end
 else byte_at=(sector*73+offset*11)^(sector>>3)^(offset>>2);
end endfunction
function integer physical;input integer client,offset;integer c;begin
 if(client==3)case(offset/16)0:c=2;1:c=5;2:c=3;3:c=30;4:c=31;default:c=-10000;endcase
 else case(offset/16)0:c=10;1:c=11;2:c=9;default:c=-10000;endcase
 physical=1000+(c-2)*16+(offset%16);
end endfunction
always@(negedge clk)begin
 cycles=cycles+1;cmdack=0;brvalid=0;brack=0;
 if(!rst)begin
  if(cmdreq&&!cmd_wait)begin cmd_wait=1;cmd_delay=7;end
  if(cmd_wait&&cmd_delay>0)begin cmd_delay=cmd_delay-1;if(cmd_delay==0)begin cmdack=1;start_lba=cmd[39:8];end end
  if(!cmdreq)cmd_wait=0;
  if(brreq&&!waiting&&!active)begin
   waiting=1;active=1;at=0;total=blocks*512;
   if(blocks==64)begin
    multi_count=multi_count+1;
    if(start_lba<1000||start_lba+64>1480)$fatal(1,"prefetch crosses volume %0d",start_lba);
   end else if(blocks==1)single_count=single_count+1;
   else $fatal(1,"unexpected block count %0d",blocks);
  end
  if(!brreq)waiting=0;
  if(active&&cycles%2==0)begin
   brvalid=1;brdata=byte_at(start_lba+at/512,at%512);at=at+1;
   if(at==total)begin active=0;brack=1;end
  end
 end
end
task request_sector;input integer client,offset;integer n,target,deadline;begin
 @(negedge clk);#1;owner=client;base_lba=client==3?1000:1128;virtual_lba=base_lba+offset;req=1;n=0;target=physical(client,offset);deadline=cycles+200000;
 while(!done)begin
  @(posedge clk);
  if(err)$fatal(1,"mapper error %0d",error_code);
  if(valid)begin
   if(n>=512||data!==byte_at(target,n))$fatal(1,"wrong physical sector owner=%0d off=%0d byte=%0d got=%h exp=%h",client,offset,n,data,byte_at(target,n));
   n=n+1;checks=checks+1;
  end
  if(cycles>deadline)$fatal(1,"timeout");
  @(negedge clk);#1;
 end
 if(n!=512)$fatal(1,"sector length %0d",n);
 req=0;requests=requests+1;repeat(8)@(negedge clk);
end endtask
integer j;
initial begin
 repeat(8)@(negedge clk);#1;rst=0;wait(init);
 for(j=0;j<80;j=j+1)begin request_sector(3,j);if(j%9==0)request_sector(1,(j*5)%48);end
 request_sector(3,0);request_sector(3,47);request_sector(3,79);request_sector(1,0);request_sector(3,64);
 @(negedge clk);#1;inv=1;repeat(4)@(negedge clk);#1;inv=0;
 request_sector(3,16);request_sector(3,32);request_sector(3,63);request_sector(3,79);
 for(j=0;j<3;j=j+1)begin
   wait(!active);repeat(30)@(negedge clk);#1;rst=1;
   repeat(8)@(negedge clk);#1;rst=0;wait(init);
   request_sector(3,0);request_sector(3,79);request_sector(1,47);
 end
 $display("COVERAGE multi=%0d single=%0d checks=%0d requests=%0d",multi_count,single_count,checks,requests);
 if(multi_count<3||single_count<3||checks!=requests*512)$fatal(1,"coverage missing");
 $display("CACHE64_PASS requests=%0d bytes=%0d cmd18=%0d cmd17=%0d",requests,checks,multi_count,single_count);$finish;
end
initial begin #200000000;$fatal(1,"global timeout");end
endmodule
