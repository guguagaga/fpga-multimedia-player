// Isolated Codec11 feasibility prototype, NOT integrated into the player.
// Exact RGB565 bilinear formula with weights (8-x),(8-y), rounding +32 /64.
// Horizontal/vertical forward differences use adds/shifts; no DSP multiply.
module gradient_block_experimental(
 input wire clk,rst,start,pause,
 input wire[15:0]c00,c10,c01,c11,
 output reg busy,pix_valid,done,output wire[15:0]pixel);
 reg setup;reg[2:0]x,y;
 wire emit=busy&&!setup&&!pause;
 wire row_step=emit&&x==7;
 genvar ch;
 generate for(ch=0;ch<3;ch=ch+1)begin:channel
  localparam BITS=(ch==1)?6:5;
  localparam LOW=(ch==0)?11:(ch==1)?5:0;
  wire[BITS-1:0]a=c00[LOW+:BITS],b=c10[LOW+:BITS],c=c01[LOW+:BITS],d=c11[LOW+:BITS];
  reg[BITS+2:0]left_row,right_row;
  reg signed[BITS:0]dy_left,dy_right;
  reg signed[BITS+3:0]dx;
  reg signed[BITS+6:0]acc;
  reg[BITS-1:0]value;
  assign pixel[LOW+:BITS]=value;
  always@(posedge clk)begin
   if(start&&!busy)begin
    left_row<={a,3'b0};right_row<={b,3'b0};
    dy_left<=$signed({1'b0,c})-$signed({1'b0,a});
    dy_right<=$signed({1'b0,d})-$signed({1'b0,b});
   end else if(busy&&!pause)begin
    if(setup)begin
     acc<={1'b0,left_row,3'b0}+32;
     dx<=$signed({1'b0,right_row})-$signed({1'b0,left_row});
    end else begin
     value<=acc[BITS+5:6];acc<=acc+dx;
     if(row_step)begin
      left_row<=$signed({1'b0,left_row})+dy_left;
      right_row<=$signed({1'b0,right_row})+dy_right;
     end
    end
   end
  end
 end endgenerate
 always@(posedge clk or posedge rst)begin
  if(rst)begin busy<=0;setup<=0;x<=0;y<=0;pix_valid<=0;done<=0;end
  else begin
   pix_valid<=0;done<=0;
   if(start&&!busy)begin busy<=1;setup<=1;x<=0;y<=0;end
   else if(busy&&!pause)begin
    if(setup)setup<=0;
    else begin
     pix_valid<=1;
     if(x==7)begin x<=0;setup<=1;y<=y+1'b1;if(y==7)begin busy<=0;done<=1;end end
     else x<=x+1'b1;
    end
   end
  end
 end
endmodule
