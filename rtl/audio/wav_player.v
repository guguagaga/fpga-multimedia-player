`timescale 1ns / 1ps
// Sector transactions are indivisible. A request and its address remain stable
// until read_end; control events finish the current PCM sample and drain it.
// Supported media: contiguous PCM WAV, 48 kHz, 16 bit, one or two channels.
module wav_player #(
  parameter [31:0] BLIND_SCAN_LIMIT = 32'd4096,
  parameter [23:0] SEEK_DRAIN_WD = 24'd10_000_000,
  parameter [23:0] HDR_WD = 24'd10_000_000,
  parameter [3:0] BUS_SETTLE = 4'd2,
  parameter LOOP_ON_EOF = 1'b1
) (
  input wire clk, rst,
  input wire scan_start,
  input wire [31:0] scan_start_sector, scan_max_sector,
  input wire sd_init_done, track_sel,
  input wire [31:0] track_sel_sector,
  output reg wav_ready,
  output reg [31:0] sample_rate,
  output reg [15:0] channels, bit_depth,
  output reg [31:0] data_size, pcm_out_cnt,
  output reg sd_sec_read,
  output reg [31:0] sd_sec_read_addr,
  input wire [7:0] sd_sec_read_data,
  input wire sd_sec_read_data_valid, sd_sec_read_end,
  input wire fifo_almost_full, pause, seek,
  input wire [31:0] step_bytes,
  // Synchronized from the audio domain; both FIFO and sample builder idle.
  input wire fifo_drained,
  // Sector ownership, so time spent waiting for another client is excluded.
  input wire sd_grant,
  output reg track_end, track_bad, pcm_valid,
  output reg [7:0] pcm_data,
  output wire [3:0] dbg_state,
  output wire dbg_gate_open
);
  localparam [1:0] ST_IDLE = 0, ST_HDR = 1, ST_STREAM = 2, ST_SEEK = 3;
  localparam [1:0] ACT_SELECT = 0, ACT_START = 1, ACT_SEEK = 2, ACT_STOP = 3;
  localparam [1:0] HP_RIFF = 0, HP_TAG = 1, HP_LEN = 2, HP_PAYLOAD = 3;
  localparam [31:0] MAX_HEADER_BYTES = 32'd65536;
  reg [1:0] state, action, hp;
  reg inflight, scanning, pending_scan;
  reg [31:0] wav_sector, pending_sector, scan_stop;
  // bus_pos is the file offset of the next received SD byte; wanted is the
  // first PCM byte to emit. Neither is advanced without an actual data beat.
  reg [31:0] bus_pos, wanted, data_offset, end_pos, seek_latched;
  reg [ 3:0] request_gap;
  reg [ 6:0] format_settle;
  reg [23:0] wait_count;
  // Recover an orphaned request after 600 us without ownership or responses.
  // A granted SPI transaction may legitimately exceed this interval.
  localparam [15:0] INFLIGHT_WD_MAX = 16'd60_000;
  localparam [23:0] SEEK_STAY_MAX   = 24'd10_000_000;
  reg [23:0] seek_stay_cnt;
  reg seek_stay_timeout;
  reg [15:0] inflight_wd;
  reg inflight_expired;
  wire orphan_timeout = inflight && !sd_grant && !sd_sec_read_data_valid && !sd_sec_read_end &&
      inflight_expired;
  reg timeout_reported;
  reg [31:0] riff_length, chunk_id, chunk_len, payload_left, payload_index;
  reg [1:0] field_index;
  reg header_bad, header_complete, fmt_seen;
  reg [15:0] new_format, new_channels, new_bits, new_align;
  reg [31:0] new_rate, new_size, new_offset;

  // 预存 scan_stop-1，使扇区边界判断只执行比较，缩短地址控制路径。
  reg [31:0] scan_stop_m1;
  always @(posedge clk or posedge rst) begin
    if (rst) scan_stop_m1 <= 32'd0;
    else scan_stop_m1 <= scan_stop - 32'd1;
  end
  // Cut Gray-decode -> occupancy subtraction -> request-enable path.
  // Board FIFO has 8192 entries, almost_full=6144: 2048-byte reserve.
  // One registered flag adds at most one byte before a 512-byte in-flight
  // sector; this remains well within that reserve. Reset blocks new stream
  // requests until the current occupancy has been sampled.
  reg fifo_almost_full_q;
  always @(posedge clk or posedge rst) begin
    if (rst) fifo_almost_full_q <= 1'b1;
    else fifo_almost_full_q <= fifo_almost_full;
  end
  wire [31:0] length_now = {sd_sec_read_data, chunk_len[31:8]};
  // seek、track_sel、scan_start 在模块入口统一寄存一拍，限制跨模块控制扇出。
  reg seek_q, track_sel_q, scan_start_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      seek_q <= 1'b0;
      track_sel_q <= 1'b0;
      scan_start_q <= 1'b0;
    end else begin
      seek_q <= seek;
      track_sel_q <= track_sel;
      scan_start_q <= scan_start;
    end
  end
  wire [31:0] frame_mask = (channels == 16'd2) ? 32'd3 : 32'd1;
  wire partial_frame = (pcm_out_cnt & frame_mask) != 0;
  wire old_tail = ((state == ST_STREAM) && (track_sel_q || scan_start_q || seek_q)) ||
      ((state == ST_SEEK) && ((action == ACT_SELECT) || (action == ACT_SEEK)));
  wire gate_open = ((state == ST_STREAM && !track_sel_q && !scan_start_q && !seek_q) ||
                    (old_tail && partial_frame)) && (bus_pos >= wanted) && (bus_pos < end_pos);
  // 文件头确定后预计算偏移和对齐掩码，使实时跳转路径仅处理变化的采样偏移。
  reg [31:0] seek_base_r;  // data_offset + step_bytes
  reg [31:0] frame_mask_n_r;  // ~frame_mask  (mask off sub-frame bytes)
  // 寄存 step_bytes，播放和跳转逻辑使用稳定的声道相关步长。
  reg [31:0] step_bytes_r;
  always @(posedge clk or posedge rst) begin
    if (rst) step_bytes_r <= 32'd960_000;
    else step_bytes_r <= step_bytes;
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      seek_base_r    <= 32'd0;
      frame_mask_n_r <= 32'hFFFF_FFFE;
    end else if (header_complete && !header_bad) begin
      seek_base_r    <= data_offset + step_bytes_r;
      frame_mask_n_r <= ~((channels == 16'd2) ? 32'd3 : 32'd1);
    end
  end
  wire [32:0] seek_sum_p = {1'b0, pcm_out_cnt} + {1'b0, seek_base_r};

  // 按采样帧边界对齐目标地址：T = sum - ((sum-D) & ~M)。
  // 掩码只影响最低两位，低位差值使用两位运算，避免宽减法后再加回基址。
  wire [1:0] seek_low = (seek_sum_p[1:0] - data_offset[1:0]) & ~frame_mask_n_r[1:0];
  wire [31:0] seek_target = (seek_sum_p[32] || seek_sum_p >= {1'b0, end_pos}) ?
      data_offset : (seek_sum_p[31:0] - {30'd0, seek_low});
  wire [32:0] repeat_sum = {1'b0, seek_latched} + {1'b0, step_bytes_r};
  // 重复播放地址使用已寄存的帧对齐掩码，保持与采样边界一致。
  wire [1:0] rep_low = (repeat_sum[1:0] - data_offset[1:0]) & ~frame_mask_n_r[1:0];
  wire [31:0] repeat_target = (repeat_sum[32] || repeat_sum >= {1'b0, end_pos}) ?
      data_offset : (repeat_sum[31:0] - {30'd0, rep_low});
  // 预存 RIFF 长度上界 riff_length+8，避免每次解析块长度时重复加法。
  reg [32:0] riff_limit_r;
  always @(posedge clk or posedge rst) begin
    if (rst) riff_limit_r <= 33'd0;
    else riff_limit_r <= {1'b0, riff_length} + 33'd8;
  end
  // At the final tag byte, the payload begins five bytes later (4 length
  // bytes plus the next byte). Precompute the RIFF bound before HP_LEN ends.
  // This remains exact even for consecutive valid bytes; no SPI gap assumed.
  reg [32:0] chunk_payload_offset;
  reg [32:0] chunk_available;
  reg chunk_offset_bad;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      chunk_payload_offset <= 0;
      chunk_available <= 0;
      chunk_offset_bad <= 1;
    end else begin
      if (inflight && sd_sec_read_data_valid && state == ST_HDR && hp == HP_TAG && field_index == 3)
        chunk_payload_offset <= {1'b0, bus_pos} + 33'd5;
      chunk_available  <= riff_limit_r - chunk_payload_offset;
      chunk_offset_bad <= chunk_payload_offset > riff_limit_r;
    end
  end
  // MAX_HEADER_BYTES 为 2 的幂时通过高位非零判断越界，其余参数使用常数比较。
  wire hdr_too_long = (MAX_HEADER_BYTES == 32'd65536) ?
      (|bus_pos[31:16]) : (bus_pos >= MAX_HEADER_BYTES);
  // 预存 end_pos-1，以当前位置比较检测最后一个字节。
  reg [31:0] end_pos_m1_r;
  always @(posedge clk or posedge rst) begin
    if (rst) end_pos_m1_r <= 32'd0 - 32'd1;
    else end_pos_m1_r <= end_pos - 32'd1;
  end
  wire format_ok = (new_format == 16'd1) && (new_rate == 32'd48000) && (new_bits == 16'd16) &&
      ((new_channels == 16'd1 && new_align == 16'd2) ||
       (new_channels == 16'd2 && new_align == 16'd4));
  assign dbg_state = {2'd0, state};
  assign dbg_gate_open = gate_open;

  // All functional registers have one owner. Parsing is chunk-based, including
  // RIFF's odd-length padding; text such as "data" inside LIST is never a tag.
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      inflight_wd <= 0;
      inflight_expired <= 0;
      seek_stay_cnt <= 0;
      seek_stay_timeout <= 0;
      state <= ST_IDLE;
      action <= ACT_STOP;
      hp <= HP_RIFF;
      inflight <= 0;
      scanning <= 0;
      pending_scan <= 0;
      wav_sector <= 0;
      pending_sector <= 0;
      scan_stop <= 0;
      bus_pos <= 0;
      wanted <= 0;
      data_offset <= 0;
      end_pos <= 0;
      seek_latched <= 0;
      request_gap <= 0;
      format_settle <= 0;
      wait_count <= 0;
      timeout_reported <= 0;
      riff_length <= 0;
      chunk_id <= 0;
      chunk_len <= 0;
      payload_left <= 0;
      payload_index <= 0;
      field_index <= 0;
      header_bad <= 0;
      header_complete <= 0;
      fmt_seen <= 0;
      new_format <= 0;
      new_channels <= 0;
      new_bits <= 0;
      new_align <= 0;
      new_rate <= 0;
      new_size <= 0;
      new_offset <= 0;
      wav_ready <= 0;
      sample_rate <= 0;
      channels <= 0;
      bit_depth <= 0;
      data_size <= 0;
      pcm_out_cnt <= 0;
      sd_sec_read <= 0;
      sd_sec_read_addr <= 0;
      track_end <= 0;
      track_bad <= 0;
      pcm_valid <= 0;
      pcm_data <= 0;
    end else if (!sd_init_done) begin
      inflight_wd <= 0;
      inflight_expired <= 0;
      seek_stay_cnt <= 0;
      seek_stay_timeout <= 0;
      state <= ST_IDLE;
      inflight <= 0;
      scanning <= 0;
      sd_sec_read <= 0;
      wav_ready <= 0;
      track_end <= 0;
      track_bad <= 0;
      pcm_valid <= 0;
      request_gap <= 0;
      wait_count <= 0;
      data_offset <= 0;
      end_pos <= 0;
      pcm_out_cnt <= 0;
    end else begin
      pcm_valid <= 0;
      track_end <= 0;
      track_bad <= 0;
      if (request_gap != 0) request_gap <= request_gap - 1'b1;
      if (format_settle != 0) format_settle <= format_settle - 1'b1;

      // A stalled physical transaction cannot be safely reassigned. Report
      // it once, keep ownership until read_end or a card/system reset.
      if (inflight && sd_grant) begin
        if (sd_sec_read_data_valid) wait_count <= 0;
        else if (wait_count != 24'hffffff) wait_count <= wait_count + 1'b1;
        if (!timeout_reported && wait_count >= ((state == ST_SEEK) ? SEEK_DRAIN_WD : HDR_WD)) begin
          timeout_reported <= 1;
          track_bad <= 1;
        end
      end else wait_count <= 0;

      if (sd_sec_read_data_valid && inflight) begin
        bus_pos <= bus_pos + 1'b1;
        if (gate_open) begin
          pcm_data <= sd_sec_read_data;
          pcm_valid <= 1;
          pcm_out_cnt <= pcm_out_cnt + 1'b1;
          // 当前位置等于 end_pos-1 时结束读取，避免在 EOF 比较前串接加法。
          if (state == ST_STREAM && bus_pos == end_pos_m1_r) begin
            track_end <= 1;
            wav_ready <= 1;
            state <= ST_SEEK;
            action <= LOOP_ON_EOF ? ACT_SEEK : ACT_STOP;
            seek_latched <= data_offset;
          end
        end
        if (state == ST_HDR && !header_bad && !header_complete) begin
          if (hdr_too_long) header_bad <= 1;
          case (hp)
            HP_RIFF: begin
              case (bus_pos)
                0:  if (sd_sec_read_data != "R") header_bad <= 1;
                1:  if (sd_sec_read_data != "I") header_bad <= 1;
                2:  if (sd_sec_read_data != "F") header_bad <= 1;
                3:  if (sd_sec_read_data != "F") header_bad <= 1;
                4:  riff_length[7:0] <= sd_sec_read_data;
                5:  riff_length[15:8] <= sd_sec_read_data;
                6:  riff_length[23:16] <= sd_sec_read_data;
                7:  riff_length[31:24] <= sd_sec_read_data;
                8:  if (sd_sec_read_data != "W") header_bad <= 1;
                9:  if (sd_sec_read_data != "A") header_bad <= 1;
                10: if (sd_sec_read_data != "V") header_bad <= 1;
                11: begin
                  if (sd_sec_read_data != "E" || riff_length > 32'hfffffff7) header_bad <= 1;
                  hp <= HP_TAG;
                  field_index <= 0;
                  chunk_id <= 0;
                end
              endcase
            end
            HP_TAG: begin
              chunk_id <= {sd_sec_read_data, chunk_id[31:8]};
              field_index <= field_index + 1'b1;
              if (field_index == 3) begin
                hp <= HP_LEN;
                chunk_len <= 0;
              end
            end
            HP_LEN: begin
              chunk_len   <= length_now;
              field_index <= field_index + 1'b1;
              if (field_index == 3) begin
                payload_index <= 0;
                if (chunk_id == 32'h61746164) begin  // "data"
                  // 使用扩展位宽检查块长度与 RIFF 边界，避免溢出后误接受非法数据块。
                  if (!fmt_seen || !format_ok || length_now == 0 || (|length_now[31:28]) ||
                      (length_now & ((new_channels == 2) ? 32'd3 : 32'd1)) != 0 ||
                      chunk_offset_bad || ({1'b0, length_now} > chunk_available))
                    header_bad <= 1;
                  else begin
                    new_size <= length_now;
                    new_offset <= chunk_payload_offset[31:0];
                    header_complete <= 1;
                  end
                end else if (length_now > MAX_HEADER_BYTES ||
                             (chunk_id == 32'h20746d66 && length_now < 16))
                  header_bad <= 1;
                else if (length_now == 0) begin
                  hp <= HP_TAG;
                  chunk_id <= 0;
                end else begin
                  payload_left <= length_now + length_now[0];
                  hp <= HP_PAYLOAD;
                end
              end
            end
            HP_PAYLOAD: begin
              if (chunk_id == 32'h20746d66 && payload_index < chunk_len) begin  // "fmt "
                case (payload_index)
                  0:  new_format[7:0] <= sd_sec_read_data;
                  1:  new_format[15:8] <= sd_sec_read_data;
                  2:  new_channels[7:0] <= sd_sec_read_data;
                  3:  new_channels[15:8] <= sd_sec_read_data;
                  4:  new_rate[7:0] <= sd_sec_read_data;
                  5:  new_rate[15:8] <= sd_sec_read_data;
                  6:  new_rate[23:16] <= sd_sec_read_data;
                  7:  new_rate[31:24] <= sd_sec_read_data;
                  12: new_align[7:0] <= sd_sec_read_data;
                  13: new_align[15:8] <= sd_sec_read_data;
                  14: new_bits[7:0] <= sd_sec_read_data;
                  15: new_bits[15:8] <= sd_sec_read_data;
                endcase
                if (payload_index + 1'b1 == chunk_len) fmt_seen <= 1;
              end
              payload_index <= payload_index + 1'b1;
              payload_left  <= payload_left - 1'b1;
              if (payload_left == 1) begin
                hp <= HP_TAG;
                field_index <= 0;
                chunk_id <= 0;
              end
            end
          endcase
        end
      end

      if ((sd_sec_read_end || orphan_timeout) && inflight) begin
        sd_sec_read <= 0;
        inflight <= 0;
        request_gap <= BUS_SETTLE;
        if (state == ST_HDR) begin
          if (header_complete && !header_bad) begin
            state  <= ST_SEEK;
            action <= ACT_START;
          end else if (header_bad || hdr_too_long) begin
            if (scanning && wav_sector < scan_max_sector &&
                (BLIND_SCAN_LIMIT == 0 || wav_sector < scan_stop_m1)) begin
              wav_sector <= wav_sector + 1'b1;
              sd_sec_read_addr <= wav_sector + 1'b1;
              bus_pos <= 0;
              hp <= HP_RIFF;
              header_bad <= 0;
              header_complete <= 0;
              fmt_seen <= 0;
              field_index <= 0;
              chunk_id <= 0;
              chunk_len <= 0;
              riff_length <= 0;
              new_format <= 0;
              new_channels <= 0;
              new_rate <= 0;
              new_bits <= 0;
              new_align <= 0;
            end else begin
              state <= ST_SEEK;
              action <= ACT_STOP;
              track_bad <= 1;
              wav_ready <= 0;
            end
          end else sd_sec_read_addr <= wav_sector + {23'd0, bus_pos[31:9]};
        end else if (state == ST_STREAM) sd_sec_read_addr <= wav_sector + {23'd0, bus_pos[31:9]};
      end

      if (!inflight && request_gap == 0 && format_settle == 0 &&
          ((state == ST_HDR && !header_complete && !header_bad) ||
           (state == ST_STREAM && !pause && !fifo_almost_full_q && bus_pos < end_pos) ||
           (state == ST_SEEK && partial_frame && old_tail))) begin
        sd_sec_read <= 1;
        inflight <= 1;
        wait_count <= 0;
        timeout_reported <= 0;
        if (state == ST_SEEK) sd_sec_read_addr <= wav_sector + {23'd0, bus_pos[31:9]};
      end

      // Never withdraw ownership mid-sector: dropping even one PCM byte
      // shifts every following 16-bit sample. The response pipeline can
      // deliver data/end one clock after grant falls, so those also reset
      // the orphan timer. Recovery uses the normal completion path above
      // to advance the address after a lost end, rather than replaying it.
      if (!inflight || sd_grant || sd_sec_read_data_valid || sd_sec_read_end) begin
        inflight_wd <= 16'd0;
        inflight_expired <= 0;
      end else begin
        if (inflight_wd != INFLIGHT_WD_MAX) inflight_wd <= inflight_wd + 16'd1;
        // Mirrors the saturated counter on this same edge, so timeout
        // observation stays aligned with the control event while limiting fanout.
        inflight_expired <= (inflight_wd >= INFLIGHT_WD_MAX - 1);
      end

      // 跳转等待超时后恢复控制流程，防止失去扇区完成响应而永久等待。
      if (state != ST_SEEK) seek_stay_cnt <= 24'd0;
      else if (seek_stay_cnt != SEEK_STAY_MAX) seek_stay_cnt <= seek_stay_cnt + 24'd1;

      seek_stay_timeout <= (state == ST_SEEK) && (seek_stay_cnt >= SEEK_STAY_MAX);

      if (state == ST_SEEK && !inflight && (!partial_frame || seek_stay_timeout) &&
          (fifo_drained || seek_stay_timeout) && request_gap == 0 &&
          (!(seek_q && action == ACT_SEEK) || seek_stay_timeout)) begin
        case (action)
          ACT_SELECT: begin
            wav_sector <= pending_sector;
            sd_sec_read_addr <= pending_sector;
            scanning <= pending_scan;
            bus_pos <= 0;
            hp <= HP_RIFF;
            header_bad <= 0;
            header_complete <= 0;
            fmt_seen <= 0;
            field_index <= 0;
            chunk_id <= 0;
            chunk_len <= 0;
            riff_length <= 0;
            payload_left <= 0;
            payload_index <= 0;
            new_format <= 0;
            new_channels <= 0;
            new_rate <= 0;
            new_bits <= 0;
            new_align <= 0;
            // Previous format is held until all old PCM samples drain.
            end_pos <= 0;
            pcm_out_cnt <= 0;
            wav_ready <= 0;
            state <= ST_HDR;
          end
          ACT_START: begin
            // ACT_START is entered only after header_complete && !header_bad.
            // format_ok has already checked 48000 Hz / 16 bit / mono or stereo.
            // Publish the validated constants, allowing downstream arithmetic
            // to simplify without changing any accepted PCM format.
            sample_rate <= 32'd48000;
            channels <= (new_channels == 16'd2) ? 16'd2 : 16'd1;
            bit_depth <= 16'd16;
            data_size <= new_size;
            data_offset <= new_offset;
            end_pos <= new_offset + new_size;
            wanted <= new_offset;
            bus_pos <= {new_offset[31:9], 9'd0};
            pcm_out_cnt <= 0;
            sd_sec_read_addr <= wav_sector + {23'd0, new_offset[31:9]};
            scanning <= 0;
            state <= ST_STREAM;
            wav_ready <= 1;
            format_settle <= 7'd64;
          end
          ACT_SEEK: begin
            wanted <= seek_latched;
            bus_pos <= {seek_latched[31:9], 9'd0};
            pcm_out_cnt <= seek_latched - data_offset;
            sd_sec_read_addr <= wav_sector + {23'd0, seek_latched[31:9]};
            state <= ST_STREAM;
            wav_ready <= 1;
            format_settle <= 7'd64;
          end
          ACT_STOP: state <= ST_IDLE;
        endcase
      end

      // New selections have highest priority. Repeated selections during a
      // drain replace the pending destination; the active address stays put.
      if (track_sel_q || scan_start_q) begin
        pending_sector <= track_sel_q ? track_sel_sector : scan_start_sector;
        pending_scan <= !track_sel_q;
        scan_stop <= scan_start_sector + BLIND_SCAN_LIMIT;
        action <= ACT_SELECT;
        state <= ST_SEEK;
        wav_ready <= 0;
      end else if (seek_q && state == ST_STREAM && end_pos != 0) begin
        seek_latched <= seek_target;
        action <= ACT_SEEK;
        state <= ST_SEEK;
        wav_ready <= 0;
      end else if (seek_q && state == ST_SEEK && action == ACT_SEEK) begin
        seek_latched <= repeat_target;
      end
    end
  end
endmodule

module wav_player_shim (
  input  wire        clk,
  input  wire        rst,
  input  wire        scan_start,
  input  wire [31:0] scan_start_sector,
  input  wire [31:0] scan_max_sector,
  input  wire        sd_init_done,
  output wire        wav_ready,
  output wire        dbg_pcm_start_odd,
  output wire [31:0] dbg_pcm_sum32,
  output wire [31:0] dbg_pcm_n32,
  output wire [31:0] sample_rate,
  output wire [15:0] channels,
  output wire [15:0] bit_depth,
  output wire [31:0] data_size,
  output wire [31:0] pcm_out_cnt,
  output wire        sd_sec_read,
  output wire [31:0] sd_sec_read_addr,
  input  wire [ 7:0] sd_sec_read_data,
  input  wire        sd_sec_read_data_valid,
  input  wire        sd_sec_read_end,
  input  wire        fifo_almost_full,
  input  wire        fifo_drained, sd_grant,
  input  wire        pause,
  input  wire        seek,
  input  wire [31:0] step_bytes,
  input  wire        track_sel,
  input  wire [31:0] track_sel_sector,
  output wire        track_end,
  output wire        track_bad,
  output wire        pcm_valid,
  output wire [ 7:0] pcm_data,
  output wire [ 2:0] dbg_state,
  output wire        dbg_gate_open,           // 透传内部 gate_open
  output wire [ 7:0] dbg_fp,
  output wire        dbg_silent_hit,
  output wire        dbg_posbad_hit,
  output wire        dbg_seek_data_ok,
  output wire        dbg_wp_pcm_seen,
  output wire        dbg_wp_pcm_recent,
  output wire        dbg_wp_gate_stuck,
  output wire        dbg_hdr_phase,
  output wire [ 1:0] dbg_fbcnt_frz,
  output wire        dbg_seek_drain,
  output wire        dbg_resync_pulse
);

  // 内部 wav_player 的观测输出（只连 dbg_state 的有效 3 位）
  wire [3:0] core_dbg_state;
  wav_player #(
    .LOOP_ON_EOF(1'b0)
  ) u_core (
    .clk                   (clk),
    .rst                   (rst),
    .scan_start            (scan_start),
    .scan_start_sector     (scan_start_sector),
    .scan_max_sector       (scan_max_sector),
    .sd_init_done          (sd_init_done),
    .track_sel             (track_sel),
    .track_sel_sector      (track_sel_sector),
    .wav_ready             (wav_ready),
    .sample_rate           (sample_rate),
    .channels              (channels),
    .bit_depth             (bit_depth),
    .data_size             (data_size),
    .pcm_out_cnt           (pcm_out_cnt),
    .sd_sec_read           (sd_sec_read),
    .sd_sec_read_addr      (sd_sec_read_addr),
    .sd_sec_read_data      (sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end       (sd_sec_read_end),
    .fifo_almost_full      (fifo_almost_full),
    .fifo_drained          (fifo_drained),
    .sd_grant              (sd_grant),
    .pause                 (pause),
    .seek                  (seek),
    .step_bytes            (step_bytes),
    .track_end             (track_end),
    .track_bad             (track_bad),
    .pcm_valid             (pcm_valid),
    .pcm_data              (pcm_data),
    .dbg_state             (core_dbg_state),
    .dbg_gate_open         (dbg_gate_open)
  );

  // 真实观测：只保留设计真正提供的那一位
  assign dbg_state         = core_dbg_state[2:0];

  // 以下兼容观测端口输出常量，不代表实时采样结果。
  //   用寄存器驱动，复位后恒定（避免未寄存/悬空 ）
  assign dbg_pcm_start_odd = 1'b0;
  assign dbg_pcm_sum32     = 32'd0;
  assign dbg_pcm_n32       = 32'd0;
  assign dbg_fp            = 8'd0;
  assign dbg_silent_hit    = 1'b0;
  assign dbg_posbad_hit    = 1'b0;
  assign dbg_fbcnt_frz     = 2'd0;

  assign dbg_seek_data_ok  = 1'b0;
  assign dbg_wp_pcm_seen   = 1'b0;
  assign dbg_wp_pcm_recent = 1'b0;
  assign dbg_wp_gate_stuck = 1'b0;
  assign dbg_hdr_phase     = 1'b0;
  assign dbg_seek_drain    = 1'b0;
  assign dbg_resync_pulse  = 1'b0;

endmodule
