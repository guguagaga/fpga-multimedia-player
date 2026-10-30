`timescale 1ns/1ps
module tb;
  reg clk=0; always #5 clk=~clk;
  reg rst=1, frame_start=0, iv=0, blocked=0;
  reg [15:0] sw,sh,ah;
  reg [23:0] ip=0;
  wire hi0,hi1,ov0,ov1,v0,v1;
  wire [23:0] p0,p1;
  image_fit_reference ref0(.clk(clk),.rst(rst),.frame_start(frame_start),
    .src_w(sw),.src_h(sh),.aspect_h(ah),.in_valid(iv),.in_pixel(ip),
    .high(hi0),.overflow(ov0),.out_blocked(blocked),.out_valid(v0),.out_pixel(p0));
  image_fit_720p dut(.clk(clk),.rst(rst),.frame_start(frame_start),
    .src_w(sw),.src_h(sh),.aspect_h(ah),.in_valid(iv),.in_pixel(ip),
    .high(hi1),.overflow(ov1),.out_blocked(blocked),.out_valid(v1),.out_pixel(p1));
  integer w,h,a,fw,fh,left,top,n0=0,n1=0,sent=0,c=0,abort_at=0,restarts=0;
  integer done0=0,done1=0;
  reg [23:0] expected;
  function [23:0] color(input integer x,input integer y);
    color=((x*73)^(y*101)^(x<<12)^(y<<4))&24'hffffff;
  endfunction
  function [23:0] pixel(input integer n);
    integer x,y,sx,sy;
    begin
      x=n%1280;y=n/1280;pixel=0;
      if(x>=left && x<left+fw && y>=top && y<top+fh)begin
        sx=(x-left)*w/fw;sy=(y-top)*h/fh;
        pixel=color(sx,sy);
      end
    end
  endfunction
  initial begin
    if(!$value$plusargs("W=%d",w)||!$value$plusargs("H=%d",h)||!$value$plusargs("A=%d",a))$fatal(1,"args");
    if($value$plusargs("ABORT=%d",abort_at))begin end
    sw=w;sh=h;ah=a;
    if(w*720>=a*1280)begin fw=1280;fh=a*1280/w;if(fh<1)fh=1;end
    else begin fh=720;fw=w*720/a;if(fw<1)fw=1;end
    left=(1280-fw)/2;top=(720-fh)/2;
    repeat(4)@(negedge clk);rst=0;
    while(c<30000000)begin
      @(negedge clk);
      blocked=(c%97<21)||(c%100003<201);
      iv=sent<w*h&&!hi0&&!hi1&&(c%11!=0);
      ip=color(sent%w,sent/w);
      frame_start=0;
      if(abort_at>0&&c==abort_at)begin
        frame_start=1;iv=0;sent=0;n0=0;n1=0;done0=0;done1=0;restarts=restarts+1;
      end
      @(posedge clk);#1;
      if(iv)sent=sent+1;
      if(ov0||ov1)$fatal(1,"overflow");
      if(v0)begin
        expected=pixel(n0);
        if(n0>=921600||p0!==expected)$fatal(1,"reference pixel %d got=%h want=%h",n0,p0,expected);
        n0=n0+1;
      end
      if(v1)begin
        expected=pixel(n1);
        if(n1>=921600||p1!==expected)$fatal(1,"candidate pixel %d got=%h want=%h",n1,p1,expected);
        n1=n1+1;
      end
      if(ref0.state==13&&done0==0)done0=c;
      if(dut.state==13&&done1==0)done1=c;
      if(done0>0&&done1>0)begin
        if(n0!=921600||n1!=921600||sent!=w*h)$fatal(1,"incomplete frame");
        if(abort_at>0&&restarts!=1)$fatal(1,"restart not tested");
        $display("PASS %dx%d aspect=%d reference=%d candidate=%d cycles=%d/%d restart=%d",w,h,a,n0,n1,done0,done1,restarts);
        $finish;
      end
      c=c+1;
    end
    $fatal(1,"timeout counts=%d/%d sent=%d states=%d/%d",n0,n1,sent,ref0.state,dut.state);
  end
endmodule
