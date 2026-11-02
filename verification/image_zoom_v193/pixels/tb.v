`timescale 1ns/1ps
module tb;
reg clk=0,rst=1,start=0,zoom=0,valid=0,blocked=0;reg[23:0]pixel=0;
reg[15:0]w=1,h=1,ah=1;wire high,overflow,ov;wire[23:0]op;
always #5 clk=~clk;
image_fit_720p #(.ENABLE_ZOOM(1)) dut(.clk(clk),.rst(rst),.frame_start(start),.zoom_small(zoom),.src_w(w),.src_h(h),.aspect_h(ah),.in_valid(valid),.in_pixel(pixel),.high(high),.overflow(overflow),.out_blocked(blocked),.out_valid(ov),.out_pixel(op));
integer count=0,cycle=0,ix=0,iy=0,fw,fh,l,t,sx,sy,mode,frame=0;reg[23:0]expected;
function[23:0] color(input integer x,input integer y);begin
 color={x[7:0],y[7:0],(x[7:0]^y[7:0]^8'ha5)};
end endfunction
always @(negedge clk)begin
 cycle=cycle+1;blocked=(cycle%41<7);
 if(cycle%1000000==0)begin $display("PROGRESS frame=%0d cycle=%0d pixels=%0d state=%0d fifo=%0d source=%0d,%0d",frame,cycle,count,dut.state,dut.count,dut.sx,dut.sy);$fflush();end
end
always @(posedge clk)if(ov)begin
 ix=count%1280;iy=count/1280;
 expected=0;
 if(ix>=l && ix<l+fw && iy>=t && iy<t+fh)begin
  sx=(ix-l)*w/fw;sy=(iy-t)*h/fh;expected=color(sx,sy);
 end
 if(op!==expected)$fatal(1,"pixel frame=%0d pos=%0d,%0d expected=%h actual=%h fit=%0dx%0d",frame,ix,iy,expected,op,fw,fh);
 count=count+1;if(count>921600)$fatal(1,"too many pixels");
end
integer x,y;
task one(input integer wi,input integer he,input integer aspect,input integer sm);
begin
 w=wi;h=he;ah=aspect;zoom=sm;frame=frame+1;count=0;
 if(wi*720>=aspect*1280)begin fw=1280;fh=aspect*1280/wi;end
 else begin fw=wi*720/aspect;fh=720;end
 if(fw<1)fw=1;if(fh<1)fh=1;
 if(sm)begin fw=fw*3/4;fh=fh*3/4;if(fw<1)fw=1;if(fh<1)fh=1;end
 l=(1280-fw)/2;t=(720-fh)/2;
 @(negedge clk);start=1;@(negedge clk);start=0;zoom=~sm;
 for(y=0;y<he;y=y+1)for(x=0;x<wi;x=x+1)begin
  @(negedge clk);while(high || cycle%19==0)@(negedge clk);
  pixel=color(x,y);valid=1;@(negedge clk);valid=0;
 end
 wait(dut.state==13);repeat(5)@(negedge clk);
 if(count!=921600 || overflow)$fatal(1,"frame incomplete count=%0d",count);
 $display("PASS frame=%0d source=%0dx%0d aspect_h=%0d small=%0d fit=%0dx%0d",frame,wi,he,aspect,sm,fw,fh);
end endtask
initial begin repeat(5)@(negedge clk);rst=0;
 one(320,240,240,0);one(320,240,240,1);one(1280,720,720,1);
 one(1920,480,1080,1);one(1,1,1,1);one(7,19,19,1);one(4096,1,1,1);
 one(320,240,240,0);
 $display("PASS8 full720p zoom pixel frames, source-aspect, midframe mode latch, backpressure");$finish;
end
initial begin #2000000000;$fatal(1,"timeout");end
endmodule
