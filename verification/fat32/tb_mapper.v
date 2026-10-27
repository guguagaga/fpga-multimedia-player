`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,inv=0,mounted=1,req=0,multi=0,pace=0;reg[1:0]owner=0;
reg[31:0]vlba=0,base=0;reg[3:0]shift=0;reg[27:0]maxc=10000;
wire[7:0]data;wire valid,done,error;wire[3:0]ec;wire[1:0]eo;
wire sr,sm,sp;wire[31:0]sa;reg[7:0]sd=0;reg sv=0,se=0;
fat32_sector_mapper #(.IO_TIMEOUT(100),.MAX_WALK(64))dut(clk,rst,inv,mounted,32'd10,32'd1000,shift,maxc,req,owner,vlba,base,multi,pace,data,valid,done,error,ec,eo,sr,sa,sm,sp,sd,sv,se);
integer fault_mode=0,transactions=0,fat_reads=0,media_reads=0,checks=0,owner_override=-1;
reg stall_forever=0,short_fat=0;
function[27:0]node;input integer f,k;begin node=2+f*1000+((k*53)%997);end endfunction
function[31:0]fat;input integer c;integer f,k;begin
 fat=0;
 for(f=0;f<3;f=f+1)for(k=0;k<40;k=k+1)if(c==node(f,k))begin
  if(k==39)fat=32'h0ffffff8;else fat={4'hf,node(f,k+1)};
 end
 if(fault_mode==1&&c==node(0,0))fat=32'h0ffffff7;
 if(fault_mode==2&&c==node(0,0))fat=0;
 if(fault_mode==3&&c==node(0,0))fat=node(0,0);
 if(fault_mode==4&&c==node(0,2))fat=node(0,1);
 if(fault_mode==5&&c==node(0,0))fat=32'h0ffffff8;
end endfunction
function[7:0]value;input integer lba,b;begin value=(lba*19+b*7)^(lba>>7);end endfunction
integer b,c,n;reg[31:0]entry,addr;
initial begin
 wait(!rst);
 forever begin
  @(negedge clk);
  if(sr)begin
   if(transactions<8)$display("SD BEGIN t=%t state=%d lba=%d",$time,dut.state,sa);addr=sa;transactions=transactions+1;
   if(addr<1000)begin fat_reads=fat_reads+1;if(sm||sp)$fatal(1,"FAT multi/pace");end
   else begin media_reads=media_reads+1;
    if(sm&&(((addr-1000)&((1<<shift)-1))+16>(1<<shift)))$fatal(1,"CMD18 crossed cluster");
   end
   if(stall_forever)wait(!sr);
   else begin
    repeat(3)@(negedge clk);
    n=(short_fat&&addr<1000)?511:512;
    for(b=0;b<n;b=b+1)begin
     if(addr<1000&&addr!=77)begin c=(addr-10)*128+b/4;entry=fat(c);sd=entry>>(8*(b%4));end
     else sd=value(addr,b);
     sv=1;@(negedge clk);sv=0;
     if(b%13==0)repeat(2)@(negedge clk);
    end
    if(transactions<8)$display("SD END t=%t lba=%d",$time,addr);se=1;@(negedge clk);se=0;
   end
   wait(!sr);repeat(2)@(negedge clk);
  end
 end
end
task transfer;
 input integer f,k,so,expected_error;
 integer got,cycles;reg[31:0]physical;reg finished,failed;reg[3:0]code_seen;reg[1:0]owner_seen;
 begin
  @(negedge clk);owner=f==3?2:(f==2?3:f);multi=1;pace=(f==0);base=1000+((node(f==3?0:f,0)-2)<<shift);
  if(owner_override>=0)owner=owner_override;
  vlba=f==3?32'd77:base+(k<<shift)+so;physical=f==3?77:1000+((node(f,k)-2)<<shift)+so;
  req=1;got=0;cycles=0;finished=0;failed=0;if(transactions<8)$display("CLIENT owner=%d k=%d t=%t",f,k,$time);
  while(!finished&&cycles<200000)begin
   @(posedge clk);
   if(done)begin finished=1;failed=error;code_seen=ec;owner_seen=eo;end
   if(valid)begin
    if(expected_error)$fatal(1,"invalid chain produced media");
    if(data!==value(physical,got))$fatal(1,"pixel bytes owner=%d k=%d sector=%d byte=%d got=%h expected=%h phy=%d",f,k,so,got,data,value(physical,got),physical);
    got=got+1;checks=checks+1;
   end
   @(negedge clk);cycles=cycles+1;
  end
  if(!finished)$fatal(1,"mapper hung state=%d",dut.state);
  if(expected_error)begin if(!failed||code_seen!=expected_error||owner_seen!=owner)$fatal(1,"error mismatch got=%d exp=%d",ec,expected_error);end
  else if(failed||got!=512)$fatal(1,"transfer length/error %d %d",got,error);
  req=0;repeat(5)@(negedge clk);
 end
endtask
task clear;begin inv=1;@(negedge clk);inv=0;repeat(3)@(negedge clk);end endtask
integer sh,k,f,j,seed=12345;
initial begin
 repeat(5)@(negedge clk);rst=0;
 for(sh=0;sh<8;sh=sh+1)begin
  shift=sh;clear();
  // Sequential owner interleaving, every sector in short clusters and
  // first/last sectors of long clusters, then backward and random seeks.
  for(k=0;k<8;k=k+1)for(f=0;f<3;f=f+1)begin transfer(f,k,0,0);transfer(f,k,(1<<sh)-1,0);end
  for(j=0;j<16;j=j+1)begin f=$unsigned($random(seed))%3;k=$unsigned($random(seed))%20;transfer(f,k,$unsigned($random(seed))%(1<<sh),0);end
  $display("GEOMETRY PASS sectors_per_cluster=%d checks=%d fat_reads=%d",1<<sh,checks,fat_reads);
 end
 // Raw directory/FAT requests bypass mount validation and never prefetch.
 mounted=0;transfer(3,0,0,0);mounted=1;
 // Several files reuse one owner; cached cursors must match the file base.
 owner_override=0;for(j=0;j<9;j=j+1)transfer(j%3,7-j%4,0,0);owner_override=-1;
 // Invalid directory origin, EOC, bad/free/self-loop, long loop hop bound,
 // malformed FAT sector and a missing SD response.
 shift=4;clear();transfer(0,40,0,6);
 for(j=1;j<=5;j=j+1)begin fault_mode=j;clear();
  if(j==1||j==2)transfer(0,1,0,7);
  if(j==3)transfer(0,1,0,8);
  if(j==4)transfer(0,80,0,3);
  if(j==5)transfer(0,1,0,6);
 end
 fault_mode=0;clear();short_fat=1;transfer(0,1,0,4);short_fat=0;
 clear();stall_forever=1;transfer(0,1,0,5);stall_forever=0;
 clear();mounted=0;transfer(0,0,0,1);mounted=1;
 clear();transfer(0,2,0,0); // Recovery after the fault must not reuse stale cursor/cache.
 $display("PASS FAT mapper checks=%d transactions=%d FAT=%d media=%d",checks,transactions,fat_reads,media_reads);$finish;
end
initial begin #2000000000;$fatal(1,"global timeout");end
endmodule

