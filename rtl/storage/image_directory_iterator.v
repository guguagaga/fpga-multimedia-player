// Root-directory image cursor. Constant metadata space; no fixed image table.
// A result remains stable until consume. Pause blocks NEW transactions only.
// The caller must complete or reset the transport on a missing sector end.
module image_directory_iterator (
  input wire clk, rst, enable, pause,
  input wire [31:0] fat_start, data_start,
  input wire [27:0] root_cluster, max_cluster,
  input wire [3:0] cluster_shift,
  output reg valid, empty, error,
  output reg [31:0] image_lba,
  input wire consume,
  output wire sd_req,
  output reg [31:0] sd_addr,
  input wire [7:0] sd_data,
  input wire sd_valid, sd_end, sd_error
);
  localparam INIT=0, LOCATE=1, SHIFT=2, ADD=3, ISSUE=4, READ=5,
             EVAL=6, FAT_ADDR=7, FAT_ISSUE=8, FAT_READ=9,
             FAT_EVAL=10, RESULT_SHIFT=11, RESULT_ADD=12, HOLD=13,
             ADVANCE=14, WRAP=15, STOP=16;
  reg [4:0] state;
  reg [27:0] cluster, hops, file_cluster;
  reg [7:0] sector_index;
  reg [4:0] start_entry, resume_entry;
  reg [9:0] byte_count;
  reg [31:0] offset, file_size, fat_next;
  reg [3:0] shifts;
  reg entry_ok, ext_bmp, ext_qoi, found, end_seen, read_bad, wrapped;
  wire [7:0] upper = sd_data & 8'hdf;
  wire [7:0] sectors_per_cluster = 8'd1 << cluster_shift;
  wire entry_active = byte_count[8:5] >= start_entry && !found && !end_seen;
  assign sd_req = state == READ || state == FAT_READ;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state<=INIT; valid<=0; empty<=0; error<=0; image_lba<=0;
      cluster<=0; hops<=0; sector_index<=0; start_entry<=0; resume_entry<=0;
      byte_count<=0; offset<=0; shifts<=0; sd_addr<=0; file_cluster<=0;
      file_size<=0; fat_next<=0; entry_ok<=0; ext_bmp<=0; ext_qoi<=0;
      found<=0; end_seen<=0; read_bad<=0; wrapped<=0;
    end else begin
      case(state)
        INIT: if(enable) begin
          if(root_cluster<2 || root_cluster>max_cluster || cluster_shift>7) begin
            error<=1; state<=STOP;
          end else begin
            cluster<=root_cluster; hops<=0; sector_index<=0;
            start_entry<=0; state<=LOCATE;
          end
        end
        LOCATE: begin offset<=cluster-2; shifts<=cluster_shift; state<=SHIFT; end
        SHIFT: if(shifts!=0) begin offset<=offset<<1; shifts<=shifts-1'b1; end
               else state<=ADD;
        ADD: begin sd_addr<=data_start+offset+sector_index; state<=ISSUE; end
        ISSUE: if(enable && !pause) begin
          byte_count<=0; found<=0; end_seen<=0; read_bad<=0;
          entry_ok<=0; state<=READ;
        end
        READ: begin
          if(sd_error) read_bad<=1;
          if(sd_valid) begin
            if(byte_count<513) byte_count<=byte_count+1'b1;
            if(byte_count<512 && entry_active) begin
              case(byte_count[4:0])
                0: begin
                  entry_ok<=sd_data!=0 && sd_data!=8'he5;
                  if(sd_data==0) end_seen<=1;
                  ext_bmp<=0; ext_qoi<=0; file_cluster<=0; file_size<=0;
                end
                8: begin ext_bmp<=upper=="B"; ext_qoi<=upper=="Q"; end
                9: begin ext_bmp<=ext_bmp && upper=="M"; ext_qoi<=ext_qoi && upper=="O"; end
                10: begin ext_bmp<=ext_bmp && upper=="P"; ext_qoi<=ext_qoi && upper=="I"; end
                11: entry_ok<=entry_ok && sd_data!=8'h0f && !sd_data[4] && !sd_data[3];
                20: file_cluster[23:16]<=sd_data;
                21: begin file_cluster[27:24]<=sd_data[3:0]; if(sd_data[7:4]!=0) entry_ok<=0; end
                26: file_cluster[7:0]<=sd_data;
                27: file_cluster[15:8]<=sd_data;
                28: file_size[7:0]<=sd_data;
                29: file_size[15:8]<=sd_data;
                30: file_size[23:16]<=sd_data;
                31: if(entry_ok && (ext_bmp || ext_qoi) &&
                    file_cluster>=2 && file_cluster<=max_cluster &&
                    (sd_data!=0 || file_size[23:0]!=0)) begin
                  found<=1; resume_entry<={1'b0,byte_count[8:5]}+1'b1;
                end
              endcase
            end
          end
          if(sd_end) state<=EVAL;
        end
        EVAL: begin
          if(read_bad || byte_count!=512) begin error<=1; state<=STOP; end
          else if(found) begin
            offset<=file_cluster-2; shifts<=cluster_shift; state<=RESULT_SHIFT;
          end else if(end_seen) state<=WRAP;
          else begin start_entry<=16; state<=ADVANCE; end
        end
        RESULT_SHIFT: if(shifts!=0) begin offset<=offset<<1; shifts<=shifts-1'b1; end
                      else state<=RESULT_ADD;
        RESULT_ADD: begin image_lba<=data_start+offset; valid<=1; state<=HOLD; end
        HOLD: if(consume) begin
          valid<=0; wrapped<=0; start_entry<=resume_entry; state<=ADVANCE;
        end
        ADVANCE: begin
          if(start_entry<16) state<=LOCATE;
          else if(sector_index+8'd1<sectors_per_cluster) begin
            sector_index<=sector_index+1'b1; start_entry<=0; state<=LOCATE;
          end else state<=FAT_ADDR;
        end
        FAT_ADDR: begin sd_addr<=fat_start+{11'd0,cluster[27:7]}; state<=FAT_ISSUE; end
        FAT_ISSUE: if(enable && !pause) begin
          byte_count<=0; fat_next<=0; read_bad<=0; state<=FAT_READ;
        end
        FAT_READ: begin
          if(sd_error) read_bad<=1;
          if(sd_valid) begin
            if(byte_count<513) byte_count<=byte_count+1'b1;
            if(byte_count<512 && byte_count[8:2]==cluster[6:0]) begin
              case(byte_count[1:0])
                0: fat_next[7:0]<=sd_data;
                1: fat_next[15:8]<=sd_data;
                2: fat_next[23:16]<=sd_data;
                3: fat_next[31:24]<=sd_data;
              endcase
            end
          end
          if(sd_end) state<=FAT_EVAL;
        end
        FAT_EVAL: begin
          if(read_bad || byte_count!=512) begin error<=1; state<=STOP; end
          else if(fat_next[27:0]>=28'hffffff8) state<=WRAP;
          else if(fat_next[27:0]<2 || fat_next[27:0]>max_cluster ||
                  fat_next[27:0]==cluster || hops>=max_cluster-2) begin
            error<=1; state<=STOP;
          end else begin
            cluster<=fat_next[27:0]; hops<=hops+1'b1;
            sector_index<=0; start_entry<=0; state<=LOCATE;
          end
        end
        WRAP: begin
          if(wrapped) begin empty<=1; state<=STOP; end
          else begin
            wrapped<=1; cluster<=root_cluster; hops<=0;
            sector_index<=0; start_entry<=0; state<=LOCATE;
          end
        end
        STOP: valid<=0; // Stable diagnostic until remount/reset.
        default: begin error<=1; state<=STOP; end
      endcase
    end
  end
endmodule
