// Autodetect QOA / shared PCM and IMA WAV decoding. Format is selected
// by file bytes. Compressed seek discards decoded samples; past EOF restarts.
module compressed_audio_reader(
 input wire clk,rst,start,halt,pause,seek,fifo_drained,
 input wire[31:0]sector,input wire fifo_almost_full,
 output reg pcm_fallback,output wire wav_ready,output wire stereo,
 output wire[31:0]data_size,output reg[31:0]pcm_out_cnt,
 output wire sd_req,output wire[31:0]sd_addr,input wire[7:0]sd_data,
 input wire sd_valid,sd_end,sd_grant,
 output reg track_end,track_bad,pcm_valid,output reg[7:0]pcm_data,
 output wire idle,output wire[3:0]dbg_state);
 localparam IDLE=0,PROBE=1,STOP_PROBE=2,START_CODEC=3,RUN=4,DONE=5,BAD=6;
 reg[2:0]state;reg[1:0]kind;
 reg source_restart,decoder_start;reg[31:0]sector_l,source_sector;
 reg[31:0]probe_pos,probe_magic,probe_tag,probe_len,probe_left;
 reg[1:0]probe_field,probe_state;reg[15:0]probe_format;
 wire[7:0]byte_data;wire byte_valid,source_busy,source_error;
 wire q_ready,i_ready,q_ir,i_ir,q_sv,i_sv,q_done,i_done,q_error,i_error,q_stereo,i_stereo;
 wire[15:0]ql,qr,il,ir;wire[31:0]q_total,i_total;
 wire codec_ready=(kind==1)?q_ready:i_ready;
 wire codec_error=(kind==1)?q_error:i_error;
 wire codec_done=(kind==1)?q_done:i_done;
 wire codec_sv=(kind==1)?q_sv:i_sv;
 wire[15:0]sample_l=(kind==1)?ql:il,sample_r=(kind==1)?qr:ir;
 reg[31:0]serial_word;reg[2:0]serial_left;reg[6:0]format_settle;reg ready_d;
 reg[19:0]skip_left;reg seek_wait,wrap_seek;
 reg[8:0]prefix_left;reg prefix_active;
 wire i_pcm;wire[31:0]i_data_offset;
 reg pcm_seek;reg[31:0]pcm_seek_byte;
 wire[31:0]pcm_step=stereo?32'd1920000:32'd960000;
 reg[32:0]seek_sum_q;reg[31:0]seek_limit_q;
 reg[31:0]pcm_target_q,pcm_file_offset_q;
 reg[2:0]seek_phase;
 // Break Gray-pointer occupancy arithmetic -> decoder clock-enable paths.
 // The production FIFO is 8192B with almost-full at 6144B. A one-clock
 // observation delay can accept at most one additional stereo sample (4B).
 // Any active serializer also finishes at most 4B. No sector streams PCM
 // directly: source bytes are consumed by the decoder sample handshake.
 // Halt/seek remain immediate; the FIFO's actual full guard is unchanged.
 reg fifo_almost_full_q;
 always@(posedge clk or posedge rst)begin
  if(rst)fifo_almost_full_q<=1'b1;
  else fifo_almost_full_q<=fifo_almost_full;
 end
 wire sample_accept=(state==RUN)&&!halt&&!seek&&!seek_wait&&format_settle==0&&serial_left==0&&
                       (skip_left!=0||!fifo_almost_full_q);
 wire source_cancel=halt||state==STOP_PROBE||state==DONE||state==BAD||(seek_wait&&((kind==2&&i_pcm)||wrap_seek));
 wire byte_ready=!source_restart&&((state==PROBE)||((state==RUN)&&!halt&&!seek_wait&&((prefix_active)||((kind==1)?q_ir:i_ir))));
 wire codec_input_valid=(state==RUN)&&!halt&&!seek_wait&&!source_restart&&!prefix_active&&byte_valid;
 assign wav_ready=(state==RUN||state==DONE)&&codec_ready&&!seek_wait&&skip_left==0;
 assign stereo=(kind==1)?q_stereo:i_stereo;
 wire[31:0]total_samples=(kind==1)?q_total:i_total;
 assign data_size=stereo?{total_samples[29:0],2'd0}:{total_samples[30:0],1'd0};
 assign idle=!source_busy&&serial_left==0;
 assign dbg_state={1'b0,state};
 sector_byte_source src(.clk(clk),.rst(rst),.restart(source_restart),.cancel(source_cancel),
  .enable(!pause&&!fifo_almost_full_q),.base_sector(source_sector),.sd_req(sd_req),.sd_addr(sd_addr),
  .sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end),.sd_grant(sd_grant),
  .dout(byte_data),.valid(byte_valid),.ready(byte_ready),.busy(source_busy),.error(source_error));
 qoa_stream q(.clk(clk),.rst(rst),.start(decoder_start&&kind==1),.din(byte_data),
  .din_valid(codec_input_valid&&kind==1),.din_ready(q_ir),.sample_valid(q_sv),.sample_ready(sample_accept&&kind==1),
  .left(ql),.right(qr),.done(q_done),.error(q_error),.ready(q_ready),.stereo(q_stereo),.total_samples(q_total));
 ima_stream i(.clk(clk),.rst(rst),.start(decoder_start&&kind==2),.din(byte_data),
  .din_valid(codec_input_valid&&kind==2),.din_ready(i_ir),.sample_valid(i_sv),.sample_ready(sample_accept&&kind==2),
  .left(il),.right(ir),.done(i_done),.error(i_error),.ready(i_ready),.stereo(i_stereo),.total_samples(i_total),
  .pcm_mode(i_pcm),.data_offset(i_data_offset),.pcm_seek(pcm_seek),.pcm_seek_byte(pcm_seek_byte));
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;kind<=0;source_restart<=0;decoder_start<=0;sector_l<=0;source_sector<=0;
   probe_pos<=0;probe_magic<=0;probe_tag<=0;probe_len<=0;probe_left<=0;probe_field<=0;probe_state<=0;probe_format<=0;
   pcm_fallback<=0;pcm_out_cnt<=0;track_end<=0;track_bad<=0;pcm_valid<=0;pcm_data<=0;
   serial_word<=0;serial_left<=0;format_settle<=0;ready_d<=0;skip_left<=0;seek_wait<=0;wrap_seek<=0;
   prefix_left<=0;prefix_active<=0;pcm_seek<=0;pcm_seek_byte<=0;pcm_target_q<=0;pcm_file_offset_q<=0;seek_phase<=0;seek_sum_q<=0;seek_limit_q<=0;
  end else begin
   source_restart<=0;decoder_start<=0;track_end<=0;track_bad<=0;pcm_valid<=0;pcm_seek<=0;
   ready_d<=codec_ready;
   if(!ready_d&&codec_ready)format_settle<=64;
   else if(format_settle!=0)format_settle<=format_settle-1'b1;
   if(serial_left!=0)begin
    pcm_data<=serial_word[7:0];pcm_valid<=1;serial_word<=serial_word>>8;
    serial_left<=serial_left-1'b1;pcm_out_cnt<=pcm_out_cnt+1'b1;
   end
   if(start&&!source_busy&&serial_left==0)begin
    sector_l<=sector;source_sector<=sector;source_restart<=1;state<=PROBE;kind<=0;probe_pos<=0;probe_magic<=0;
    probe_tag<=0;probe_len<=0;probe_left<=0;probe_field<=0;probe_state<=0;probe_format<=0;
    pcm_fallback<=0;pcm_out_cnt<=0;skip_left<=0;seek_wait<=0;wrap_seek<=0;ready_d<=0;prefix_left<=0;prefix_active<=0;seek_phase<=0;
   end else case(state)
    PROBE:if(byte_valid&&!source_restart)begin
     probe_pos<=probe_pos+1'b1;probe_magic<={probe_magic[23:0],byte_data};
     if(probe_pos==3)begin kind<=({probe_magic[23:0],byte_data}==32'h716f6166)?1:2;state<=STOP_PROBE;end
    end
    STOP_PROBE:if(!source_busy)begin
     source_restart<=1;decoder_start<=1;state<=START_CODEC;ready_d<=0;
    end
    START_CODEC:begin state<=RUN;format_settle<=64;end
    RUN:begin
     if(codec_sv&&sample_accept)begin
      if(skip_left!=0)begin
       skip_left<=skip_left-1'b1;pcm_out_cnt<=pcm_out_cnt+(stereo?4:2);
      end else begin serial_word<={sample_r,sample_l};serial_left<=stereo?4:2;end
     end
     if(prefix_active&&byte_valid&&byte_ready)begin prefix_left<=prefix_left-1'b1;if(prefix_left==1)prefix_active<=0;end
     if(seek)begin seek_wait<=1;seek_phase<=0;skip_left<=0;wrap_seek<=0;end
     if(seek_wait&&fifo_drained&&serial_left==0)begin
      case(seek_phase)
       0:begin seek_sum_q<={1'b0,pcm_out_cnt}+{1'b0,pcm_step};seek_limit_q<=data_size;seek_phase<=1;end
       1:begin pcm_target_q<=seek_sum_q>={1'b0,seek_limit_q}?32'd0:seek_sum_q[31:0];seek_phase<=2;end
       2:begin
        if(kind==2&&i_pcm)begin pcm_file_offset_q<=i_data_offset+pcm_target_q;seek_phase<=3;end
        else if(pcm_target_q==0)begin wrap_seek<=1;seek_phase<=3;end
        else begin skip_left<=480000;seek_wait<=0;end
       end
       3:if(!source_busy)begin
        source_sector<=(kind==2&&i_pcm)?sector_l+{23'd0,pcm_file_offset_q[31:9]}:sector_l;seek_phase<=4;
       end
       4:begin
        source_restart<=1;seek_wait<=0;format_settle<=64;
        if(kind==2&&i_pcm)begin
         pcm_seek_byte<=pcm_target_q;pcm_seek<=1;prefix_left<=pcm_file_offset_q[8:0];prefix_active<=|pcm_file_offset_q[8:0];pcm_out_cnt<=pcm_target_q;
        end else begin
         decoder_start<=1;state<=START_CODEC;wrap_seek<=0;skip_left<=0;pcm_out_cnt<=0;ready_d<=0;
        end
       end
      endcase
     end
     if(codec_done&&serial_left==0&&!seek&&!seek_wait)begin state<=DONE;track_end<=1;end
     if(codec_error)begin state<=BAD;track_bad<=1;end
    end
   endcase
   // source_error is sticky until source_restart is sampled. A new track
   // must be allowed through those two cycles to clear the previous fault.
   if(source_error&&!start&&!source_restart&&state!=IDLE&&state!=BAD)begin state<=BAD;track_bad<=1;end
  end
 end
endmodule
