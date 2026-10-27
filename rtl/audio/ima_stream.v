// IMA ADPCM WAV block decoder. ADPCM-XQ is an offline encoder for this
// standard format; its lookahead/noise shaping requires no extra RTL decoder.
// 48 kHz mono/stereo, power-of-two blockAlign 64..4096, fact sample trim.
module ima_stream(
 input wire clk,rst,start,input wire[7:0]din,input wire din_valid,output wire din_ready,
 output wire sample_valid,input wire sample_ready,output wire[15:0]left,right,
 output reg done,error,ready,stereo,output reg[31:0]total_samples,
 output wire pcm_mode,output reg[31:0]data_offset,
 input wire pcm_seek,input wire[31:0]pcm_seek_byte);
 localparam RIFF=0,TAG=1,LENGTH=2,PAYLOAD=3,CHECK=4,BLOCK_HDR=5,BLOCK_CHECK=6,
  GET_BYTE=7,DECODE=8,OUTPUT_PAIR=9,AFTER_OUTPUT=10,STOP=11,LOOKUP=12,CHECK_PRE=13,STEP_PARTS=14,DIFF_SUM=15,RECON_SUM=16;
 reg[4:0]state;reg[16:0]pos;reg[4:0]payload_pos;reg[31:0]tag,chunk_len,data_bytes;reg[16:0]payload_left;reg[27:0]data_left;reg[25:0]remaining;
 reg[1:0]field;reg fmt_seen,fact_seen;
 reg[15:0]format,channels,bits;reg[12:0]align,samples_per_block;
 reg[31:0]rate;reg[2:0]hdr_pos;
 reg[12:0]block_pos;reg channel,nibble_hi;
 reg[7:0]packed_byte;reg[3:0]group_pos,out_pos;
 reg signed[15:0]predictor[0:1];reg[6:0]step_index[0:1];
 (* ram_style="bram" *) reg[15:0]left_buf[0:7],right_buf[0:7];
 reg[15:0]left_q,right_q;reg[1:0]output_delay;
 reg[7:0]pcm_low;
 wire[3:0]code=nibble_hi?packed_byte[7:4]:packed_byte[3:0];
 (* ram_style="bram" *)reg[15:0]step_rom[0:127];reg[15:0]step;
 integer step_init;
 initial begin for(step_init=0;step_init<128;step_init=step_init+1)step_rom[step_init]=step_lut(step_init);end
 always @(posedge clk)step<=step_rom[step_index[channel]];
 reg[16:0]diff_a,diff_b,diff;
 reg signed[17:0]sum;
 wire signed[15:0]decoded=(sum>32767)?16'sh7fff:(sum< -32768)?16'sh8000:sum[15:0];
 wire signed[8:0]next_index=$signed({2'b0,step_index[channel]})+
  (code[2]? (9'sd2+($signed({7'd0,code[1:0]})<<<1)) : -9'sd1);

 // Chunk tags have four LENGTH bytes plus CHECK_PRE to settle after TAG.
 // Format settles during fmt payload before a later data chunk. Registered
 // classification cuts the 16/32-bit comparisons out of output pointer CEs.
 reg is_pcm,is_stereo,is_mono,tag_data,tag_fmt,tag_fact;
 reg chunk_empty,fmt_chunk_valid;
 always @(posedge clk)begin
  is_pcm<=format==1;
  is_stereo<=channels==2;is_mono<=channels==1;
  chunk_empty<=chunk_len==0;
  fmt_chunk_valid<=chunk_len>=16&&(format==1||chunk_len>=20);
  tag_data<=tag==32'h61746164;
  tag_fmt<=tag==32'h20746d66;
  tag_fact<=tag==32'h74636166;
 end
 reg first_pair;reg[3:0]output_len;assign pcm_mode=(is_pcm);
 always @(posedge clk)begin
  left_q<=left_buf[out_pos[2:0]];right_q<=right_buf[out_pos[2:0]];
  if(state==BLOCK_CHECK)begin left_buf[0]<=predictor[0];right_buf[0]<=predictor[1];end
  else if(state==DECODE)begin if(channel)right_buf[group_pos[2:0]]<=decoded;else left_buf[group_pos[2:0]]<=decoded;end
  else if(state==GET_BYTE&&is_pcm&&din_valid&&data_left!=0)begin
   if(group_pos==1)left_buf[0]<={din,pcm_low};
   if(group_pos==3)right_buf[0]<={din,pcm_low};
  end
  if(state==GET_BYTE&&is_pcm&&din_valid&&!group_pos[0])pcm_low<=din;
 end
 always @(posedge clk or posedge rst)begin
  if(rst)output_delay<=2;
  else if(state!=OUTPUT_PAIR)output_delay<=2;
  else if(output_delay!=0)output_delay<=output_delay-1'b1;
  else if(sample_ready)output_delay<=2;
 end
 function[15:0]step_lut;input[6:0]n;begin case(n)
7'd0:step_lut=16'd7;
7'd1:step_lut=16'd8;
7'd2:step_lut=16'd9;
7'd3:step_lut=16'd10;
7'd4:step_lut=16'd11;
7'd5:step_lut=16'd12;
7'd6:step_lut=16'd13;
7'd7:step_lut=16'd14;
7'd8:step_lut=16'd16;
7'd9:step_lut=16'd17;
7'd10:step_lut=16'd19;
7'd11:step_lut=16'd21;
7'd12:step_lut=16'd23;
7'd13:step_lut=16'd25;
7'd14:step_lut=16'd28;
7'd15:step_lut=16'd31;
7'd16:step_lut=16'd34;
7'd17:step_lut=16'd37;
7'd18:step_lut=16'd41;
7'd19:step_lut=16'd45;
7'd20:step_lut=16'd50;
7'd21:step_lut=16'd55;
7'd22:step_lut=16'd60;
7'd23:step_lut=16'd66;
7'd24:step_lut=16'd73;
7'd25:step_lut=16'd80;
7'd26:step_lut=16'd88;
7'd27:step_lut=16'd97;
7'd28:step_lut=16'd107;
7'd29:step_lut=16'd118;
7'd30:step_lut=16'd130;
7'd31:step_lut=16'd143;
7'd32:step_lut=16'd157;
7'd33:step_lut=16'd173;
7'd34:step_lut=16'd190;
7'd35:step_lut=16'd209;
7'd36:step_lut=16'd230;
7'd37:step_lut=16'd253;
7'd38:step_lut=16'd279;
7'd39:step_lut=16'd307;
7'd40:step_lut=16'd337;
7'd41:step_lut=16'd371;
7'd42:step_lut=16'd408;
7'd43:step_lut=16'd449;
7'd44:step_lut=16'd494;
7'd45:step_lut=16'd544;
7'd46:step_lut=16'd598;
7'd47:step_lut=16'd658;
7'd48:step_lut=16'd724;
7'd49:step_lut=16'd796;
7'd50:step_lut=16'd876;
7'd51:step_lut=16'd963;
7'd52:step_lut=16'd1060;
7'd53:step_lut=16'd1166;
7'd54:step_lut=16'd1282;
7'd55:step_lut=16'd1411;
7'd56:step_lut=16'd1552;
7'd57:step_lut=16'd1707;
7'd58:step_lut=16'd1878;
7'd59:step_lut=16'd2066;
7'd60:step_lut=16'd2272;
7'd61:step_lut=16'd2499;
7'd62:step_lut=16'd2749;
7'd63:step_lut=16'd3024;
7'd64:step_lut=16'd3327;
7'd65:step_lut=16'd3660;
7'd66:step_lut=16'd4026;
7'd67:step_lut=16'd4428;
7'd68:step_lut=16'd4871;
7'd69:step_lut=16'd5358;
7'd70:step_lut=16'd5894;
7'd71:step_lut=16'd6484;
7'd72:step_lut=16'd7132;
7'd73:step_lut=16'd7845;
7'd74:step_lut=16'd8630;
7'd75:step_lut=16'd9493;
7'd76:step_lut=16'd10442;
7'd77:step_lut=16'd11487;
7'd78:step_lut=16'd12635;
7'd79:step_lut=16'd13899;
7'd80:step_lut=16'd15289;
7'd81:step_lut=16'd16818;
7'd82:step_lut=16'd18500;
7'd83:step_lut=16'd20350;
7'd84:step_lut=16'd22385;
7'd85:step_lut=16'd24623;
7'd86:step_lut=16'd27086;
7'd87:step_lut=16'd29794;
7'd88:step_lut=16'd32767;
default:step_lut=16'd32767;endcase end endfunction
 // Parsed format fields settle long before data; chunk length needs one
 // explicit pipeline cycle after LENGTH before any decision consumes it.
 reg pcm_fields_ok,ima_fields_ok,ima_layout_ok,chunk_ok;
 reg pcm_data_ok,ima_data_ok;
 reg[12:0]expected_spb;
 always @(posedge clk)begin
  expected_spb<=1+((align-(is_stereo?13'd8:13'd4))<<(is_stereo?0:1));
  pcm_fields_ok<=fmt_seen&&rate==48000&&bits==16&&((is_mono&&align==2)||(is_stereo&&align==4));
  ima_fields_ok<=fmt_seen&&fact_seen&&format==17&&rate==48000&&bits==4&&(is_mono||is_stereo);
  ima_layout_ok<=align>=64&&align<=4096&&(align&(align-1'b1))==0&&samples_per_block==expected_spb;
  chunk_ok<=chunk_len<=32'h0fffffff&&(tag_data||chunk_len<=65500);
  // CHECK_PRE supplies a settle cycle after the last chunk-length byte.
  // Keep wide header comparisons off the state/output-position enables.
  pcm_data_ok<=pcm_fields_ok&&chunk_len!=0&&!(is_mono&&chunk_len[27])&&
               (is_stereo?chunk_len[1:0]==0:chunk_len[0]==0);
  ima_data_ok<=ima_fields_ok&&ima_layout_ok&&total_samples!=0&&total_samples<=32'h03ffffff&&
               chunk_len>=(is_stereo?8:4)&&(is_stereo?chunk_len[2:0]==0:chunk_len[1:0]==0);
 end
 assign din_ready=(state==RIFF||state==TAG||state==LENGTH||state==PAYLOAD||state==BLOCK_HDR||state==GET_BYTE);
 assign sample_valid=(state==OUTPUT_PAIR)&&output_delay==0;
 assign left=left_q;assign right=stereo?right_q:left_q;
 always @(posedge clk or posedge rst)begin
  if(rst)begin diff_a<=0;diff_b<=0;diff<=0;sum<=0;state<=STOP;done<=0;error<=0;ready<=0;stereo<=0;total_samples<=0;
   pos<=0;tag<=0;chunk_len<=0;payload_left<=0;payload_pos<=0;data_left<=0;remaining<=0;data_offset<=0;data_bytes<=0;
   field<=0;fmt_seen<=0;fact_seen<=0;format<=0;channels<=0;bits<=0;align<=0;samples_per_block<=0;rate<=0;
   hdr_pos<=0;block_pos<=0;channel<=0;nibble_hi<=0;packed_byte<=0;group_pos<=0;out_pos<=0;output_len<=0;first_pair<=0;
   predictor[0]<=0;predictor[1]<=0;step_index[0]<=0;step_index[1]<=0;
  end else if(start)begin state<=RIFF;pos<=0;done<=0;error<=0;ready<=0;stereo<=0;total_samples<=0;
   fmt_seen<=0;fact_seen<=0;field<=0;tag<=0;chunk_len<=0;format<=0;channels<=0;bits<=0;align<=0;rate<=0;
  end else if(pcm_seek&&ready&&is_pcm)begin
   state<=GET_BYTE;
   data_left<=data_bytes-pcm_seek_byte;remaining<=(data_bytes-pcm_seek_byte)>>(stereo?2:1);
   group_pos<=0;out_pos<=0;output_len<=1;done<=0;
  end else begin
   if(din_valid&&din_ready&&!ready)begin pos<=pos+1'b1;if(pos>=65536&&!ready)begin error<=1;state<=STOP;end end
   case(state)
    RIFF:if(din_valid)begin
     case(pos)
      0:if(din!="R")begin error<=1;state<=STOP;end
      1:if(din!="I")begin error<=1;state<=STOP;end
      2,3:if(din!="F")begin error<=1;state<=STOP;end

      8:if(din!="W")begin error<=1;state<=STOP;end
      9:if(din!="A")begin error<=1;state<=STOP;end
      10:if(din!="V")begin error<=1;state<=STOP;end
      11:if(din!="E")begin error<=1;state<=STOP;end else begin state<=TAG;field<=0;tag<=0;end
     endcase
    end
    TAG:if(din_valid)begin tag<={din,tag[31:8]};field<=field+1'b1;if(field==3)begin state<=LENGTH;chunk_len<=0;end end
    LENGTH:if(din_valid)begin
     chunk_len<={din,chunk_len[31:8]};field<=field+1'b1;
     if(field==3)begin state<=CHECK_PRE;payload_pos<=0;end
    end
    CHECK_PRE:state<=CHECK;
    CHECK:begin
     if(!chunk_ok)begin error<=1;state<=STOP;end
     else if(tag_data)begin
      if(is_pcm)begin
       if(!pcm_data_ok)begin error<=1;state<=STOP;end
       else begin
        total_samples<=chunk_len>>(is_stereo?2:1);remaining<=chunk_len>>(is_stereo?2:1);
        data_offset<=pos;data_bytes<=chunk_len;data_left<=chunk_len;ready<=1;stereo<=is_stereo;
        state<=GET_BYTE;group_pos<=0;output_len<=1;out_pos<=0;
       end
      end else if(!ima_data_ok)begin error<=1;state<=STOP;end
      else begin data_left<=chunk_len;remaining<=total_samples;ready<=1;stereo<=is_stereo;
       state<=BLOCK_HDR;hdr_pos<=0;block_pos<=0;channel<=0;end
     end else if(chunk_empty)begin state<=TAG;tag<=0;end
     else begin payload_left<=chunk_len+chunk_len[0];state<=PAYLOAD;end
    end
    PAYLOAD:if(din_valid)begin
     if(payload_pos!=31)payload_pos<=payload_pos+1'b1;payload_left<=payload_left-1'b1;
     if(tag_fmt)begin
      case(payload_pos)
       0:format[7:0]<=din;1:format[15:8]<=din;
       2:channels[7:0]<=din;3:channels[15:8]<=din;
       4,5,6,7:rate<={din,rate[31:8]};
       12:align[7:0]<=din;13:begin align[12:8]<=din[4:0];if(din>16)begin error<=1;state<=STOP;end end 14:bits[7:0]<=din;15:bits[15:8]<=din;
       18:samples_per_block[7:0]<=din;19:samples_per_block[12:8]<=din[4:0];
      endcase
      if(payload_left==1 && fmt_chunk_valid)fmt_seen<=1;
     end else if(tag_fact && payload_pos<4)begin
      total_samples<={din,total_samples[31:8]};if(payload_pos==3)fact_seen<=1;
     end
     if(payload_left==1)begin state<=TAG;tag<=0;field<=0;end
    end
    BLOCK_HDR:if(data_left==0)begin error<=1;state<=STOP;end else if(din_valid)begin
     block_pos<=block_pos+1'b1;data_left<=data_left-1'b1;hdr_pos<=hdr_pos+1'b1;
     case(hdr_pos[1:0])
      0:predictor[channel][7:0]<=din;
      1:predictor[channel][15:8]<=din;
      2:begin step_index[channel]<=din[6:0];if(din>88)begin error<=1;state<=STOP;end end
      3:begin
       if(din!=0)begin error<=1;state<=STOP;end
       else if(stereo&&!channel)channel<=1;
       else begin state<=BLOCK_CHECK;channel<=0;end
      end
     endcase
    end
    BLOCK_CHECK:begin
output_len<=1;out_pos<=0;first_pair<=1;state<=OUTPUT_PAIR;
    end
    GET_BYTE:if(data_left==0)begin error<=1;state<=STOP;end else if(din_valid)begin
     data_left<=data_left-1'b1;
     if(is_pcm)begin
      group_pos<=group_pos+1'b1;
      if(group_pos==(stereo?3:1))begin state<=OUTPUT_PAIR;output_len<=1;out_pos<=0;group_pos<=0;end
     end else begin packed_byte<=din;nibble_hi<=0;block_pos<=block_pos+1'b1;state<=LOOKUP;end
    end
    LOOKUP:state<=STEP_PARTS;
    STEP_PARTS:begin
     diff_a<={4'd0,step[15:3]}+(code[0]?{4'd0,step[15:2]}:17'd0);
     diff_b<=(code[1]?{2'd0,step[15:1]}:17'd0)+(code[2]?{1'b0,step}:17'd0);
     state<=DIFF_SUM;
    end
    DIFF_SUM:begin diff<=diff_a+diff_b;state<=RECON_SUM;end
    RECON_SUM:begin sum<=$signed(predictor[channel])+(code[3]?-$signed({1'b0,diff}):$signed({1'b0,diff}));state<=DECODE;end
    DECODE:begin
     predictor[channel]<=decoded;step_index[channel]<=next_index<0?0:next_index>88?88:next_index[6:0];

     nibble_hi<=!nibble_hi;group_pos<=group_pos+1'b1;
     if(group_pos==7)begin
      group_pos<=0;
      if(stereo&&!channel)begin channel<=1;state<=GET_BYTE;end
      else begin channel<=0;output_len<=8;out_pos<=0;first_pair<=0;state<=OUTPUT_PAIR;end
     end else if(nibble_hi)state<=GET_BYTE;else state<=LOOKUP;
    end
    OUTPUT_PAIR:if(sample_ready&&output_delay==0)begin
     remaining<=remaining-1'b1;
     if(remaining==1)begin done<=1;state<=STOP;end
     else if(out_pos+1==output_len)state<=AFTER_OUTPUT;
     else out_pos<=out_pos+1'b1;
    end
    AFTER_OUTPUT:begin
     group_pos<=0;channel<=0;
     if(is_pcm)state<=GET_BYTE;
     else if(block_pos==align)begin
      if(data_left==0)begin error<=1;state<=STOP;end
      else begin state<=BLOCK_HDR;hdr_pos<=0;block_pos<=0;end
     end else state<=GET_BYTE;
    end
   endcase
  end
 end
endmodule


