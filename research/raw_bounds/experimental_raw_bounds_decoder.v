`timescale 1ns/1ps
// Isolated research prototype, 2026-10-27. NOT production codec RTL.
// One packet per start: 0x83 RAW or proposed 0x86 quadrant bounds.
// Buffers one 8x8 block, then emits row-major RGB565 with backpressure.
// Input length/framing is the caller's responsibility; cancel resets state.
module experimental_raw_bounds_decoder(
 input wire clk,rst,start,cancel,pause,
 input wire[7:0]din,input wire din_valid,output wire din_ready,
 output wire[15:0]pixel,output wire pixel_valid,input wire pixel_ready,
 output reg done,fault);
 localparam IDLE=0,OP=1,FLAGS=2,LO=3,HI=4,BASE_LO=5,BASE_HI=6,
  WIDTH_LO=7,WIDTH_HI=8,RESIDUAL=9,EMIT_WAIT=10,EMIT=11,STOP=12;
 reg[3:0]state;reg[7:0]flags,lo,meta_lo;reg[1:0]quad,channel;
 reg[3:0]qpos;reg[5:0]rawpos,outpos;reg global_raw;
 reg[4:0]rbase,bbase,rval;reg[5:0]gbase,gval;
 reg[2:0]rw,gw,bw;reg[23:0]reservoir;reg[5:0]nbits;
 reg[15:0]block_mem[0:63];reg[15:0]pixel_q;
 wire[2:0]width=(channel==0)?rw:(channel==1)?gw:bw;
 wire need_byte=state==RESIDUAL && nbits<width;
 wire[5:0]mask=(6'd1<<width)-1'b1;
 wire[6:0]value=((channel==0)?{2'd0,rbase}:(channel==1)?{1'd0,gbase}:{2'd0,bbase})+(reservoir[5:0]&mask);
 wire[5:0]write_pos=global_raw?rawpos:{quad[1],qpos[3:2],quad[0],qpos[1:0]};
 assign din_ready=!pause&&(state==OP||state==FLAGS||state==LO||state==HI||
  state==BASE_LO||state==BASE_HI||state==WIDTH_LO||state==WIDTH_HI||need_byte);
 assign pixel=pixel_q;assign pixel_valid=!pause&&state==EMIT;
 always@(posedge clk)pixel_q<=block_mem[outpos];
 task reject;begin fault<=1;state<=STOP;end endtask
 task quadrant_done;begin
  qpos<=0;reservoir<=0;nbits<=0;
  if(quad==3)begin outpos<=0;state<=EMIT_WAIT;end
  else begin
   quad<=quad+1'b1;
   case((flags>>(2*(quad+1)))&3)
    0:state<=LO;1:state<=BASE_LO;default:reject;
   endcase
  end
 end endtask
 always@(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;done<=0;fault<=0;quad<=0;qpos<=0;rawpos<=0;outpos<=0;
   channel<=0;flags<=0;lo<=0;meta_lo<=0;global_raw<=0;rw<=0;gw<=0;bw<=0;
   rbase<=0;gbase<=0;bbase<=0;rval<=0;gval<=0;reservoir<=0;nbits<=0;end
  else begin
   done<=0;
   if(cancel)begin state<=IDLE;fault<=0;end
   else if(start)begin state<=OP;fault<=0;quad<=0;qpos<=0;rawpos<=0;outpos<=0;reservoir<=0;nbits<=0;channel<=0;end
   else if(!pause)case(state)
    OP:if(din_valid)begin
     if(din==8'h83)begin global_raw<=1;state<=LO;end
     else if(din==8'h86)begin global_raw<=0;state<=FLAGS;end
     else reject;
    end
    FLAGS:if(din_valid)begin flags<=din;
     case(din[1:0])0:state<=LO;1:state<=BASE_LO;default:reject;endcase
    end
    LO:if(din_valid)begin lo<=din;state<=HI;end
    HI:if(din_valid)begin
     block_mem[write_pos]<={din,lo};
     if(global_raw)begin
      if(rawpos==63)begin outpos<=0;state<=EMIT_WAIT;end
      else begin rawpos<=rawpos+1'b1;state<=LO;end
     end else if(qpos==15)quadrant_done;
     else begin qpos<=qpos+1'b1;state<=LO;end
    end
    BASE_LO:if(din_valid)begin lo<=din;state<=BASE_HI;end
    BASE_HI:if(din_valid)begin rbase<=din[7:3];gbase<={din[2:0],lo[7:5]};bbase<=lo[4:0];state<=WIDTH_LO;end
    WIDTH_LO:if(din_valid)begin meta_lo<=din;state<=WIDTH_HI;end
    WIDTH_HI:if(din_valid)begin
     if(din[7:1]!=0||meta_lo[2:0]>5||meta_lo[5:3]>6||{din[0],meta_lo[7:6]}>5)reject;
     else begin rw<=meta_lo[2:0];gw<=meta_lo[5:3];bw<={din[0],meta_lo[7:6]};channel<=0;reservoir<=0;nbits<=0;state<=RESIDUAL;end
    end
    RESIDUAL:begin
     if(need_byte)begin if(din_valid)begin reservoir<=reservoir|({16'd0,din}<<nbits);nbits<=nbits+8;end end
     else if(value>((channel==1)?63:31))reject;
     else begin
      reservoir<=reservoir>>width;nbits<=nbits-width;
      if(channel==0)begin rval<=value[4:0];channel<=1;end
      else if(channel==1)begin gval<=value[5:0];channel<=2;end
      else begin
       block_mem[write_pos]<={rval,gval,value[4:0]};channel<=0;
       if(qpos==15)quadrant_done;else qpos<=qpos+1'b1;
      end
     end
    end
    EMIT_WAIT:state<=EMIT;
    EMIT:if(pixel_ready)begin
     if(outpos==63)begin done<=1;state<=STOP;end
     else begin outpos<=outpos+1'b1;state<=EMIT_WAIT;end
    end
    default:begin end
   endcase
  end
 end
endmodule
