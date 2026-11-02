`timescale 1ns/1ps
module tb;
reg clk=0;always #5.5 clk=~clk;
reg rst=1,fin=0;wire req,wreq,wen,shown,loading;wire[31:0]addr,wd;wire[15:0]ih;
reg[7:0]data=0;reg valid=0,ended=0,grant=0;wire[3:0]st;
reg ack=0;integer cycle=0;wire blocked=(cycle%97<21);
sd_card_bmp #(.CLK_FREQ_HZ(90909091)) dut(.clk(clk),.rst(rst),
 .directory_count(3'd1),.directory0(32'd100),.directory1(32'd0),.directory2(32'd0),.directory3(32'd0),
 .key_next(1'b1),.key_auto(1'b1),.bmp_width(16'd640),.bmp_height(16'd480),
 .period_code(4'd0),.auto_period_sec(10'd600),.period_reseed(1'b0),
 .display_valid(shown),.img_loading(loading),.scan_start_sector(32'd100),.scan_start_sector2(32'd0),
 .scan_start2(1'b0),.scan_limited(1'b1),.write_finish_toggle(fin),
 .switch_lock(1'b0),.vid_lock(1'b0),.fade_done_pulse(1'b0),
 .write_req(wreq),.write_req_ack(ack),.write_almost_full(blocked),
 .write_en(wen),.write_data(wd),.img_h_o(ih),.sd_init_done(!rst),.sd_error(1'b0),
 .sd_sec_read(req),.sd_sec_read_addr(addr),.sd_sec_read_data(data),.sd_sec_read_data_valid(valid),
 .sd_sec_read_end(ended),.sd_grant(grant),.state_code(st));
reg[7:0]hdr[0:511];integer w,h,kind,stride,bytes,sh,step,fw,fh,left,top,off,b,txns=0,n=0,x,y,sx,sy,delay_finish=0;
reg[23:0]expected;reg request_seen=0;
function[23:0]colour(input integer x,input integer y);begin colour=((x*73)^(y*101)^(x<<12)^(y<<4))&24'hffffff;end endfunction
function[7:0]value(input integer offset);
 integer pos,ix,iy,ch;reg[23:0]v;
 begin
 value=0;
 if(kind==0)begin
  if(offset<54)value=hdr[offset];
  else begin pos=offset-54;iy=pos/stride;ix=(pos%stride)/3;ch=(pos%stride)%3;
   v=colour(ix,iy);if(ix<w&&iy<h)case(ch)0:value=v[7:0];1:value=v[15:8];2:value=v[23:16];endcase
  end
 end else begin
  if(offset<14)value=hdr[offset];
  else if(offset<14+w*h*4)begin pos=(offset-14)/4;ch=(offset-14)%4;v=colour(pos%w,pos/w);
   case(ch)0:value=8'hfe;1:value=v[23:16];2:value=v[15:8];3:value=v[7:0];endcase
  end else if(offset==14+w*h*4+7)value=1;
 end
 end
endfunction
initial begin
 if(!$value$plusargs("W=%d",w)||!$value$plusargs("H=%d",h)||!$value$plusargs("KIND=%d",kind))$fatal(1,"args");
 $readmemh("header.hex",hdr);
 stride=((w*3+3)/4)*4;
 step=kind==0&&w%4==0&&w>=640&&(h==960||h==1440||h==1920)?h/480:1;sh=h/step;
 if(w*720>=h*1280)begin fw=1280;fh=h*1280/w;if(fh<1)fh=1;end
 else begin fh=720;fw=w*720/h;if(fw<1)fw=1;end
 left=(1280-fw)/2;top=(720-fh)/2;
 repeat(8)@(negedge clk);#1;rst=0;
 forever begin
  @(negedge clk);
  if(req)begin
   txns=txns+1;grant=1;off=(addr-100)*512;
   if(off<0)$fatal(1,"wrong sector");
   repeat(10)@(negedge clk);
   for(b=0;b<512;b=b+1)begin
    data=value(off+b);valid=1;@(negedge clk);valid=0;
    repeat(3)@(negedge clk);
   end
   ended=1;@(negedge clk);ended=0;grant=0;
   repeat(20)@(negedge clk);
  end
 end
end
always@(negedge clk)if(!rst)begin
 cycle=cycle+1;ack=0;
 if(!wreq)request_seen=0;
 if(wreq&&!request_seen)begin ack=1;request_seen=1;end
 if(wen)begin
  x=n%1280;y=n/1280;expected=0;
  if(x>=left&&x<left+fw&&y>=top&&y<top+fh)begin
   sx=(x-left)*w/fw;sy=((y-top)*sh/fh)*step;expected=colour(sx,sy);
  end
  if(n>=921600||wd!=={expected,8'd0})$fatal(1,"PIXEL n=%d got=%h expected=%h source=%d,%d",n,wd,{expected,8'd0},sx,sy);
  n=n+1;if(n==921600)delay_finish=30;
 end
 if(delay_finish>1)delay_finish=delay_finish-1;
 else if(delay_finish==1)begin delay_finish=0;fin=~fin;end
 if(shown)begin
  if(n!=921600||ih!=720)$fatal(1,"early display commit");
  $display("PASS IMAGE CHAIN kind=%d %dx%d fit=%dx%d pixels=%d sectors=%d faststep=%d",kind,w,h,fw,fh,n,txns,step);$finish;
 end
 if(cycle>45000000)$fatal(1,"timeout n=%d state=%d image_error=%b fitstate=%d",n,st,dut.image_load_error,dut.u_image_fit.state);
end
endmodule
