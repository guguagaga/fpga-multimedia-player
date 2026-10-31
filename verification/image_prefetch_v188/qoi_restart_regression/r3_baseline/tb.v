`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,load=0,ack=0,grant=0,valid=0,ended=0,abortload=0;
always #5 clk=~clk;
reg[7:0]data=0;wire req,wreq,ready,pv,error;wire[23:0]pixel;wire[31:0]addr;
bmp_read #(.SCALING_EN(1)) dut(.clk(clk),.rst(rst),.load_abort(abortload),.sd_error(1'b0),.sd_grant(grant),
.bmp_width(16'd640),.bmp_height(16'd480),.scan_start(1'b0),.scan_start2(1'b0),.scan_abort(1'b0),
.scan_start_sector(32'd0),.scan_start_sector2(32'd0),.scan_max_sector(32'd0),.scan_limited(1'b1),.scan_target_count(3'd1),
.load_start(load),.load_sector(32'd100),.ready(ready),.write_req(wreq),.write_req_ack(ack),.write_almost_full(1'b0),
.sd_init_done(1'b1),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),.bmp_data_wr_en(pv),.bmp_data(pixel),.load_error(error));
reg[7:0]bytes[0:511];integer i,n,seen=0,k,waited;reg[23:0]expected;
always @(posedge clk)if(pv)begin if(pixel!==expected)$fatal(1,"pixel");seen=seen+1;end
task sector;begin
 grant=1;repeat(10)@(negedge clk);
 for(i=0;i<512;i=i+1)begin data=bytes[i];valid=1;@(negedge clk);valid=0;repeat(3)@(negedge clk);end
 ended=1;@(negedge clk);ended=0;grant=0;repeat(20)@(negedge clk);
end endtask
task one_load(input integer number,input integer bad);begin
 for(n=0;n<512;n=n+1)bytes[n]=0;
 bytes[0]="q";bytes[1]="o";bytes[2]="i";bytes[3]="f";bytes[7]=1;bytes[11]=1;bytes[12]=3;
 bytes[14]=8'hfe;bytes[15]=number;bytes[16]=number+1;bytes[17]=number+2;bytes[25]=bad?8'h02:8'h01;
 expected={bytes[15],bytes[16],bytes[17]};seen=0;
 @(negedge clk);load=1;@(negedge clk);load=0;
 wait(req);@(negedge clk);sector;wait(wreq);
 @(negedge clk);ack=1;@(negedge clk);ack=0;
 waited=0;while(!req&&waited<30)begin @(negedge clk);waited=waited+1;end
 if(!req)$fatal(1,"restart prematurely returned idle number=%0d stale_done=%b stale_error=%b",number,dut.q_done,dut.q_error);
 sector;wait(ready);repeat(3)@(negedge clk);
 if(seen!=1 || error!==bad[0])$fatal(1,"completion number=%0d pixels=%0d error=%b",number,seen,error);
end endtask
initial begin
repeat(8)@(negedge clk);rst=0;
one_load(1,0);one_load(2,0);one_load(3,1);one_load(4,0);one_load(5,0);
$display("PASS5 QOI loads without reset, done->start and error->start, exactpixels");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
