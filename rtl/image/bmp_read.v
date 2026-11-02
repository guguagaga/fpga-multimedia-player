// BMP header and pixel-stream reader.
module bmp_read #(
  parameter [31:0] SCAN_INIT_BUDGET = 32'd6000,
  // FRAME_WORDS 定义完整输出帧字数；有效像素不足时补黑至该边界。
  parameter [31:0] FRAME_WORDS      = 32'd307200,
  parameter        SCALING_EN       = 1'b0,
  parameter        FAST_ROW_EN      = 1'b1
) (
  input  wire load_abort,
  input  wire sd_error,
  input  wire sd_grant,
  input       clk,
  input       rst,
  output      ready,

  // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
  input             scan_start,
  input             scan_abort,
  input      [31:0] scan_start_sector,
  input      [31:0] scan_max_sector,
  input      [ 2:0] scan_target_count,
  input             scan_limited,
  input      [31:0] scan_start_sector2,
  input             scan_start2,
  output reg        scan_done,
  output reg        scan_found_valid,
  output reg [31:0] scan_found_sector,
  output reg [ 2:0] scan_found_total,

  // 按指定扇区加载一张图到 SDRAM
  input        load_start,
  input [31:0] load_sector,

  input             sd_init_done,
  output reg [ 3:0] state_code,
  input      [15:0] bmp_width,
  input      [15:0] bmp_height,

  output reg write_req,
  input      write_req_ack,
  input      write_almost_full,

  output reg        sd_sec_read,
  output reg [31:0] sd_sec_read_addr,
  input      [ 7:0] sd_sec_read_data,
  input             sd_sec_read_data_valid,
  input             sd_sec_read_end,

  output wire        bmp_data_wr_en,
  output wire [23:0] bmp_data,

  // 本次校验通过并正在装载的源图高度
  //   （取自 BMP 头）。写侧用它算 VFLIP 起始 (H-1)*640，把图顶到内存行 0..H-1。
  //   整帧期间稳定；H = FRAME_HEIGHT 时写侧行为与改动前逐位相同。
  output wire [15:0] img_h_o,
  output wire        source_top_down,
  output reg         load_error,
  output wire [15:0] img_w_o,
  output reg [15:0] aspect_h_o,

  output wire [31:0] scan_sector_o
);

  localparam ST_IDLE = 6'b000001;
  localparam ST_SCAN = 6'b000010;
  // Recover a lost client end pulse only AFTER all 512 bytes were received
  // and the arbiter released ownership. Never time out an active SD transfer.
  reg [9:0] sector_bytes;
  reg [15:0] end_wait;
  wire recovered_end = sd_sec_read && (end_wait == 16'd59999);
  wire sector_end = sd_sec_read_end || recovered_end;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      sector_bytes <= 0;
      end_wait <= 0;
    end else begin
      if (!sd_sec_read) sector_bytes <= 0;
      else if (sd_sec_read_data_valid && sector_bytes < 512) sector_bytes <= sector_bytes + 1'b1;
      if (!sd_sec_read || sd_grant !== 1'b0 || sd_sec_read_data_valid || sd_sec_read_end ||
          sector_bytes != 512)
        end_wait <= 0;
      else if (!recovered_end) end_wait <= end_wait + 1'b1;
    end
  end
  localparam ST_LOAD_HDR  = 6'b000100;
  localparam ST_LOAD_WAIT = 6'b001000;
  localparam ST_LOAD_DATA = 6'b010000;
  // 补黑阶段：像素流发完后，用本地节拍器继续发 32'd0，
  //   直到本帧总字数恰好 FRAME_WORDS(=307200)。H=480 时补黑 0 字、该状态永不进入
  //   ⇒ 与改动前逐位相同。
  localparam ST_FILL      = 6'b100000;

  reg [5:0] state;
  reg [9:0] rd_cnt;
  // A byte-qualified one-hot header capture isolates the FSM fanout from
  // 24 header-byte clock enables. Last relevant field is byte33; decisions
  // occur at sector end after byte511. Field availability shifts by one
  // cycle; SD transactions and payload pixel timing are unchanged.
  reg [33:0] header_select_q;
  reg [7:0] header_data_q;
  integer header_i;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      header_select_q <= 0;
      header_data_q   <= 0;
    end else begin
      header_data_q <= sd_sec_read_data;
      for (header_i = 0; header_i < 34; header_i = header_i + 1)
      header_select_q[header_i] <= ((state == ST_SCAN) || (state == ST_LOAD_HDR)) &&
          sd_sec_read_data_valid && (rd_cnt == header_i);
    end
  end
  reg [31:0] image_pixels;
  reg [31:0] width;
  reg [31:0] height;
  // QOI integration: one full sector is buffered before decoding. A RUN can
  // expand one byte to 62 pixels; SD transactions cannot be backpressured.
  reg [31:0] q_magic, q_width, q_height;
  reg [7:0] q_channels, q_colorspace;
  reg is_qoi;
  always @(posedge clk or posedge rst) begin
    if (rst) is_qoi <= 0;
    else is_qoi <= (q_magic == 32'h716f6966);
  end
  reg fast_rows;
  reg [15:0] meta_h, meta_w;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      meta_h <= 0;
      aspect_h_o <= 0;
      meta_w <= 0;
    end else begin
      meta_h <= is_qoi ? q_height[15:0] : (fast_rows ? 16'd480 : height[15:0]);
      aspect_h_o <= is_qoi ? q_height[15:0] : height[15:0];
      meta_w <= is_qoi ? q_width[15:0] : width[15:0];
    end
  end
  assign source_top_down = is_qoi;
  // All fields complete by byte33; decisions occur after byte511.
  // Width, height and format checks are independent register stages, so
  // a32-bit bound comparator cannot feed an entire header-wide AND tree.
  reg q_width_ok_q, q_height_ok_q, q_format_ok_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      q_width_ok_q  <= 0;
      q_height_ok_q <= 0;
      q_format_ok_q <= 0;
    end else begin
      q_width_ok_q  <= q_width >= (SCALING_EN ? 32'd1 : {16'd0,bmp_width}) && q_width <= 4096;
      q_height_ok_q <= q_height >= 1 && q_height <= 4096 && (SCALING_EN || q_height <= bmp_height);
      q_format_ok_q <= is_qoi && (q_channels == 3 || q_channels == 4) && q_colorspace <= 1;
    end
  end
  wire q_header_match = q_width_ok_q && q_height_ok_q && q_format_ok_q;
  reg bmp_pixel_wr_en;
  reg [23:0] bmp_pixel_data;
  wire q_done, q_error, q_byte_ready, q_pixel_valid;
  wire [23:0] q_pixel;
  wire q_pixel_ready = (state == ST_LOAD_DATA) && is_qoi && !write_almost_full;
  assign bmp_data_wr_en = is_qoi ? (q_pixel_valid && q_pixel_ready) : bmp_pixel_wr_en;
  assign bmp_data = is_qoi ? q_pixel : bmp_pixel_data;
  reg [7:0] q_buf[0:511];
  reg [7:0] q_mem_q, q_byte;
  reg q_have, q_pending, q_valid;
  reg [9:0] q_pos;
  wire q_start = (state == ST_LOAD_WAIT) && write_req_ack && is_qoi;
  // The decoder clears its index for 64 clocks before accepting bytes.
  // Register the writer-ack decode so it does not fan out combinationally
  // into all QOI pixel/state registers. The sector buffer retains bytes
  // until din_ready; abort/reset cancels a pending start.
  reg q_start_q;
  always @(posedge clk or posedge rst) begin
    if (rst) q_start_q <= 1'b0;
    else if (load_start || load_abort || !sd_init_done) q_start_q <= 1'b0;
    else q_start_q <= q_start;
  end
  reg [31:0] q_byte_limit;
  always @(posedge clk) begin
    q_mem_q <= q_buf[q_pos[8:0]];
    if (state == ST_LOAD_DATA && is_qoi && sd_sec_read_data_valid)
      q_buf[sector_bytes[8:0]] <= sd_sec_read_data;
    q_byte_limit <= (image_pixels << 2) + image_pixels + 32'd22;
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      q_magic <= 0;
      q_width <= 0;
      q_height <= 0;
      q_channels <= 0;
      q_colorspace <= 0;
    end else begin
      if (header_select_q[0]) q_magic <= {24'd0, header_data_q};
      else if (|header_select_q[3:1]) q_magic <= {q_magic[23:0], header_data_q};
      if (header_select_q[4]) q_width <= {24'd0, header_data_q};
      else if (|header_select_q[7:5]) q_width <= {q_width[23:0], header_data_q};
      if (header_select_q[8]) q_height <= {24'd0, header_data_q};
      else if (|header_select_q[11:9]) q_height <= {q_height[23:0], header_data_q};
      if (header_select_q[12]) q_channels <= header_data_q;
      if (header_select_q[13]) q_colorspace <= header_data_q;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      q_have <= 0;
      q_pending <= 0;
      q_valid <= 0;
      q_pos <= 0;
      q_byte <= 0;
    end else if (load_start || load_abort || !sd_init_done) begin
      q_have <= 0;
      q_pending <= 0;
      q_valid <= 0;
      q_pos <= 0;
    end else begin
      if (state == ST_LOAD_DATA && is_qoi && sector_end) begin
        q_have <= 1;
        q_pos  <= 0;
      end
      if (q_have && !q_pending && !q_valid && q_pos < 512) begin
        q_pending <= 1;
        q_pos <= q_pos + 1'b1;
      end
      if (q_pending) begin
        q_byte <= q_mem_q;
        q_valid <= 1;
        q_pending <= 0;
      end
      if (q_valid && q_byte_ready) q_valid <= 0;
      if (q_have && q_pos == 512 && !q_pending && !q_valid) q_have <= 0;
    end
  end
  qoi_stream #(
    .EXTERNAL_PIXELS(1'b1),
    .BRAM32_INDEX(2)
  ) u_qoi (
    .clk            (clk),
    .rst            (rst || load_abort || !sd_init_done),
    .start          (q_start_q),
    .din            (q_byte),
    .din_valid      (q_valid),
    .din_ready      (q_byte_ready),
    .pixel          (q_pixel),
    .expected_pixels(image_pixels[24:0]),
    .pixel_valid    (q_pixel_valid),
    .pixel_ready    (q_pixel_ready),
    .done           (q_done),
    .error          (q_error),
    .width          (),
    .height         ()
  );




  reg [ 7:0] header_0;
  reg [ 7:0] header_1;
  reg [31:0] file_len;
  reg [31:0] pixel_offset;


  reg [15:0] bit_count;
  reg [31:0] compression;

  reg [31:0] scan_sector;
  // phase A 的扇区预算计数
  reg [31:0] scan_budget_cnt;
  reg [31:0] load_sector_latched;
  reg [ 2:0] scan_target_latched;

  localparam [31:0] WR_TOTAL_LIMIT = SCALING_EN ? 32'd16777216 : FRAME_WORDS;
  reg [22:0] wr_total;

  // 扫描进度输出（给顶层做 LOADING 等待画面）
  assign scan_sector_o = scan_sector;
  // 把头部解析出的高度给写侧用
  assign img_h_o       = meta_h;
  assign img_w_o       = meta_w;
  reg [13:0] fast_row_bytes;
  reg [15:0] fast_step_bytes;
  // Fast offsets fit 25 bits: pixel_offset < 64 KiB and the largest
  // accepted source is 4096*1920*3 bytes (< 24 MiB). Unusual headers
  // with larger pixel offsets retain the original full-stream fallback.
  reg [24:0] fast_start, fast_end, fast_next;
  reg [31:0] fast_lba;
  // Header fields settle before header-end; row lookahead settles during
  // the current row. Keep the address adder outside the request/state mux.
  always @(posedge clk or posedge rst) begin
    if (rst) fast_lba <= 0;
    else
      fast_lba <= load_sector_latched +
          ((state == ST_LOAD_HDR) ? {9'd0, pixel_offset[31:9]} : {16'd0, fast_next[24:9]});
  end
  reg [ 8:0] fast_row;
  reg [31:0] bmp_len_cnt;
  reg [ 2:0] bmp_retire_pipe;
  reg bmp_retire_q, bmp_retire_fast_q, bmp_retire_last_q;
  reg bmp_retire_eof_q, bmp_retire_full_q;
  // QOI must decode the entire buffered sector before requesting another.
  // At !q_have/!q_pending/!q_valid, bmp_len_cnt has been stable for many
  // clocks. Register its byte-limit comparison before the request-enable
  // cone; the in-flight sector and byte counters are never interrupted.
  reg q_limit_hit_q;
  reg [15:0] q_limit_parts;
  always @(posedge clk or posedge rst) begin
    if (rst) begin q_limit_hit_q <= 0; q_limit_parts <= 0; end
    else begin
      // The sector counter is stable while QOI drains its buffered bytes.
      // Resolve the limit before requesting another sector, using the same
      // grouped comparator as the existing BMP retirement pipeline.
      q_limit_parts <= compare_groups(bmp_len_cnt, q_byte_limit);
      q_limit_hit_q <= !merge_less(q_limit_parts);
    end
  end
  // Sector retirement has a three-cycle byte drain. Compute wide
  // EOF/row bounds in two stages during that drain; the final byte count
  // is visible to the partial stage one clock after sector_end, and to
  // the merged predicate one further clock later, before retirement.
  reg [15:0] retire_eof_parts, retire_fast_parts;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      retire_eof_parts  <= 0;
      retire_fast_parts <= 0;
    end else begin
      retire_eof_parts  <= compare_groups(bmp_len_cnt, file_len);
      retire_fast_parts <= compare_groups(bmp_len_cnt, {7'd0, fast_end});
    end
  end
  // Header classification settles hundreds of byte clocks before payload.
  // Keep each wide predicate in its own stage, rather than sharing its
  // reduction with fast_rows and stride mux enables in one clock.
  reg fast_width_ok_q, fast_offset_ok_q, fast_height2_q, fast_height3_q, fast_height4_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      fast_width_ok_q  <= 0;
      fast_offset_ok_q <= 0;
      fast_height2_q   <= 0;
      fast_height3_q   <= 0;
      fast_height4_q   <= 0;
    end else begin
      fast_width_ok_q  <= width[1:0] == 0 && width >= 640 && width <= 4096;
      fast_offset_ok_q <= pixel_offset[31:16] == 0;
      fast_height2_q   <= height == 960;
      fast_height3_q   <= height == 1440;
      fast_height4_q   <= height == 1920;
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      fast_rows <= 0;
      fast_row_bytes <= 0;
      fast_step_bytes <= 0;
    end else begin
      fast_rows <= FAST_ROW_EN && SCALING_EN && !is_qoi && fast_width_ok_q && fast_offset_ok_q &&
          (fast_height2_q || fast_height3_q || fast_height4_q);
      fast_row_bytes <= {1'b0, width[12:0]} + {width[12:0], 1'b0};
      if (fast_height2_q) fast_step_bytes <= {1'b0, fast_row_bytes, 1'b0};
      else if (fast_height3_q)
        fast_step_bytes <= {2'b0, fast_row_bytes} + {1'b0, fast_row_bytes, 1'b0};
      else fast_step_bytes <= {fast_row_bytes, 2'b0};
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      fast_start <= 0;
      fast_end   <= 0;
      fast_next  <= 0;
      fast_row   <= 0;
    end else begin
      // Pipelined lookahead settles during the header/ack and each row.
      fast_end  <= fast_start + {11'd0, fast_row_bytes};
      fast_next <= fast_start + {9'd0, fast_step_bytes};
      if (state != ST_LOAD_DATA) begin
        fast_start <= pixel_offset[24:0];
        fast_row   <= 0;
      end else if (bmp_retire_q && bmp_retire_fast_q && !bmp_retire_last_q) begin
        fast_start <= fast_next;
        fast_row   <= fast_row + 1'b1;
      end
    end
  end
  // Retire a completed BMP sector on the following clock. The byte
  // parser/counter stays in LOAD_DATA throughout, so RGB bytes spanning
  // sector boundaries and skipped-row state are preserved. No next request
  // can issue during this pending decision. QOI handshakes are unchanged.
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bmp_retire_pipe <= 0;
      bmp_retire_q <= 0;
      bmp_retire_fast_q <= 0;
      bmp_retire_last_q <= 0;
      bmp_retire_eof_q <= 0;
      bmp_retire_full_q <= 0;
    end else begin
      // A byte may coincide with sector_end. First drain the registered byte,
      // then sample the committed pixel count, then retire the sector.
      bmp_retire_pipe <= {bmp_retire_pipe[1:0], (state == ST_LOAD_DATA) && !is_qoi && sector_end};
      bmp_retire_q <= bmp_retire_pipe[2];
      bmp_retire_fast_q <= fast_rows && !(merge_less(retire_fast_parts));
      bmp_retire_last_q <= fast_row == 479;
      bmp_retire_eof_q <= !(merge_less(retire_eof_parts));
      bmp_retire_full_q <= wr_total >= FRAME_WORDS;
    end
  end
  reg [1:0] bmp_byte_idx;

  wire header_match;
  wire bmp_data_valid;
  wire [31:0] file_sector_count;
  wire [31:0] next_scan_sector_if_match;
  wire [31:0] next_scan_sector_if_miss;
  // Header fields are complete by byte 33; header decisions occur only after
  // the 512-byte sector ends. Compute the image bounds in advance, rather
  // than putting multiply/add/compare in every pixel's 100 MHz enable path.
  // Three pipeline stages settle long before ST_LOAD_DATA can be entered.

  // Header geometry settles hundreds of byte clocks before any pixel load.
  // Select the source dimensions BEFORE the product, allowing one shared
  // DSP instead of parallel BMP/QOI products plus a32-bit result mux.
  reg [15:0] source_width_q, source_height_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      source_width_q  <= 0;
      source_height_q <= 0;
    end else begin
      source_width_q  <= is_qoi ? q_width[15:0] : width[15:0];
      source_height_q <= is_qoi ? q_height[15:0] : height[15:0];
    end
  end
  // 24-bit BMP scanlines are padded to a four-byte boundary.
  // width mod 4 equals the number of padding bytes for RGB888.
  reg [17:0] padding_bytes;
  always @(posedge clk) begin
    case (source_width_q[1:0])
      0: padding_bytes <= 0;
      1: padding_bytes <= {2'd0,source_height_q};
      2: padding_bytes <= {1'd0,source_height_q,1'b0};
      3: padding_bytes <= {2'd0,source_height_q}+{1'd0,source_height_q,1'b0};
    endcase
  end
  reg [31:0] pixel_bytes;
  always @(posedge clk) pixel_bytes <= image_pixels * 32'd3;
  reg [31:0] image_bytes;
  reg [31:0] image_end;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      image_pixels <= 32'd0;
      image_bytes <= 32'd0;
      image_end <= 32'd0;
    end else begin
      image_pixels <= source_width_q * source_height_q;
      image_bytes <= pixel_bytes + {14'd0,padding_bytes};
      image_end <= pixel_offset + image_bytes;
    end
  end

  assign ready = (state == ST_IDLE);
  reg [31:0] header_payload_bytes;
  reg header_length_ok;
  // The header is stable well before sector_end. Compare byte lanes first,
  // then combine their registered results, avoiding one32-bit LUT chain.
  reg [3:0] header_len_gt, header_len_eq;
  integer header_lane;
  always @(posedge clk or posedge rst) begin
    if(rst) begin header_len_gt<=0;header_len_eq<=0;end
    else for(header_lane=0;header_lane<4;header_lane=header_lane+1)begin
      header_len_gt[header_lane]<=file_len[header_lane*8+:8]>pixel_offset[header_lane*8+:8];
      header_len_eq[header_lane]<=file_len[header_lane*8+:8]==pixel_offset[header_lane*8+:8];
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      header_payload_bytes <= 0;
      header_length_ok <= 0;
    end else begin
      header_payload_bytes <= file_len - pixel_offset;
      header_length_ok <= header_len_gt[3] || (header_len_eq[3] &&
          (header_len_gt[2] || (header_len_eq[2] &&
          (header_len_gt[1] || (header_len_eq[1] &&
          (header_len_gt[0] || header_len_eq[0]))))));
    end
  end
  reg header_ok_r;
  always @(posedge clk or posedge rst) begin
    if (rst) header_ok_r <= 1'b0;
    else header_ok_r <= header_match;
  end
  wire bmp_header_match;
  assign header_match = q_header_match || bmp_header_match;
  reg bmp_width_ok_q, bmp_height_ok_q, bmp_format_ok_q, bmp_payload_ok_q;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bmp_width_ok_q   <= 0;
      bmp_height_ok_q  <= 0;
      bmp_format_ok_q  <= 0;
      bmp_payload_ok_q <= 0;
    end else begin
      bmp_width_ok_q <= width >= (SCALING_EN ? 32'd1 : {16'd0,bmp_width}) && width <= 32'd4096;
      bmp_height_ok_q <= height >= 32'd1 &&
          (SCALING_EN ? height <= 32'd4096 : height <= {16'd0, bmp_height});
      bmp_format_ok_q <= header_0 == "B" && header_1 == "M" && bit_count == 16'd24 &&
          compression == 32'd0;
      bmp_payload_ok_q <= pixel_offset >= 32'd54 && header_length_ok &&
          header_payload_bytes >= image_bytes;
    end
  end
  assign
      bmp_header_match = bmp_width_ok_q && bmp_height_ok_q && bmp_format_ok_q && bmp_payload_ok_q;
  // Two-stage unsigned range comparisons. Partial comparisons, byte,
  // valid and fast-row selection all refer to the same input clock.
  // One extra byte pipeline stage is paired with one extra sector drain stage.
  reg [7:0] bmp_input_byte_q, bmp_input_byte_s1;
  reg bmp_input_valid_q, bmp_input_valid_s1, bmp_fast_s1;
  reg bmp_after_offset_q, bmp_before_end_q, bmp_after_fast_q, bmp_before_fast_q, bmp_fast_q;
  reg [15:0] cmp_offset_s1, cmp_end_s1, cmp_fast_start_s1, cmp_fast_end_s1;
  // Register four-bit predicates instead of mapping a 16-bit comparison
  // into TD's long serial LUT chain. The next stage uses a balanced tree.
  function [15:0] compare_groups;
    input [31:0] a, b;
    integer n;
    begin
      for (n = 0; n < 8; n = n + 1) begin
        compare_groups[2*n+1] = (a[n*4+:4] < b[n*4+:4]);
        compare_groups[2*n]   = (a[n*4+:4] == b[n*4+:4]);
      end
    end
  endfunction
  function [1:0] join_compare;
    input [1:0] hi, lo;
    begin
      join_compare = {hi[1] || (hi[0] && lo[1]), hi[0] && lo[0]};
    end
  endfunction
  function merge_less;
    input [15:0] p;
    reg [1:0] a, b, c, d, e, f, g;
    begin
      a = join_compare(p[15:14], p[13:12]);
      b = join_compare(p[11:10], p[9:8]);
      c = join_compare(p[7:6], p[5:4]);
      d = join_compare(p[3:2], p[1:0]);
      e = join_compare(a, b);
      f = join_compare(c, d);
      g = join_compare(e, f);
      merge_less = g[1];
    end
  endfunction
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bmp_input_byte_q <= 0;
      bmp_input_byte_s1 <= 0;
      bmp_input_valid_q <= 0;
      bmp_input_valid_s1 <= 0;
      bmp_fast_s1 <= 0;
      cmp_offset_s1 <= 0;
      cmp_end_s1 <= 0;
      cmp_fast_start_s1 <= 0;
      cmp_fast_end_s1 <= 0;
      bmp_after_offset_q <= 0;
      bmp_before_end_q <= 0;
      bmp_after_fast_q <= 0;
      bmp_before_fast_q <= 0;
      bmp_fast_q <= 0;
    end else begin
      bmp_input_byte_s1 <= sd_sec_read_data;
      bmp_input_valid_s1 <= (state == ST_LOAD_DATA) && !is_qoi && sd_sec_read_data_valid;
      bmp_fast_s1 <= fast_rows;
      cmp_offset_s1 <= compare_groups(bmp_len_cnt, pixel_offset);
      cmp_end_s1 <= compare_groups(bmp_len_cnt, image_end);
      cmp_fast_start_s1 <= compare_groups(bmp_len_cnt, {7'd0, fast_start});
      cmp_fast_end_s1 <= compare_groups(bmp_len_cnt, {7'd0, fast_end});
      bmp_input_byte_q <= bmp_input_byte_s1;
      bmp_input_valid_q <= bmp_input_valid_s1;
      bmp_fast_q <= bmp_fast_s1;
      bmp_after_offset_q <= !(merge_less(cmp_offset_s1));
      bmp_before_end_q <= merge_less(cmp_end_s1);
      bmp_after_fast_q <= !(merge_less(cmp_fast_start_s1));
      bmp_before_fast_q <= merge_less(cmp_fast_end_s1);
    end
  end
  wire bmp_stream_byte_valid = bmp_input_valid_q && bmp_after_offset_q && bmp_before_end_q &&
      (!bmp_fast_q || (bmp_after_fast_q && bmp_before_fast_q)) &&
      (SCALING_EN ? 1'b1 : (wr_total < FRAME_WORDS));
  reg [12:0] row_pixel;
  reg [1:0] padding_left;
  assign bmp_data_valid = bmp_stream_byte_valid && padding_left == 0;
  always @(posedge clk or posedge rst) begin
    if (rst) begin row_pixel <= 0; padding_left <= 0; end
    else if (state != ST_LOAD_DATA) begin row_pixel <= 0; padding_left <= 0; end
    else if (bmp_stream_byte_valid) begin
      if (padding_left != 0) padding_left <= padding_left - 1'b1;
      else if (bmp_byte_idx == 2) begin
        if (row_pixel == source_width_q[12:0]-1'b1) begin
          row_pixel <= 0;
          padding_left <= source_width_q[1:0];
        end else row_pixel <= row_pixel + 1'b1;
      end
    end
  end
  assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
  assign next_scan_sector_if_match = scan_sector + 32'd1;
  assign next_scan_sector_if_miss = scan_sector + 32'd1;

  // 预算计数器：每读完一个扇区 +1，只在受限扫描（phase A）时使用
  wire scan_budget_hit = scan_limited && (scan_budget_cnt + 32'd1 >= SCAN_INIT_BUDGET) &&
      (sector_end == 1'b1);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
      if (sd_sec_read_data_valid) rd_cnt <= rd_cnt + 10'd1;
      else if (sector_end) rd_cnt <= 10'd0;
    end else begin
      rd_cnt <= 10'd0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      header_0     <= 8'd0;
      header_1     <= 8'd0;
      file_len     <= 32'd0;
      pixel_offset <= 32'd54;
      width        <= 32'd0;
      height       <= 32'd0;
      bit_count    <= 16'd0;
      compression  <= 32'd0;
    end else begin
      if (header_select_q[0]) header_0 <= header_data_q;
      if (header_select_q[1]) header_1 <= header_data_q;
      if (header_select_q[2]) file_len[7:0] <= header_data_q;
      if (header_select_q[3]) file_len[15:8] <= header_data_q;
      if (header_select_q[4]) file_len[23:16] <= header_data_q;
      if (header_select_q[5]) file_len[31:24] <= header_data_q;
      if (header_select_q[10]) pixel_offset[7:0] <= header_data_q;
      if (header_select_q[11]) pixel_offset[15:8] <= header_data_q;
      if (header_select_q[12]) pixel_offset[23:16] <= header_data_q;
      if (header_select_q[13]) pixel_offset[31:24] <= header_data_q;
      if (header_select_q[18]) width[7:0] <= header_data_q;
      if (header_select_q[19]) width[15:8] <= header_data_q;
      if (header_select_q[20]) width[23:16] <= header_data_q;
      if (header_select_q[21]) width[31:24] <= header_data_q;
      if (header_select_q[22]) height[7:0] <= header_data_q;
      if (header_select_q[23]) height[15:8] <= header_data_q;
      if (header_select_q[24]) height[23:16] <= header_data_q;
      if (header_select_q[25]) height[31:24] <= header_data_q;
      if (header_select_q[28]) bit_count[7:0] <= header_data_q;
      if (header_select_q[29]) bit_count[15:8] <= header_data_q;
      if (header_select_q[30]) compression[7:0] <= header_data_q;
      if (header_select_q[31]) compression[15:8] <= header_data_q;
      if (header_select_q[32]) compression[23:16] <= header_data_q;
      if (header_select_q[33]) compression[31:24] <= header_data_q;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_WAIT && fast_rows) begin
      bmp_len_cnt <= {pixel_offset[31:9], 9'd0};
    end else if (state == ST_LOAD_DATA) begin
      if (bmp_retire_q && bmp_retire_fast_q && !bmp_retire_last_q)
        bmp_len_cnt <= {7'd0, fast_next[24:9], 9'd0};
      else if (sd_sec_read_data_valid) bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
      bmp_len_cnt <= 32'd0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
      if (bmp_data_valid) bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
      bmp_byte_idx <= 2'd0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      bmp_pixel_wr_en <= 1'b0;
      bmp_pixel_data  <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
      if (bmp_data_valid) begin
        case (bmp_byte_idx)
          2'd0: begin
            bmp_pixel_wr_en <= 1'b0;
            bmp_pixel_data[7:0] <= bmp_input_byte_q;
          end
          2'd1: begin
            bmp_pixel_wr_en <= 1'b0;
            bmp_pixel_data[15:8] <= bmp_input_byte_q;
          end
          2'd2: begin
            bmp_pixel_wr_en <= 1'b1;
            bmp_pixel_data[23:16] <= bmp_input_byte_q;
          end
          default: begin
            bmp_pixel_wr_en <= 1'b0;
          end
        endcase
      end else begin
        bmp_pixel_wr_en <= 1'b0;
      end
    end else if (state == ST_FILL) begin
      // 本地节拍器：每拍发一个黑字（32'd0），
      //   直到本帧总字数恰好 FRAME_WORDS。冒烟条件在 wr_total 里，
      //   这里只要在 ST_FILL 就一直发（退出由状态机负责）。
      //   ⚠️ bmp_pixel_wr_en 是寄存器：如果在"决定退出"那一拍仍然拉高，
      //      它会在下一拍（已经回 ST_IDLE）多产生 1 个写脉冲 ⇒ 多写 1 字。
      //      所以这里必须用 wr_total 把关，退出拍不发。
      // 退出条件必须始终是 FRAME_WORDS：
      //   ST_FILL 的职责就是"把帧补满到 307200"，与源图多大无关。
      //   若跟着 WR_TOTAL_LIMIT 走，缩放模式下 wr_total 永远到不了
      //   FRAME_WORDS，而 ST_FILL 又不涨计数器 ⇒ 永远出不去，整机挂死。
      if (wr_total >= FRAME_WORDS || write_almost_full) begin
        bmp_pixel_wr_en <= 1'b0;
      end else begin
        bmp_pixel_wr_en <= 1'b1;
        bmp_pixel_data  <= 24'd0;
      end
    end else begin
      bmp_pixel_wr_en <= 1'b0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      wr_total <= 23'd0;
    end else if (!sd_init_done || ((state == ST_IDLE) && load_start)) begin
      wr_total <= 23'd0;
    end else if (state == ST_LOAD_DATA) begin
      if (bmp_data_valid && (bmp_byte_idx == 2'd2)) wr_total <= wr_total + 23'd1;
    end else if ((state == ST_FILL) && (wr_total < WR_TOTAL_LIMIT) && !write_almost_full) begin
      wr_total <= wr_total + 23'd1;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state               <= ST_IDLE;
      load_error          <= 0;
      state_code          <= 4'd0;
      sd_sec_read         <= 1'b0;
      sd_sec_read_addr    <= 32'd0;
      write_req           <= 1'b0;
      scan_done           <= 1'b0;
      scan_found_valid    <= 1'b0;
      scan_found_sector   <= 32'd0;
      scan_found_total    <= 3'd0;
      scan_sector         <= 32'd0;
      scan_budget_cnt     <= 32'd0;
      load_sector_latched <= 32'd0;
      scan_target_latched <= 3'd0;
    end else if (!sd_init_done) begin
      state               <= ST_IDLE;
      load_error          <= 0;
      state_code          <= 4'd0;
      sd_sec_read         <= 1'b0;
      sd_sec_read_addr    <= 32'd0;
      write_req           <= 1'b0;
      scan_done           <= 1'b0;
      scan_found_valid    <= 1'b0;
      scan_found_sector   <= 32'd0;
      scan_found_total    <= 3'd0;
      scan_sector         <= 32'd0;
      scan_budget_cnt     <= 32'd0;
      load_sector_latched <= 32'd0;
      scan_target_latched <= 3'd0;
    end else begin
      scan_found_valid <= 1'b0;

      case (state)
        ST_IDLE: begin
          state_code  <= 4'd1;
          sd_sec_read <= 1'b0;
          write_req   <= 1'b0;

          if (scan_start || scan_start2) begin
            scan_target_latched <= scan_target_count;
            scan_done           <= 1'b0;
            scan_found_total    <= 3'd0;
            // 选起点：phase A 用 scan_start_sector，
            //   phase B（scan_start2，由顶层接上 scan_sector_o）用
            //   scan_start_sector2，这样后台扫描从 phase A 停下的
            //   位置继续，而不是从头再扫一遍。
            scan_sector         <= scan_start2 ? scan_start_sector2 : scan_start_sector;
            scan_budget_cnt     <= 32'd0;  // 预算重新起算
            sd_sec_read_addr    <= scan_start2 ? scan_start_sector2 : scan_start_sector;
            state               <= ST_SCAN;
          end else if (load_start) begin
            load_sector_latched <= load_sector;
            load_error          <= 0;
            sd_sec_read_addr    <= load_sector;
            state               <= ST_LOAD_HDR;
          end
        end

        ST_SCAN: begin
          state_code  <= 4'd2;
          sd_sec_read <= 1'b1;

          if (sector_end) begin
            sd_sec_read <= 1'b0;
            // 预算计数（只有 phase A 受限扫描才用）
            if (scan_limited && !scan_budget_hit) scan_budget_cnt <= scan_budget_cnt + 32'd1;

            if (header_ok_r) begin
              scan_found_valid  <= 1'b1;
              scan_found_sector <= scan_sector;
              scan_found_total  <= scan_found_total + 3'd1;
              // 只有"非受限"（phase B 后台）才允许因凑满 target 提前结束。
              // phase A 必须只由预算/范围决定何时结束，否则若顶层把
              // scan_target_count 传小，phase A 会提前收工、后面的图丢失。
              if (scan_found_total + 3'd1 >= scan_target_latched) begin
                scan_done        <= 1'b1;
                state            <= ST_IDLE;
                sd_sec_read_addr <= next_scan_sector_if_match;
                scan_sector      <= next_scan_sector_if_match;
              end else if ((next_scan_sector_if_match > scan_max_sector) || scan_budget_hit) begin
                scan_done        <= 1'b1;
                state            <= ST_IDLE;
                sd_sec_read_addr <= next_scan_sector_if_match;
                scan_sector      <= next_scan_sector_if_match;
              end else begin
                sd_sec_read_addr <= next_scan_sector_if_match;
                scan_sector      <= next_scan_sector_if_match;
              end
            end else begin
              if ((scan_sector >= scan_max_sector) ||
                  (next_scan_sector_if_miss > scan_max_sector) || scan_budget_hit) begin
                scan_done <= 1'b1;
                state     <= ST_IDLE;
              end else begin
                sd_sec_read_addr <= next_scan_sector_if_miss;
                scan_sector      <= next_scan_sector_if_miss;
              end
            end
            // Pause a background scan only at a sector boundary. Keep
            // the next sector so the top can resume after an image load.
            if (scan_abort) begin
              scan_done <= 1'b1;
              state <= ST_IDLE;
              scan_sector <= scan_sector + 32'd1;
              sd_sec_read_addr <= scan_sector + 32'd1;
            end
          end
        end

        ST_LOAD_HDR: begin
          state_code  <= 4'd5;
          sd_sec_read <= 1'b1;

          if (sector_end) begin
            sd_sec_read <= 1'b0;
            if (header_ok_r) begin
              write_req        <= 1'b1;
              sd_sec_read_addr <= fast_rows ? fast_lba : load_sector_latched;
              state            <= ST_LOAD_WAIT;
            end else begin
              state <= ST_IDLE;
            end
          end
        end

        ST_LOAD_WAIT: begin
          state_code <= 4'd3;
          if (write_req_ack) begin
            write_req <= 1'b0;
            state     <= ST_LOAD_DATA;
          end
        end

        ST_LOAD_DATA: begin
          state_code <= 4'd4;
          if (is_qoi) begin
            if (!sd_sec_read && !q_have && !q_pending && !q_valid && !q_done && !q_error) begin
              if (q_limit_hit_q) begin
                load_error <= 1;
                state <= ST_IDLE;
              end else sd_sec_read <= 1;
            end
            if (sector_end) begin
              sd_sec_read <= 0;
              sd_sec_read_addr <= sd_sec_read_addr + 1'b1;
            end
            // A registered start clears the previous decoder result on this
            // edge; do not terminate the new file using the old done/error.
            if ((q_done || q_error) && !sd_sec_read && !q_start_q) begin
              load_error <= q_error;
              state <= ST_IDLE;
            end
          end else begin
            // Leave >=256 words free for an indivisible 512-byte sector
            // (at most 171 pixels). Never interrupt an existing request.
            if (!(bmp_retire_q || |bmp_retire_pipe) && (!write_almost_full || sd_sec_read))
              sd_sec_read <= 1'b1;
            else sd_sec_read <= 1'b0;

            if (sector_end) sd_sec_read <= 1'b0;
            if (bmp_retire_q) begin
              sd_sec_read <= 1'b0;
              if (bmp_retire_fast_q) begin
                if (bmp_retire_last_q) state <= ST_IDLE;
                else sd_sec_read_addr <= fast_lba;
              end else if (bmp_retire_eof_q) begin
                // 像素流发完了，但本帧
                //   还没写满 FRAME_WORDS ⇒ 进 ST_FILL 补黑；
                //   H=480 时 wr_total 已经等于 FRAME_WORDS ⇒ 直接收尾，
                //   与改动前逐拍相同 
                if (SCALING_EN || bmp_retire_full_q) state <= ST_IDLE;
                else state <= ST_FILL;
              end else begin
                sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
              end
            end
          end
        end

        // ---- 补黑阶段 ----
        //   不再请求 SD 扇区（数据已经拿全了），只用本地节拍器把黑字发到写侧，
        //   直到本帧恰好 FRAME_WORDS 个字。
        //   退出即回 ST_IDLE，总字数恰好 FRAME_WORDS（不是"至少"）。
        ST_FILL: begin
          state_code  <= 4'd6;  // 新增观测码（DIG5 可读）
          sd_sec_read <= 1'b0;
          write_req   <= 1'b0;
          if (wr_total >= FRAME_WORDS) state <= ST_IDLE;
        end

        default: begin
          state       <= ST_IDLE;
          state_code  <= 4'd1;
          sd_sec_read <= 1'b0;
          write_req   <= 1'b0;
        end
      endcase
      if (load_abort === 1'b1) begin
        if (state == ST_LOAD_WAIT || state == ST_FILL ||
            ((state == ST_LOAD_HDR || state == ST_LOAD_DATA) && (!sd_sec_read || sector_end))) begin
          state <= ST_IDLE;
          sd_sec_read <= 0;
          write_req <= 0;
        end
      end
      // The mapper owns the failed sector and has already retired it.
      // Discard this incomplete frame; never publish fabricated pixels.
      if (sd_error === 1'b1) begin
        state <= ST_IDLE;
        sd_sec_read <= 0;
        write_req <= 0;
        load_error <= 1;
      end

    end
  end

endmodule
