// QOA file streaming decoder, fixed 48 kHz mono/stereo profile.
// Algorithm/table based on qoa.h, Copyright (c) 2023 Dominic Szablewski, MIT.
// Retain the accompanying license in docs/licenses/QOA_MIT.txt.
// Prediction weights remain signed 32 bits between seeds (no 16-bit truncation).
// One time-shared signed 32x16 multiplier, four MAC cycles per sample.
module qoa_stream(
 input wire clk,rst,start,input wire[7:0]din,input wire din_valid,output wire din_ready,
 output wire sample_valid,input wire sample_ready,output wire[15:0]left,right,
 output reg done,error,ready,stereo,output reg[31:0]total_samples);
 localparam FILE_HDR=0,FRAME_HDR=1,CHECK_FRAME=2,LMS=3,SLICE=4,PREDICT=5,
  RECON=6,STORE=7,OUTPUT_PAIR=8,NEXT_GROUP=9,STOP=10,UPDATE=11,COUNT_SLICES=12,PRED_FETCH=13,UPDATE_FETCH=14,MAC_MULT=15,MAC_ADD=16,MAC_JOIN=17,UPDATE_READ=18,UPDATE_CALC=19;
 reg[4:0]state;reg[5:0]pos;reg[63:0]shift_reg,slice_bits;
 reg[31:0]magic,remaining;
 reg[7:0]frame_channels;
 reg[23:0]frame_rate;
 reg[15:0]frame_samples,frame_size,frame_count;
 reg[15:0]expected_frame_bytes;
 reg[8:0]num_slices;reg[15:0]slice_count_left;
 reg[4:0]slice_len,sample_idx,out_idx;
 reg channel;reg[1:0]tap;reg[3:0]scale;
 reg signed[15:0]history[0:7];
 (* ram_style="bram" *) reg signed[31:0]weights[0:7];
 reg signed[31:0]weight_q;
 reg signed[31:0]weight_mul_q,product_hi,weight_updated;reg signed[32:0]product_lo;
 reg signed[31:0]acc,mac_product;reg signed[15:0]history_q;
 reg signed[15:0]reconstructed;
 (* ram_style="bram" *) reg[15:0]left_buf[0:31],right_buf[0:31];
 reg[15:0]left_q,right_q;reg[1:0]output_delay;
 always @(posedge clk)begin
  left_q<=left_buf[out_idx];right_q<=right_buf[out_idx];
  if(state==STORE)begin if(channel)right_buf[sample_idx]<=reconstructed;else left_buf[sample_idx]<=reconstructed;end
 end
 always @(posedge clk or posedge rst)begin
  if(rst)output_delay<=2;
  else if(state!=OUTPUT_PAIR)output_delay<=2;
  else if(output_delay!=0)output_delay<=output_delay-1'b1;
  else if(sample_ready)output_delay<=2;
 end
 wire[2:0]addr={channel,tap};
 (* ram_style="bram" *) reg signed[15:0]dequant_rom[0:127];
 reg signed[15:0]residual;
 integer rom_init;
 initial begin for(rom_init=0;rom_init<128;rom_init=rom_init+1)dequant_rom[rom_init]=dequant(rom_init);end
 always @(posedge clk)residual<=dequant_rom[{scale,slice_bits[63:61]}];
 wire signed[31:0]prediction=acc>>>13;
 wire signed[32:0]recon_sum=$signed(prediction)+$signed(residual);
 wire signed[31:0]delta=$signed(residual)>>>4;
 wire weight_write=(state==LMS&&din_valid&&pos[0]&&pos[3])||state==UPDATE;
 wire[2:0]weight_addr=(state==LMS)?{channel,pos[2:1]}:addr;
 wire[31:0]weight_data=(state==LMS)?$signed({shift_reg[7:0],din}):weight_updated;
`ifdef __ICARUS__
 always @(posedge clk)begin
  weight_q<=weights[addr];
  if(weight_write)weights[weight_addr]<=weight_data;
 end
`else
 // Spare 32K RAMs hold the two halves, preserving scarce 9K RAM blocks.
 wire[31:0]weight_from_ram;
 always @(*)weight_q=weight_from_ram;
 genvar weight_half;
 generate for(weight_half=0;weight_half<2;weight_half=weight_half+1)begin:weight_ram
 EG_PHY_BRAM32K #(.MODE("DP16K"),.DATA_WIDTH_A("16"),.DATA_WIDTH_B("16"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG")) mem(
  .doa(),.dia(weight_data[weight_half*16+:16]),.addra({8'd0,weight_addr}),.bytea(1'b0),.bytewea(1'b0),
  .csa(1'b1),.wea(weight_write),.clka(clk),.rsta(1'b0),.ocea(1'b1),
  .dob(weight_from_ram[weight_half*16+:16]),.dib(16'd0),.addrb({8'd0,addr}),.byteb(1'b0),.byteweb(1'b0),
  .csb(1'b1),.web(1'b0),.clkb(clk),.rstb(1'b0),.oceb(1'b1));
 end endgenerate
`endif
 // Pipeline RAM output and split the low 32 bits of the signed product.
 // Keep exact C wraparound while avoiding RAM->DSP->carry chain in one cycle.
 wire signed[16:0]weight_lo=$signed({1'b0,weight_mul_q[15:0]});
 wire signed[15:0]weight_hi=$signed(weight_mul_q[31:16]);
 function signed[15:0]dequant;input[6:0]n;begin case(n)
7'd0:dequant=16'sd1;
7'd1:dequant=-16'sd1;
7'd2:dequant=16'sd3;
7'd3:dequant=-16'sd3;
7'd4:dequant=16'sd5;
7'd5:dequant=-16'sd5;
7'd6:dequant=16'sd7;
7'd7:dequant=-16'sd7;
7'd8:dequant=16'sd5;
7'd9:dequant=-16'sd5;
7'd10:dequant=16'sd18;
7'd11:dequant=-16'sd18;
7'd12:dequant=16'sd32;
7'd13:dequant=-16'sd32;
7'd14:dequant=16'sd49;
7'd15:dequant=-16'sd49;
7'd16:dequant=16'sd16;
7'd17:dequant=-16'sd16;
7'd18:dequant=16'sd53;
7'd19:dequant=-16'sd53;
7'd20:dequant=16'sd95;
7'd21:dequant=-16'sd95;
7'd22:dequant=16'sd147;
7'd23:dequant=-16'sd147;
7'd24:dequant=16'sd34;
7'd25:dequant=-16'sd34;
7'd26:dequant=16'sd113;
7'd27:dequant=-16'sd113;
7'd28:dequant=16'sd203;
7'd29:dequant=-16'sd203;
7'd30:dequant=16'sd315;
7'd31:dequant=-16'sd315;
7'd32:dequant=16'sd63;
7'd33:dequant=-16'sd63;
7'd34:dequant=16'sd210;
7'd35:dequant=-16'sd210;
7'd36:dequant=16'sd378;
7'd37:dequant=-16'sd378;
7'd38:dequant=16'sd588;
7'd39:dequant=-16'sd588;
7'd40:dequant=16'sd104;
7'd41:dequant=-16'sd104;
7'd42:dequant=16'sd345;
7'd43:dequant=-16'sd345;
7'd44:dequant=16'sd621;
7'd45:dequant=-16'sd621;
7'd46:dequant=16'sd966;
7'd47:dequant=-16'sd966;
7'd48:dequant=16'sd158;
7'd49:dequant=-16'sd158;
7'd50:dequant=16'sd528;
7'd51:dequant=-16'sd528;
7'd52:dequant=16'sd950;
7'd53:dequant=-16'sd950;
7'd54:dequant=16'sd1477;
7'd55:dequant=-16'sd1477;
7'd56:dequant=16'sd228;
7'd57:dequant=-16'sd228;
7'd58:dequant=16'sd760;
7'd59:dequant=-16'sd760;
7'd60:dequant=16'sd1368;
7'd61:dequant=-16'sd1368;
7'd62:dequant=16'sd2128;
7'd63:dequant=-16'sd2128;
7'd64:dequant=16'sd316;
7'd65:dequant=-16'sd316;
7'd66:dequant=16'sd1053;
7'd67:dequant=-16'sd1053;
7'd68:dequant=16'sd1895;
7'd69:dequant=-16'sd1895;
7'd70:dequant=16'sd2947;
7'd71:dequant=-16'sd2947;
7'd72:dequant=16'sd422;
7'd73:dequant=-16'sd422;
7'd74:dequant=16'sd1405;
7'd75:dequant=-16'sd1405;
7'd76:dequant=16'sd2529;
7'd77:dequant=-16'sd2529;
7'd78:dequant=16'sd3934;
7'd79:dequant=-16'sd3934;
7'd80:dequant=16'sd548;
7'd81:dequant=-16'sd548;
7'd82:dequant=16'sd1828;
7'd83:dequant=-16'sd1828;
7'd84:dequant=16'sd3290;
7'd85:dequant=-16'sd3290;
7'd86:dequant=16'sd5117;
7'd87:dequant=-16'sd5117;
7'd88:dequant=16'sd696;
7'd89:dequant=-16'sd696;
7'd90:dequant=16'sd2320;
7'd91:dequant=-16'sd2320;
7'd92:dequant=16'sd4176;
7'd93:dequant=-16'sd4176;
7'd94:dequant=16'sd6496;
7'd95:dequant=-16'sd6496;
7'd96:dequant=16'sd868;
7'd97:dequant=-16'sd868;
7'd98:dequant=16'sd2893;
7'd99:dequant=-16'sd2893;
7'd100:dequant=16'sd5207;
7'd101:dequant=-16'sd5207;
7'd102:dequant=16'sd8099;
7'd103:dequant=-16'sd8099;
7'd104:dequant=16'sd1064;
7'd105:dequant=-16'sd1064;
7'd106:dequant=16'sd3548;
7'd107:dequant=-16'sd3548;
7'd108:dequant=16'sd6386;
7'd109:dequant=-16'sd6386;
7'd110:dequant=16'sd9933;
7'd111:dequant=-16'sd9933;
7'd112:dequant=16'sd1286;
7'd113:dequant=-16'sd1286;
7'd114:dequant=16'sd4288;
7'd115:dequant=-16'sd4288;
7'd116:dequant=16'sd7718;
7'd117:dequant=-16'sd7718;
7'd118:dequant=16'sd12005;
7'd119:dequant=-16'sd12005;
7'd120:dequant=16'sd1536;
7'd121:dequant=-16'sd1536;
7'd122:dequant=16'sd5120;
7'd123:dequant=-16'sd5120;
7'd124:dequant=16'sd9216;
7'd125:dequant=-16'sd9216;
7'd126:dequant=16'sd14336;
7'd127:dequant=-16'sd14336;
default:dequant=0;endcase end endfunction
 assign din_ready=(state==FILE_HDR||state==FRAME_HDR||state==LMS||state==SLICE);
 assign sample_valid=(state==OUTPUT_PAIR)&&output_delay==0;
 assign left=left_q;
 assign right=stereo?right_q:left_q;
 integer i;
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=STOP;pos<=0;shift_reg<=0;slice_bits<=0;magic<=0;remaining<=0;
   frame_channels<=0;frame_rate<=0;frame_samples<=0;frame_size<=0;frame_count<=0;num_slices<=0;slice_count_left<=0;expected_frame_bytes<=0;
   slice_len<=0;sample_idx<=0;out_idx<=0;channel<=0;tap<=0;scale<=0;acc<=0;mac_product<=0;weight_updated<=0;weight_mul_q<=0;product_lo<=0;product_hi<=0;history_q<=0;reconstructed<=0;
   done<=0;error<=0;ready<=0;stereo<=0;total_samples<=0;
  end else if(start)begin state<=FILE_HDR;pos<=0;magic<=0;total_samples<=0;remaining<=0;
   done<=0;error<=0;ready<=0;stereo<=0;frame_count<=0;
  end else begin
   case(state)
    FILE_HDR:if(din_valid)begin
     pos<=pos+1'b1;
     if(pos<4)magic<={magic[23:0],din};else total_samples<={total_samples[23:0],din};
     if(pos==7)begin
      if(magic!=32'h716f6166 || {total_samples[23:0],din}==0 || {total_samples[23:0],din}>32'h03ffffff)begin error<=1;state<=STOP;end
      else begin remaining<={total_samples[23:0],din};pos<=0;state<=FRAME_HDR;end
     end
    end
    FRAME_HDR:if(din_valid)begin
     pos<=pos+1'b1;
     case(pos)
      0:frame_channels<=din;
      1,2,3:frame_rate<={frame_rate[15:0],din};
      4,5:frame_samples<={frame_samples[7:0],din};
      6,7:frame_size<={frame_size[7:0],din};
     endcase
     if(pos==7)begin state<=CHECK_FRAME;pos<=0;end
    end
    CHECK_FRAME:begin
     // Fixed byte count is checked without division or an unbounded parser.
     if(pos==0)begin num_slices<=0;slice_count_left<=frame_samples+16'd19;state<=COUNT_SLICES;end
     else if(pos==1)begin expected_frame_bytes<=16'd8+(frame_channels==2?16'd32:16'd16)+
                              (frame_channels==2?{num_slices,4'd0}:{1'b0,num_slices,3'd0});pos<=2;end
     else if((frame_channels!=1&&frame_channels!=2)||frame_rate!=48000||frame_samples==0||
       frame_samples>5120||frame_samples>remaining||frame_size!=expected_frame_bytes||
       (ready&&stereo!=(frame_channels==2)))begin error<=1;state<=STOP;end
     else begin stereo<=(frame_channels==2);ready<=1;pos<=0;channel<=0;state<=LMS;frame_count<=0;end
    end
    COUNT_SLICES:begin
     if(slice_count_left>=20)begin slice_count_left<=slice_count_left-16'd20;num_slices<=num_slices+1'b1;end
     else begin pos<=1;state<=CHECK_FRAME;end
    end
    LMS:if(din_valid)begin
     shift_reg<={shift_reg[55:0],din};pos<=pos+1'b1;
     if(pos[0])begin
      if(!pos[3])history[{channel,pos[2:1]}]<={shift_reg[7:0],din};

     end
     if(pos==15)begin
      pos<=0;
      if(stereo&&!channel)channel<=1;
      else begin channel<=0;state<=SLICE;sample_idx<=0;slice_len<=((frame_samples-frame_count)<20)?(frame_samples-frame_count):20;end
     end
    end
    SLICE:if(din_valid)begin
     shift_reg<={shift_reg[55:0],din};pos<=pos+1'b1;
     if(pos==7)begin
      scale<=shift_reg[55:52];slice_bits<={shift_reg[51:0],din,4'd0};
      state<=PRED_FETCH;tap<=0;acc<=0;sample_idx<=0;pos<=0;
     end
    end
    PRED_FETCH:state<=PREDICT;
    PREDICT:begin history_q<=history[addr];weight_mul_q<=weight_q;state<=MAC_MULT;end
    MAC_MULT:begin product_lo<=weight_lo*history_q;product_hi<=weight_hi*history_q;state<=MAC_JOIN;end
    MAC_JOIN:begin mac_product<=product_lo[31:0]+{product_hi[15:0],16'd0};state<=MAC_ADD;end
    MAC_ADD:begin
     acc<=acc+mac_product;
     if(tap==3)state<=RECON;else begin tap<=tap+1'b1;state<=PRED_FETCH;end
    end
    RECON:begin
     if(recon_sum>32767)reconstructed<=16'sh7fff;
     else if(recon_sum< -32768)reconstructed<=16'sh8000;
     else reconstructed<=recon_sum[15:0];
     state<=UPDATE_FETCH;tap<=0;
    end
    UPDATE_FETCH:state<=UPDATE_READ;
    UPDATE_READ:begin weight_mul_q<=weight_q;history_q<=history[addr];state<=UPDATE_CALC;end
    UPDATE_CALC:begin weight_updated<=history_q<0?weight_mul_q-delta:weight_mul_q+delta;state<=UPDATE;end
    UPDATE:begin
     if(tap==3)state<=STORE;else begin tap<=tap+1'b1;state<=UPDATE_FETCH;end
    end
    STORE:begin
     history[{channel,2'd0}]<=history[{channel,2'd1}];history[{channel,2'd1}]<=history[{channel,2'd2}];
     history[{channel,2'd2}]<=history[{channel,2'd3}];history[{channel,2'd3}]<=reconstructed;

     slice_bits<=slice_bits<<3;
     if(sample_idx+1==slice_len)begin
      if(stereo&&!channel)begin channel<=1;state<=SLICE;pos<=0;end
      else begin state<=OUTPUT_PAIR;out_idx<=0;end
     end else begin sample_idx<=sample_idx+1'b1;state<=PRED_FETCH;acc<=0;tap<=0;end
    end
    OUTPUT_PAIR:if(sample_ready&&output_delay==0)begin
     remaining<=remaining-1'b1;
     if(out_idx+1==slice_len)begin frame_count<=frame_count+slice_len;state<=NEXT_GROUP;end
     else out_idx<=out_idx+1'b1;
    end
    NEXT_GROUP:begin
     if(remaining==0)begin done<=1;state<=STOP;end
     else if(frame_count==frame_samples)begin state<=FRAME_HDR;pos<=0;end
     else begin slice_len<=((frame_samples-frame_count)<20)?(frame_samples-frame_count):20;channel<=0;state<=SLICE;pos<=0;end
    end
   endcase
  end
 end
endmodule

