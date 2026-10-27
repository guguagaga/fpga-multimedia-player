
`timescale 1ns/1ps
module tb_image_rows;
reg clk=0,rst=1,load=0,valid=0,ended=0,grant=0,abortload=0,block=0;
always #5 clk=~clk;
reg [7:0] data=0;
wire req,wreq,ready,wen;wire[31:0]addr;wire[23:0]pixel;wire[15:0]oh,ow;
bmp_read #(.SCALING_EN(1)) dut(.clk(clk),.rst(rst),.load_abort(abortload),.sd_grant(grant),
 .bmp_width(16'd640),.bmp_height(16'd480),.scan_start(1'b0),.scan_start2(1'b0),.scan_abort(1'b0),
 .scan_start_sector(32'd0),.scan_start_sector2(32'd0),.scan_max_sector(32'd0),.scan_limited(1'b1),.scan_target_count(3'd4),
 .load_start(load),.load_sector(32'd12345),.ready(ready),.write_req(wreq),.write_req_ack(wreq),.write_almost_full(block),
 .sd_init_done(1'b1),.sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),.sd_sec_read_end(ended),
 .bmp_data_wr_en(wen),.bmp_data(pixel),.img_h_o(oh),.img_w_o(ow));
integer iw,ih,po,flen,n,expectn,step,j,off,txn,cycles,caseid;
reg active=0;reg[23:0]expectpixel;
function[23:0]color;input integer px,py;
 begin color={px[7:0]^py[11:4],py[7:0]^px[11:4],8'(px+py)};end
endfunction
function[7:0]value;input integer offset;
 integer pi;reg[23:0]rgb;
 begin
  case(offset)
   0:value="B";1:value="M";
   2,3,4,5:value=flen>>((offset-2)*8);
   10,11,12,13:value=po>>((offset-10)*8);
   14:value=40;
   18,19,20,21:value=iw>>((offset-18)*8);
   22,23,24,25:value=ih>>((offset-22)*8);
   26:value=1;28:value=24;
   default:begin
    if(offset>=po&&offset<flen)begin pi=(offset-po)/3;rgb=color(pi%iw,pi/iw);value=rgb>>(((offset-po)%3)*8);end
    else value=0;
   end
  endcase
 end
endfunction
always @(negedge clk)begin
 cycles=cycles+1;
 block=(cycles%1237<49);
 if(active&&wen)begin
  expectpixel=color(n%iw,(n/iw)*step);
  if(pixel!==expectpixel||n>=expectn)$fatal(1,"row stream case=%d pixel=%d got=%h expected=%h",caseid,n,pixel,expectpixel);
  n=n+1;
 end
end
initial begin
 cycles=0;
 forever begin
  @(negedge clk);
  if(!rst&&req)begin
   grant=1;txn=txn+1;off=(addr-12345)*512;
   if(off<0||off>=(flen+511)/512*512)$fatal(1,"outside BMP");
   repeat(9)@(negedge clk);
   for(j=0;j<512;j=j+1)begin
    data=value(off+j);valid=1;@(negedge clk);valid=0;repeat(3)@(negedge clk);
   end
   repeat(10)@(negedge clk);
   ended=(txn!=3);@(negedge clk);ended=0;grant=0;
   wait(!req);repeat(6)@(negedge clk);
  end
 end
end
task run_case;input integer w,h,offset,expected_step;
 begin
  @(negedge clk);rst=1;active=0;load=0;
  iw=w;ih=h;po=offset;flen=po+iw*ih*3;
  step=expected_step;expectn=iw*(step>1?480:ih);n=0;txn=0;caseid=caseid+1;
  repeat(10)@(negedge clk);rst=0;load=1;active=1;
  @(negedge clk);load=0;
  wait(!ready);wait(ready);repeat(10)@(negedge clk);
  if(n!=expectn||ow!=iw||oh!=(step>1?480:ih))
    $fatal(1,"count/size case=%d n=%d expect=%d w=%d h=%d",caseid,n,expectn,ow,oh);
  $display("PASS rows case=%0d w=%0d h=%0d offset=%0d step=%0d pixels=%0d sectors=%0d",caseid,iw,ih,po,step,n,txn);
  active=0;
 end
endtask
initial begin
 caseid=0;
 run_case(644,960,1023,2);
 run_case(800,1440,510,3);
 run_case(4096,1920,512,4);
 run_case(800,600,54,1);
 run_case(640,480,54,1);
 $display("PASS all row-selection and fallback tests");$finish;
end
initial begin #(64'd6000000000);$fatal(1,"row test timeout");end
endmodule
