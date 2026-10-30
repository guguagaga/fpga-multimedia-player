`timescale 1ns/1ps
module tb;
    defparam dut.TREE_FILE="D:/codexworks/framerate_v185_20261029/residual_tree/candidate/project/rtl/residual_tree.mem";
    defparam dut.METADATA_FILE="D:/codexworks/framerate_v185_20261029/residual_tree/candidate/project/rtl/residual_metadata.mem";
reg clk=0,rst=1,start=0;always #5 clk=~clk;
reg[7:0]in_data=0;reg in_valid=0,out_ready=0;
wire in_ready,out_valid,frame_done,fault,raw_valid,raw_ready;
wire[7:0]out_data,raw_data;wire[2:0]raw_context;
context_huffman_decoder #(.SYMBOL_FILE("D:/codexworks/framerate_v185_20261029/residual_tree/candidate/project/rtl/residual_symbols.mem")) dut(
 .clk(clk),.rst(rst),.start(start),.in_data(in_data),.in_valid(in_valid),.in_ready(in_ready),
 .out_data(raw_data),.out_valid(raw_valid),.out_ready(raw_ready),.out_context(raw_context),
 .frame_done(frame_done),.fault(fault));
codec12_lossless_restore restore(clk,rst,start,raw_data,raw_context,raw_valid,raw_ready,out_data,out_valid,out_ready);
reg[7:0]source[0:200000],reference[0:200000];
integer cycles=0,ip,op,begin_cycle;reg[1023:0]filename;
reg held=0;reg[7:0]held_data;
always@(posedge clk)cycles=cycles+1;
task run_frame;input integer index,in_count,out_count;begin
 $sformat(filename,"in%0d.hex",index);$readmemh(filename,source,0,in_count-1);
 $sformat(filename,"out%0d.hex",index);$readmemh(filename,reference,0,out_count-1);
 @(negedge clk);start=1;in_valid=0;out_ready=0;ip=0;op=0;held=0;
 @(negedge clk);start=0;begin_cycle=cycles;
 while(!frame_done || op<out_count)begin
  // A producer retains a valid byte until ready; output has long stalls.
  if(!in_valid)begin in_valid=(ip<in_count)&&(cycles%17>2);in_data=source[ip];end
  out_ready=(cycles%503>73);
  @(posedge clk);
  if(fault)$fatal(1,"decoder fault");
  if(held&&(!out_valid||out_data!==held_data))$fatal(1,"unstable stalled output");
  held=out_valid&&!out_ready;held_data=out_data;
  if(out_valid&&out_ready)begin
   if(op>=out_count||out_data!==reference[op])$fatal(1,"mismatch frame=%0d byte=%0d got=%h expected=%h",index,op,out_data,reference[op]);
   op=op+1;
  end
  if(in_valid&&in_ready)begin ip=ip+1;@(negedge clk);in_valid=0;end
  else @(negedge clk);
 end
 if(ip!=in_count||op!=out_count)$fatal(1,"length mismatch");
 repeat(10)@(negedge clk);
 if(out_valid)$fatal(1,"output after EOF");
 $display("RESTORE_PASS frame=%0d compressed=%0d raw=%0d cycles=%0d",index,ip,op,cycles-begin_cycle);
end endtask
initial begin
 repeat(5)@(negedge clk);rst=0;
 



 run_frame(0,73186,114257);
run_frame(1,72996,114178);
run_frame(2,72741,113406);
run_frame(3,73024,113501);
run_frame(4,73533,113907);
run_frame(5,73232,113763);
run_frame(6,73417,114622);
run_frame(7,73484,115011);
run_frame(8,73687,115399);
run_frame(9,73495,115338);
run_frame(10,73581,115368);
run_frame(11,73509,114832);
run_frame(12,74816,119542);
run_frame(13,74850,119517);
run_frame(14,74477,119429);
run_frame(15,74223,118909);
run_frame(16,74318,119610);
run_frame(17,74192,119739);
run_frame(18,74375,120055);
run_frame(19,74466,120027);
run_frame(20,74835,120143);
run_frame(21,74522,119995);
run_frame(22,74816,120313);
run_frame(23,74845,120163);
run_frame(24,73382,120782);
run_frame(25,73279,120844);
run_frame(26,74317,121136);
run_frame(27,74199,120884);
run_frame(28,74047,120634);
run_frame(29,74014,120656);
run_frame(30,73643,120612);
run_frame(31,73705,120603);
run_frame(32,73728,120762);
run_frame(33,73344,120548);
run_frame(34,73277,120698);
run_frame(35,73125,120519);
run_frame(36,72137,114743);
run_frame(37,72097,114866);
run_frame(38,71992,115063);
run_frame(39,72317,116004);
run_frame(40,73048,117713);
run_frame(41,73482,118149);
run_frame(42,73628,118195);
run_frame(43,73631,117787);
run_frame(44,74020,118163);
run_frame(45,73584,117990);
run_frame(46,73825,118049);
run_frame(47,73759,117756);
run_frame(48,75860,118856);
run_frame(49,75685,119706);
run_frame(50,75405,119995);
run_frame(51,74789,120432);
run_frame(52,75352,121036);
run_frame(53,75278,121018);
run_frame(54,74982,121153);
run_frame(55,74689,121259);
run_frame(56,74701,121219);
run_frame(57,74262,120722);
run_frame(58,74641,120520);
run_frame(59,74536,120178);
run_frame(60,76067,121234);
run_frame(61,75965,121136);
run_frame(62,76050,121205);
run_frame(63,75956,121211);
run_frame(64,76021,121220);
run_frame(65,76022,121226);
run_frame(66,76008,121219);
run_frame(67,76008,121219);
run_frame(68,76003,121220);
run_frame(69,75999,121219);
run_frame(70,76001,121220);
run_frame(71,76004,121219);
$display("ALL_RESIDUAL_PASS");$finish;
end
initial begin #2000000000;$fatal(1,"timeout");end
endmodule
