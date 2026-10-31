`timescale 1ns/1ps
module tb;
reg clk=0,rst_n=1,de=0,vs=1;always #5 clk=~clk;
reg[10:0]x=0;reg[9:0]y=0;
wire[23:0]out_rgb,ref_rgb;wire out_de,ref_de,out_vs,ref_vs;
osd_player_ui dut(.clk(clk),.rst_n(rst_n),.de(de),.vs(vs),.screen_x(x),.screen_y(y),
.video_r(8'h44),.video_g(8'h66),.video_b(8'h88),.tot_sec(16'd270),.cur_sec(16'd0),.progress(8'd0),
.song_name(64'h5445535420202020),.sample_rate(32'd48000),.channels(16'd1),.bit_depth(16'd16),
.volume(5'd31),.pause(1'b0),.carousel_on(1'b1),.carousel_period_sec(10'd10),.video_mode(1'b0),.sw_deg(4'd0),
.kp_debug(1'b0),.kp_image(16'd0),.kp_row(2'd0),.kp_col(4'd0),.kp_key(4'd0),
.osd_r(out_rgb[23:16]),.osd_g(out_rgb[15:8]),.osd_b(out_rgb[7:0]),.de_out(out_de),.vs_out(out_vs));
reference_osd refdut(.clk(clk),.rst_n(rst_n),.de(de),.vs(vs),.screen_x(x),.screen_y(y),
.video_r(8'h44),.video_g(8'h66),.video_b(8'h88),.tot_sec(16'd270),.cur_sec(16'd0),.progress(8'd0),
.song_name(64'h5445535420202020),.sample_rate(32'd48000),.channels(16'd1),.bit_depth(16'd16),
.volume(5'd31),.pause(1'b0),.sw_deg(4'd0),
.kp_debug(1'b0),.kp_image(16'd0),.kp_row(2'd0),.kp_col(4'd0),.kp_key(4'd0),
.osd_r(ref_rgb[23:16]),.osd_g(ref_rgb[15:8]),.osd_b(ref_rgb[7:0]),.de_out(ref_de),.vs_out(ref_vs));
reg[10:0]x_d,x_out;reg[9:0]y_d,y_out;
always @(posedge clk)begin x_d<=x;x_out<=x_d;y_d<=y;y_out<=y_d;end
integer xx,yy,checked=0,different=0,fd;
always @(posedge clk)begin
 #1;
 if(rst_n && out_de)begin
  if(out_de!==ref_de || out_vs!==ref_vs)$fatal(1,"DE/VS mismatch");
  if((^out_rgb)===1'bx || (^ref_rgb)===1'bx)$fatal(1,"Unknown RGB %0d %0d",x_out,y_out);
  if(out_rgb!==ref_rgb)begin
   if(x_out<608 || x_out>=784 || y_out<18 || y_out>=42)$fatal(1,"outside status changed at %0d %0d",x_out,y_out);
   different=different+1;
  end
  checked=checked+1;
  if(y_out<96)$fwrite(fd,"%c%c%c",out_rgb[23:16],out_rgb[15:8],out_rgb[7:0]);
 end
end
initial begin
 fd=$fopen("top_rtl.ppm","wb");$fwrite(fd,"P6\n1280 96\n255\n");
 #1 rst_n=0;#30 rst_n=1;repeat(6)@(negedge clk);vs=0;repeat(6)@(negedge clk);
 for(yy=0;yy<720;yy=yy+1)begin
  for(xx=0;xx<1280;xx=xx+1)begin @(negedge clk);x=xx;y=yy;de=1;end
  @(negedge clk);de=0;repeat(8)@(negedge clk);
 end
 repeat(6)@(negedge clk);$fclose(fd);
 if(checked!=921600 || different==0)$fatal(1,"coverage %0d changed %0d",checked,different);
 $display("PASS 921600 full-frame RGB pixels, only status rectangle differs, %0d changed",different);$finish;
end
endmodule
