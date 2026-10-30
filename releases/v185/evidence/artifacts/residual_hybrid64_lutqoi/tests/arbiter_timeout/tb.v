`timescale 1ns/1ps
module tb;
reg clk=0,rst=1;always #5 clk=~clk;
reg[3:0]req=0;reg boot=0,defer=0,done=0,valid=0;reg[7:0]data=0;
wire[31:0]addr0,addr1,addr2;wire[2:0]g0,g1,g2;wire r0,r1,r2;
wire[35:0]o0,o1,o2;
integer cycles=0,k,checks=0,deadline;
always@(negedge clk)cycles=cycles+1;
sd_arbiter_reference a0(.clk(clk),.rst(rst),
 .img_sd_sec_read(req[0]),.img_sd_sec_read_addr(32'h1111),.img_sd_sec_read_data(o0[7:0]),.img_sd_sec_read_data_valid(o0[8]),.img_sd_sec_read_end(o0[9]),
 .wav_sd_sec_read(req[1]),.wav_sd_sec_read_addr(32'h2222),.wav_sd_sec_read_data(o0[17:10]),.wav_sd_sec_read_data_valid(o0[18]),.wav_sd_sec_read_end(o0[19]),
 .fat_sd_sec_read(req[2]),.fat_sd_sec_read_addr(32'h3333),.fat_sd_sec_read_data(o0[27:20]),.fat_sd_sec_read_data_valid(o0[28]),.fat_sd_sec_read_end(o0[29]),
 .vid_sd_sec_read(req[3]),.vid_sd_sec_read_addr(32'h4444),.vid_sd_sec_read_data(),.vid_sd_sec_read_data_valid(o0[30]),.vid_sd_sec_read_end(o0[31]),
 .img_priority(boot),.wav_grant(g0[0]),.img_grant(g0[1]),.vid_grant(g0[2]),
 .sd_sec_read(r0),.sd_sec_read_addr(addr0),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done));
assign o0[35:32]=0;
sd_arbiter a1(.clk(clk),.rst(rst),
 .img_sd_sec_read(req[0]),.img_sd_sec_read_addr(32'h1111),.img_sd_sec_read_data(o1[7:0]),.img_sd_sec_read_data_valid(o1[8]),.img_sd_sec_read_end(o1[9]),
 .wav_sd_sec_read(req[1]),.wav_sd_sec_read_addr(32'h2222),.wav_sd_sec_read_data(o1[17:10]),.wav_sd_sec_read_data_valid(o1[18]),.wav_sd_sec_read_end(o1[19]),
 .fat_sd_sec_read(req[2]),.fat_sd_sec_read_addr(32'h3333),.fat_sd_sec_read_data(o1[27:20]),.fat_sd_sec_read_data_valid(o1[28]),.fat_sd_sec_read_end(o1[29]),
 .vid_sd_sec_read(req[3]),.vid_sd_sec_read_addr(32'h4444),.vid_sd_sec_read_data(),.vid_sd_sec_read_data_valid(o1[30]),.vid_sd_sec_read_end(o1[31]),
 .img_priority(boot),.wav_grant(g1[0]),.img_grant(g1[1]),.vid_grant(g1[2]),
 .sd_sec_read(r1),.sd_sec_read_addr(addr1),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),.defer_audio(defer));
assign o1[35:32]=0;
sd_arbiter #(.PREFETCH_AWARE(1),.MAX_DEFER_CYCLES(1400000)) a2(.clk(clk),.rst(rst),
 .img_sd_sec_read(req[0]),.img_sd_sec_read_addr(32'h1111),.img_sd_sec_read_data(o2[7:0]),.img_sd_sec_read_data_valid(o2[8]),.img_sd_sec_read_end(o2[9]),
 .wav_sd_sec_read(req[1]),.wav_sd_sec_read_addr(32'h2222),.wav_sd_sec_read_data(o2[17:10]),.wav_sd_sec_read_data_valid(o2[18]),.wav_sd_sec_read_end(o2[19]),
 .fat_sd_sec_read(req[2]),.fat_sd_sec_read_addr(32'h3333),.fat_sd_sec_read_data(o2[27:20]),.fat_sd_sec_read_data_valid(o2[28]),.fat_sd_sec_read_end(o2[29]),
 .vid_sd_sec_read(req[3]),.vid_sd_sec_read_addr(32'h4444),.vid_sd_sec_read_data(),.vid_sd_sec_read_data_valid(o2[30]),.vid_sd_sec_read_end(o2[31]),
 .img_priority(boot),.wav_grant(g2[0]),.img_grant(g2[1]),.vid_grant(g2[2]),
 .sd_sec_read(r2),.sd_sec_read_addr(addr2),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(done),.defer_audio(defer));
assign o2[35:32]=0;
always@(negedge clk)if(!rst)begin
 if({addr0,g0,r0,o0}!=={addr1,g1,r1,o1})$fatal(1,"default legacy mismatch");
 checks=checks+1;
end
task reset;
begin rst=1;req=0;done=0;valid=0;repeat(4)@(negedge clk);#1;rst=0;end
endtask
task complete;
begin @(negedge clk);#1;done=1;@(negedge clk);#1;done=0;repeat(20)@(negedge clk);#1;end
endtask
initial begin
 reset;
 // Default mode must be identical even with a noisy optional input.
 for(k=0;k<20000;k=k+1)begin
  @(negedge clk);#1;req=$urandom;boot=$urandom;defer=$urandom;done=$urandom;valid=$urandom;data=$urandom;
 end
 reset;boot=0;defer=1;req=4'b1010;
 repeat(3)@(negedge clk);#1;
 if(!g2[2]||g2[0])$fatal(1,"cached video not admitted while audio deferred");
 req=4'b0010;complete;
 // Reserve goes low: top removes defer, even if physical burst continues.
 defer=0;deadline=cycles+24;
 while(!g2[0])begin @(negedge clk);#1;if(cycles>deadline)$fatal(1,"low reserve did not admit audio");end
 // Accepted ownership survives cancellation and a new defer condition.
 req=0;defer=1;repeat(12)begin @(negedge clk);#1;if(!g2[0]||addr2!=32'h2222)$fatal(1,"accepted owner revoked");end
 complete;
 reset;defer=1;req=4'b0010;deadline=cycles+1400008;
 while(!g2[0])begin @(negedge clk);#1;if(cycles>deadline)$fatal(1,"bounded defer timeout failed");end
 if(cycles<deadline-9)$fatal(1,"timeout admitted too early");
 req=0;complete;
 reset;defer=1;req=4'b0010;repeat(12)@(negedge clk);#1;req=0;repeat(5)@(negedge clk);#1;
 req=4'b0010;repeat(10)@(negedge clk);#1;if(g2[0])$fatal(1,"canceled request retained defer timeout");
 defer=0;deadline=cycles+24;
 while(!g2[0])begin @(negedge clk);#1;if(cycles>deadline)$fatal(1,"busy-release admission failed");end
 $display("ARBITER_POLICY_PASS legacy_checks=%0d ownership reserve timeout cancel release",checks);$finish;
end
initial begin #30000000;$fatal(1,"timeout");end
endmodule
