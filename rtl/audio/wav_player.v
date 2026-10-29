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

  // [Design note 时序 F2]scan_stop 的 "-1" 预寄存。
  //   F1 之后 WNS 只剩 -94 ps / 25 个端点，其中 15 个全在这一族：
  //       wav_sector → (+1) → (比 scan_stop) → CE        ← 3 级 + 一条 32 位比较
  //   判据 "wav_sector+1 < scan_stop" 精确等价于 "wav_sector < scan_stop-1"，
  //   而 scan_stop 只在 scan_start 时装载一次（下面第 389 行），所以把
  //   scan_stop-1 一起寄存，比较器前面就少了一个 32 位加法器。
  //   scan_stop = scan_start_sector + 4096 >= 4096，减 1 不会退化成负数；
  //   BLIND_SCAN_LIMIT==0 时这条判据本来就被短路，不受影响。
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
  // ================================================================
  // [Design note 时序]把三个"控制事件"输入就地打一拍。
  //   seek / track_sel / scan_start 由 u_button_ctrl / u_track_ctrl 产生，
  //   它们在芯片另一侧，实测最差路径是
  //       u_button_ctrl/ff_tick_reg -> ... 6 级 LUT ... -> chunk_len[*].ce
  //   而 0 级那一段网线就占 2.03 ns（跨 20 行布局）。在本模块入口打一拍，
  //   发射点就落到这个锥体旁边的触发器上，那 2.0 ns 的跨片网线消失。
  //   三者都是"脉冲/电平事件"，本模块内所有使用点统一延后一拍，
  //   相对时序完全不变（状态机看到的仍是同一个脉冲，只晚 10 ns）。
  //   复位时清零，与原值一致。
  // ================================================================
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
  // ================================================================
  // 2026-10-13 TIMING FIX (merged): precompute the seek constants
  //   Worst sd_card_clk path (delay 12.216 ns, logic level 11,
  //   requirement 10 ns, SWNS -2.496 ns) ran:
  //     channels -> step_bytes -> (data_offset + pcm_out_cnt + step_bytes)
  //              -> compare end_pos -> subtract data_offset -> mask -> add
  //   data_offset, step_bytes (from channels) and frame_mask are all FIXED
  //   once the header is parsed, so their combination can be precomputed
  //   and held.  The live path then reduces to a single add of pcm_out_cnt.
  //   Revert: delete these two registers and use data_offset+step_bytes
  //   and ~frame_mask directly again.
  // ================================================================
  reg [31:0] seek_base_r;  // data_offset + step_bytes
  reg [31:0] frame_mask_n_r;  // ~frame_mask  (mask off sub-frame bytes)
  // [Design note 时序 F1]step_bytes 打一拍。
  //   它来自顶层的组合三目 ((wav_channels==2) ? 1920000 : 960000)，
  //   跨模块长线 + 2 级 LUT 直接串进 seek/repeat 的 6 加法器锥里
  //   （E1 里那条 level 11 的最差路径，起点的前 2.8 ns 全是这一段）。
  //   在模块入口寄存后，发射点落到本模块内。
  //   等价性：step_bytes 只在 ACT_START 之后被用到，而 channels 更在之后才变，
  //   晚一拍取到的永远是同一个值（帧稳定量）。
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

  // ====================================================================
  // [Design note 时序 F1]seek/repeat 的目标偏移，去掉一次 32 位减 + 一次 32 位加。
  //
  //   原式（两条）：
  //       T = data_offset + ((sum - data_offset) & frame_mask_n_r)
  //   展开：frame_mask_n_r 只清掉最低 1~2 位，所以
  //       (sum - D) & M = (sum - D) - ((sum - D) & ~M)
  //       T = D + (sum - D) - ((sum - D) & ~M) = sum - ((sum - D) & ~M)
  //   而 (sum-D) 的"低位"只看 sum[1:0]-D[1:0]（模 4 运算，不涉及高位借位），
  //   于是 ~M 只取最低 2 位即可：
  //       low = (sum[1:0] - D[1:0]) & ~M[1:0]        ← 2 位减法，代价可忽略
  //       T   = sum[31:0] - {30'd0, low}              ← 被减数只有 2 位有效
  //   逐位等价（已用 D=100/101/103, sum=107/108/110, 单声道与立体声交叉验证）。
  //   实测这段在 E1 里是 level 11 / ADDER=6 的最差族（-0.344）。
  //
  //   前提：sum >= D 恒成立（sum = pcm_out_cnt + D + step_bytes，两项都非负，
  //   step_bytes >= 960000），所以原式的 32 位减法不会回绕、新式也无需处理借位。
  // ====================================================================
  wire [1:0] seek_low = (seek_sum_p[1:0] - data_offset[1:0]) & ~frame_mask_n_r[1:0];
  wire [31:0] seek_target = (seek_sum_p[32] || seek_sum_p >= {1'b0, end_pos}) ?
      data_offset : (seek_sum_p[31:0] - {30'd0, seek_low});
  wire [32:0] repeat_sum = {1'b0, seek_latched} + {1'b0, step_bytes_r};
  // [Design note 时序]这里原来用组合的 ~frame_mask（= channels==2 的比较），
  //   于是 channels_reg[4] 成了 30 个违例端点的发射点。frame_mask_n_r 是
  //   同一个值的寄存版，而且 repeat_target 只在 ACT_SEEK 时使用，
  //   那条路径必经 ST_STREAM（头部已解析 ⇒ frame_mask_n_r 已装载），
  //   复位值 0xFFFFFFFE 也与 channels=0/1 时的 ~frame_mask 相同。
  //   同一个代数化简见上面的 seek_target（这里把 sum 换成 repeat_sum，其余相同）。
  wire [1:0] rep_low = (repeat_sum[1:0] - data_offset[1:0]) & ~frame_mask_n_r[1:0];
  wire [31:0] repeat_target = (repeat_sum[32] || repeat_sum >= {1'b0, end_pos}) ?
      data_offset : (repeat_sum[31:0] - {30'd0, rep_low});
  // [Design note 时序]riff 的"合法长度上界"= riff_length + 8，原来是每次
  //   判断都重算的一条加法，且直接串在 new_offset/new_size 的写使能锥里
  //   （38 个违例端点，9 级 ADDER=6）。riff_length 在头部第 4..7 字节就定下来，
  //   判据只在 HP_LEN 结束那一拍用，所以把它做成寄存器，等价且不占路径。
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
  // [Design note 时序]MAX_HEADER_BYTES = 65536 = 2^16，所以
  //   "bus_pos >= 65536" 精确等价于 "bus_pos[31:16] 非零"（16 输入 NOR，2 级 LUT），
  //   不再是一条 32 位减法借位链。参数若改成非 2 的幂，自动退回比较（下面的三目在
  //   MAX_HEADER_BYTES 是 localparam 时会被常量折叠，不产生任何硬件）。
  wire hdr_too_long = (MAX_HEADER_BYTES == 32'd65536) ?
      (|bus_pos[31:16]) : (bus_pos >= MAX_HEADER_BYTES);
  // [Design note 时序]end_pos-1 预寄存（end_pos 每首只装载一次，见 ACT_START/ACT_SELECT）。
  //   用途：把 "bus_pos+1 == end_pos" 改写成 "bus_pos == end_pos-1"，
  //   从 EOF 判定路径上拿掉一个 32 位加法器。它只在 bus_pos 走完整个文件后才可能相等，
  //   而 end_pos 装载后要几百万拍才会到，所以这一级 1 拍的延迟完全无害；
  //   复位值 32'd0 - 1 = 0xFFFF_FFFF，bus_pos 永远到不了，不会误触发。
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
          // [Design note 时序]原来写的是 bus_pos+1'b1==end_pos —— 一个 32 位加法
          //   + 32 位相等比较，起于 bus_pos（每字节都变），实测是 action/*.ce 与
          //   bus_pos_b1 那条 9 级锥的一段。end_pos 每首只装载一次，所以把
          //   end_pos-1 预寄存，这里只做一次 32 位相等比较（无加法）。
          //   等价：bus_pos+1 == end_pos  ⟺  bus_pos == end_pos-1（无符号整数）。
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
                  // ============================================================
                  // [Design note 时序 v2]这一段是 D1 之后唯一的最差族
                  //   （65 个端点全由 bus_pos 发出，9 级 / ADDER=5）：
                  //     bus_pos → (+1) → (+length_now) → (比 riff_limit) → OR → CE
                  //   三处等价改写把加法器从 5 个砍到 2 个：
                  //
                  //   ① length_now>32'h0fffffff  ⟺  |length_now[31:28]
                  //      （常数比较 → 4 输入 NOR，不再占减法链）
                  //   ② length_now > riff_limit - (bus_pos+1)
                  //      ⟺ length_now + bus_pos + 1 > riff_limit
                  //      ⟺ length_now + bus_pos >= riff_limit      ← 少一个 +1
                  //      两式都是 33 位无符号精确算术（length_now<=0x0fffffff、
                  //      bus_pos<=65536），不会溢出。原式在
                  //      bus_pos+1 > riff_limit 时会回绕，但那时③已经单独置了
                  //      header_bad，最终 OR 结果不变。
                  //   ③ bus_pos+1 > riff_limit  ⟺  bus_pos >= riff_limit
                  //
                  //   新的一串：bus_pos → (+length_now) → (>= riff_limit_r) → OR
                  // ============================================================
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
        // observation retains its original cycle while reducing fanout.
        inflight_expired <= (inflight_wd >= INFLIGHT_WD_MAX - 1);
      end

      // ====================================================================
      // [Design note ST_SEEK 停留超时超时恢复 修"播几分钟后音乐永久停止"]
      //
      //   上板数码管读数 212122 解码（seg_data_0 = 最左）：
      //     d0 = 2  => wav_dbg_state = 2 = ST_STREAM（播放器看起来"正常"）
      //     d2 = 2  => {wav_ready, video_play} = 10（wav_ready=1）
      //     d3 = 1, d4 = 2  => sd_state = 5'b10001 = 17 = S_WAIT_READ_WRITE
      //   => SD 侧空等"新请求"，播放器侧空等"数据" => 双方互锁 
      //
      //   根因：ST_SEEK 的放行条件依赖 fifo_drained，而它是顶层算出来的
      //         `fifo_empty && (builder_idle || empty_cnt==EMPTY_HOLD)`。
      //         一旦异步 FIFO 的 empty 标志不一致（写侧近满/读侧认空这类
      //         经典 CDC 问题），fifo_empty 会长期为 0 => fifo_drained 恒 0
      //         => ST_SEEK 永远出不去。按切歌能恢复，因为 track_sel 走了
      //         另一条 ACT_SELECT 通路。
      //
      //   修法：在 ST_SEEK 停留超过 100 ms 就强制放行（丢掉最多 100 ms 音频，
      //         换来整机不卡死）。这是"保命"不是"优化"：正常一次 seek 只要
      //         几微秒，100 ms 有 1 万倍余量，正常路径绝不会误触发 
      // ====================================================================
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
  output wire        dbg_gate_open,           // [Design note]透传内部 gate_open
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

  // 以下均为【常量桩】—— 不是真实观测（旧 reader 的探针，本设计不再提供）
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
