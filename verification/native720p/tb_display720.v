`timescale 1ns/1ps
// Check real timing/coordinate/AXI bridge sources over complete frames.
module tb;
 reg clk=0,rst=1;always #5 clk=~clk;
 wire hs,vs,de;wire[10:0]x;wire[9:0]y;
 wire valid,last,user;wire[23:0]data;
 video_timing_gen timing(.clk(clk),.rst(rst),.hs(hs),.vs(vs),.de(de));
 video_coord coord(.clk(clk),.rst_n(!rst),.de(de),.vs(vs),.active_x(x),.active_y(y));
 video_rgb_to_axis_640x480 #(.WIDTH(1280)) axis(.I_clk(clk),.I_rst(rst),
  .I_vs(vs),.I_de(de),.I_rgb({3'd0,x,y}),.O_video_user(user),
  .O_video_valid(valid),.O_video_last(last),.O_video_data(data));
 integer cycles=0,previous_vs=-1,frames=0,n=0,line=0,pixels=0,sofs=0,rows=0;
 reg old_vs=0,old_de=0;
 initial begin repeat(5)@(negedge clk);rst=0;end
 always @(posedge clk)if(!rst)begin
  if(de)begin
   if(x!==n || y!==rows)$fatal(1,"coordinate x=%d y=%d expected=%d,%d",x,y,n,rows);
   n=n+1;pixels=pixels+1;
  end else if(old_de)begin
   if(n!=1280)$fatal(1,"line length %d",n);
   n=0;rows=rows+1;
  end
  old_de=de;
 end
 always @(negedge clk)if(!rst)begin
  cycles=cycles+1;
  if(valid)begin
   if(user)begin if(line!=0)$fatal(1,"SOF at nonzero x");sofs=sofs+1;end
   line=line+1;
   if(last)begin if(line!=1280)$fatal(1,"AXI last column %d",line);line=0;end
  end
  if(vs&&!old_vs)begin
   if(previous_vs>=0)begin
    // Reset starts inside initial VS; measure periods after that startup edge.
    if(frames>0 && cycles-previous_vs!=1237500)$fatal(1,"frame period %d",cycles-previous_vs);
    if(pixels!=921600 || rows!=720 || sofs!=1 || line!=0)
     $fatal(1,"frame geometry pixels=%d rows=%d SOF=%d AXI_x=%d",pixels,rows,sofs,line);
    frames=frames+1;$display("CHECKED display720 frame=%d pixels=%d",frames,pixels);
    if(frames==4)begin $display("PASS display720 4 frames: 1650x750, 1280x720 pixels, 11bit coordinates, AXI SOF/EOL");$finish;end
   end
   pixels=0;rows=0;sofs=0;previous_vs=cycles;
  end
  old_vs=vs;
  if(cycles>6500000)$fatal(1,"timeout");
 end
endmodule
