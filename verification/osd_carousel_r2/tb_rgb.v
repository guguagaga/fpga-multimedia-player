`timescale 1ns/1ps
module tb;
reg clk=0,rst_n=1,de=0,vs=1;
always #5 clk=~clk;
reg [10:0] x=0; reg [9:0] y=0;
reg enabled=0; reg [9:0] seconds=2; reg [3:0] sw=0;
wire [7:0] ro,go,bo;wire deo,vso;
osd_player_ui #(.TICK_CYCLES(20)) dut(.clk(clk),.rst_n(rst_n),.de(de),.vs(vs),.screen_x(x),.screen_y(y),
.video_r(8'h11),.video_g(8'h22),.video_b(8'h33),.tot_sec(16'd0),.cur_sec(16'd0),.progress(8'd0),
.song_name(64'h5445535420202020),.sample_rate(32'd48000),.channels(16'd1),.bit_depth(16'd16),
.volume(5'd31),.pause(1'b0),.carousel_on(enabled),.carousel_period_sec(seconds),.video_mode(1'b0),.sw_deg(sw),
.kp_debug(1'b0),.kp_image(16'd0),.kp_row(2'd0),.kp_col(4'd0),.kp_key(4'd0),.osd_r(ro),.osd_g(go),.osd_b(bo),.de_out(deo),.vs_out(vso));
integer periods[0:15];reg [87:0] expected_text;reg [7:0] font[0:1519];reg [7:0] expected_char;
reg [23:0] expected_rgb;integer code,ix,iy,idx,rr,cc,bits,total_pixels=0;
task frame;begin @(negedge clk);vs=1;repeat(3)@(negedge clk);vs=0;repeat(3)@(negedge clk);end endtask
task capture(input integer xx,input integer yy);begin
 @(negedge clk);x=xx;y=yy;de=1;
 repeat(4)@(posedge clk);#1;
 if(deo!==1 || vso!==vs)$fatal(1,"DE/VS phase");
end endtask
task check_string;begin
 for(idx=0;idx<11;idx=idx+1)begin
  @(negedge clk);x=608+idx*16;y=18;#1;
  expected_char=expected_text[87-idx*8-:8];
  if(dut.char_code!==expected_char)$fatal(1,"text seconds=%0d idx=%0d actual=%h expected=%h",seconds,idx,dut.char_code,expected_char);
 end
end endtask
task check_pixels;begin
 for(iy=18;iy<42;iy=iy+1)for(ix=608;ix<784;ix=ix+1)begin
  idx=((ix/2)-304)/8;expected_char=expected_text[87-idx*8-:8];
  rr=(iy*2/3)-12;cc=(ix/2)%8;
  bits=font[(expected_char-32)*16+rr] & (128>>cc);
  expected_rgb=bits ? 24'heff0f0 : 24'h0a1019;
  capture(ix,iy);
  if({ro,go,bo}!==expected_rgb)$fatal(1,"RGB sec=%0d xy=%0d,%0d got=%h exp=%h",seconds,ix,iy,{ro,go,bo},expected_rgb);
  total_pixels=total_pixels+1;
 end
end endtask
initial begin
 $readmemh("font_8x16.mem",font);
 periods[0]=2;periods[1]=3;periods[2]=5;periods[3]=8;periods[4]=10;periods[5]=15;periods[6]=20;periods[7]=30;
 periods[8]=45;periods[9]=60;periods[10]=90;periods[11]=120;periods[12]=180;periods[13]=240;periods[14]=300;periods[15]=600;
 #1 rst_n=0;#30 rst_n=1;
 enabled=0;frame;expected_text="AUTO: OFF  ";check_string;check_pixels;
 enabled=1;
 for(code=0;code<16;code=code+1)begin
  seconds=periods[code];frame;
  if(seconds<10)expected_text={"AUTO:  ",(8'h30+8'(seconds)),"s  "};
  else if(seconds<100)expected_text={"AUTO: ",(8'h30+8'(seconds/10)),(8'h30+8'(seconds%10)),"s  "};
  else expected_text={"AUTO: ",(8'h30+8'(seconds/100)),(8'h30+8'((seconds/10)%10)),(8'h30+8'(seconds%10)),"s "};
  check_string;check_pixels;
 end
 // A new effective config cannot tear a frame; it appears at next VS.
 seconds=2;enabled=0;check_string;
 frame;expected_text="AUTO: OFF  ";check_string;
 sw=4'b1111;repeat(3)@(posedge clk);#1;if(dut.pshow!==1)$fatal(1,"B/C priority not active");
 @(negedge clk);x=608;y=18;#1;if(dut.char_code!=="B")$fatal(1,"B/C text priority");
 repeat(100)@(posedge clk);#1;if(dut.pshow!==0)$fatal(1,"B/C timeout");check_string;
 $display("PASS all 16 intervals, OFF, final RGB %0d pixels, frame snapshot, B/C priority",total_pixels);$finish;
end
endmodule
