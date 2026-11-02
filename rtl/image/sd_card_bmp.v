// 图片读取、后台预取、轮播计时与显示缓冲交接控制。
// 来源于官方 lab_ex5_i2s 示例；通过扇区接口与音频共用 SD 仲裁器。
// 预取将下一张写入空闲缓冲，完成后等待显示提交边界再切换。
// 新图片就绪后请求淡出，收到显示域确认再交接缓冲所有权。
// 视频占用、转场锁和写侧背压共同限制新装载，避免并发覆盖。
module sd_card_bmp #(
  parameter                DIRECTORY_IMAGES  = 1,
  parameter                STREAM_IMAGES     = 0,
  parameter                ENABLE_ZOOM       = 0,
  parameter integer        CLK_FREQ_HZ       = 100_000_000,
  parameter         [31:0] SCAN_MAX_SECTOR   = 32'd131071,
  parameter         [ 2:0] SCAN_TARGET_COUNT = 3'd4,
  parameter         [31:0] SCAN_INIT_BUDGET  = 32'd6000,
  parameter         [31:0] LOAD_WAIT_MAX     = 32'd200000000,
  // 首图/转场握手超时恢复门槛（单位 = 4096 拍）。
  //   默认 97656 -> 97656 x 4096 / 100MHz ≈ 4.0s（一次正常加载约 0.30s）。
  //   放在参数表里是为了 TB 能传一个很小的值来快速验证超时恢复路径。
  parameter         [16:0] TO_TICKS          = 17'd97656,
  parameter         [31:0] FRAME_WORDS       = 32'd307200
) (
  input             clk,
  input             rst,
  input wire stream_valid,
  input wire [31:0] stream_lba,
  output wire stream_consume,
  output wire stream_failed,
  input      [ 3:0] directory_count,
  input      [31:0] directory0, directory1, directory2, directory3,
  input      [31:0] directory4, directory5, directory6, directory7,
  input             key_next,
  input             zoom_small,
  input             key_auto,         // KEY4 短按 = 轮播 开/关
  // 轮播周期由扩展板 4 位拨码 exp_sw[3:0] 选择。
  //   period_code     : 当前已生效的档位码 0..15（由 carousel_period_cfg 在
  //                     显示发布边界上锁存）—— 只用于数码管显示。
  //   auto_period_sec : 当前已生效的周期秒数 2..600（同上锁存）。
  //   计时器仍在本模块内：auto_tick = 1 s 的 tick 数秒 + 10 位饱和计数器，
  //   不会回绕、不会出现 0 秒周期（预设表里没有 0）。
  input      [ 3:0] period_code,
  input      [ 9:0] auto_period_sec,
  // 键盘 D 单击：立即重开计时并打开轮播。
  //   不再循环档位（档位已由拨码决定），从当前图片重新计时。
  input             period_reseed,
  output     [ 3:0] state_code,
  input      [15:0] bmp_width,
  input      [15:0] bmp_height,
  output reg        display_valid,
  output            img_loading,      // 1 = image load in progress (for SD arbiter priority)

  // 扫描进度（扇区号），给顶层做开机 LOADING 等待画面
  output [31:0] scan_sector,
  output [ 3:0] found_count_o,
  output        scan_done_o,
  output [ 3:0] auto_mode_o,     // 显示用：0=关，否则 = 完整 4 位档位码 0..F
  // 轮播关闭或新帧发布时允许周期配置生效，避免改变当前显示周期。
  output        cfg_boundary_o,
  // 轮播开关本身（扩展板 595 面板显示 'A' / '-'）
  output        auto_on_o,

  input [31:0] scan_start_sector,

  input [31:0] scan_start_sector2,
  input        scan_start2,
  input        scan_limited,

  input            write_finish_toggle,
  output reg [1:0] write_buf_idx,
  output reg [1:0] disp_buf_idx,

  input            switch_lock,
  input            vid_lock,
  output reg       fade_req_toggle,
  input            fade_done_pulse,
  output           firstimg_fallback_o,
  output     [3:0] firstimg_diag_o,

  output             write_req,
  input              write_req_ack,
  input              write_almost_full,
  output             write_en,
  output      [31:0] write_data,
  output      [15:0] img_h_o,
  output wire        source_top_down,

  // ---- SD sector-read interface (to sd_arbiter) ----
  input         sd_init_done,
  input         sd_error,
  output [31:0] file_base_lba,
  output        sd_sec_read,
  output [31:0] sd_sec_read_addr,
  input  [ 7:0] sd_sec_read_data,
  input         sd_sec_read_data_valid,
  input         sd_grant,
  input         sd_sec_read_end
);

  wire        key_next_press;
  wire        key_auto_press;

  wire        bmp_data_wr_en;
  wire [23:0] bmp_data;
  wire        bmp_ready;
  wire        image_load_error;
  wire        bmp_scan_done;
  wire        scan_done;
  wire        scan_found_valid;
  wire [31:0] scan_found_sector;
  wire [ 2:0] scan_found_total;

  reg         scan_start_pulse;
  reg         load_start_pulse;
  reg  [31:0] load_sector;
  reg         scan_kicked;
  reg         first_image_committed;
  reg         auto_on;  // 轮播开关（KEY4 短按 / period_reseed）
  wire [ 3:0] auto_mode;  // 显示用（组合）：关=0，否则 = 档位码 0..F
  reg  [ 9:0] sec_cnt;  // 已计时秒数，饱和在 auto_period_sec
  reg  [31:0] auto_cnt;
  reg  [ 3:0] img_found_count;
  reg  [ 2:0] img_idx;  // 当前真正显示中的图片编号
  // 加载完成与显示发布分别记录；轮播周期以显示发布事件为计时基准。
  reg         load_busy;
  reg         load_busy_q;
  always @(posedge clk or posedge rst) begin
    if (rst) load_busy_q <= 1'b0;
    else load_busy_q <= load_busy;
  end
  wire load_finish = load_busy_q & ~load_busy;

  localparam PREFETCH_EN = 1'b1;  // Prefetch activity is derived from pf_state.
  //   The old pf_mode register could stick at 1 after an aborted prefetch, which made every
  //   later commit take the prefetch branch (no display change) => carousel froze on image 2.
  //   Now "is this load a prefetch" == (pf_state == PF_BUSY), so there is no stale flag.
  localparam [1:0] PF_IDLE = 2'd0, PF_BUSY = 2'd1, PF_DONE = 2'd2;

  reg [1:0] pf_state;
  reg [2:0] pf_idx;  // 预取好的图片编号
  reg [1:0] pf_buf;  // 预取好的 buffer 编号
  reg [2:0] next_target;  // 下一张要显示的图片编号（预计算）
  reg pf_flip_pend;  // 1 = 到点了，等 fade_done 再翻转显示
  reg [2:0] load_idx;  // 当前正在写入的图片编号
  reg [1:0] pending_buf_idx;  // 当前正在写入的目标缓冲区
  reg [31:0] img_sector0;
  reg [31:0] img_sector1;
  reg [31:0] img_sector2;
  reg [31:0] img_sector3;
  reg next_req_pending;
  reg [31:0] load_wait_cnt;

  // bmp_ready 先表示"源文件读取/送 FIFO 完成"；真正切显示要等 write_finish_toggle 同步后
  reg source_done_seen;

  reg fade_req_sent;

  reg wrfin_seen;  // (1) 本帧 write_finish_pulse 已经见过
  // 【首图必出图 超时恢复】共享的"慢速时基"：4096 分频 + 17 位计数（满量程 ≈5.37s）。
  //   面积吃紧（本设计已在 95%~96% mslices），所以两处超时超时恢复共用一个时基，
  //   省掉两个 32 位计数器 —— 上一版就是被那两个计数器顶到 place 96.28%，
  //   导致 route-eco 出 PHY-8023/RUN-8102 布线违例（被 phy 的 bit 时间戳闸门拦下）。
  reg [11:0] to_presc;  // 4096 分频
  reg [16:0] to_cnt;  // 单位 = 4096 拍
  reg first_load_started;  // 首图装载已经发起过（超时恢复窗口的起点）
  reg [3:0] fb_diag;
  reg firstimg_fallback_seen;  // 走过首图超时恢复（引到 DIG3）

  // 4.0s 门槛（97656 x 4096 / 100MHz ≈ 4.000s，见参数表 TO_TICKS）：
  //   远大于一次正常 BMP 加载（1801 扇区 x 25MHz SPI ≈ 164us/扇区 ≈ 0.30s，
  //   SPI_HIGH_SPEED_DIV=0 -> 25MHz，见 SD/sd_card_top.v:25），
  //   也留足"卡住重试"的余量；它只是最后一道保险，正常路径永远不该碰到。
  wire to_tick = (to_presc == 12'd4095);
  reg to_hit;  // Exact terminal predicate, updated with each count/reset.
  reg load_wait_hit;
  // 两处超时恢复的条件互斥（首图阶段 fade_req_sent=0；切图阶段 first_image_committed=1），
  // 所以可以安全共用一个计数窗口。
  //   首图窗口 = "首图装载发起过 且 还没有任何图提交"（跨看门狗重试累计，不看 load_busy 电平）
  wire to_active = (first_load_started && !first_image_committed) ||
      ((load_busy || pf_flip_pend) && fade_req_sent);
  wire firstimg_to = to_active && to_hit && !first_image_committed;  // 首图超时超时恢复
  wire fade_wait_to = to_active && to_hit && fade_req_sent;  // 转场握手超时

  // Publish only after both independently latched completion events arrive.
  // The timeout below is diagnostic; it cannot certify a valid SDRAM frame.
  wire img_frame_ready = wrfin_seen;
  wire img_src_ready = source_done_seen;
  wire firstimg_ready = img_frame_ready && img_src_ready;
  wire commit_now = load_busy &&
      ((firstimg_ready && (!first_image_committed || (PREFETCH_EN && pf_state == PF_BUSY))) ||
       (firstimg_ready && first_image_committed && fade_req_sent &&
        (fade_done_pulse || fade_wait_to)));

  reg pixel_wr_seen;

  // 同步 mem_clk 域的 write_finish_toggle
  reg [2:0] wrfin_tgl_sync;
  wire write_finish_pulse;

  wire auto_tick;
  wire [2:0] next_from_current;

  wire [15:0] img_src_w, img_h_raw, img_aspect_h;
  wire fit_high, fit_overflow;
  wire [23:0] fit_pixel;
  wire fit_valid;
  reg load_zoom_small, display_zoom_small;
  reg reader_high_q;
  always @(posedge clk or posedge rst) begin
    if (rst) reader_high_q <= 1;
    else reader_high_q <= fit_high;
  end
  image_fit_720p #(.ENABLE_ZOOM(ENABLE_ZOOM)) u_image_fit (
    .clk(clk), .rst(rst), .frame_start(load_start_pulse || vid_lock),
    .zoom_small(load_zoom_small),
    .src_w(img_src_w), .src_h(img_h_raw), .aspect_h(img_aspect_h),
    .in_valid(bmp_data_wr_en), .in_pixel(bmp_data),
    .high(fit_high), .overflow(fit_overflow),
    .out_blocked(write_almost_full), .out_valid(fit_valid), .out_pixel(fit_pixel)
  );
  // File identity is independent of pixel scaling. Keep the directory-selected
  // first sector connected to the shared FAT mapper for every image request.
  // load_sector stays stable until this load completes or is drained/aborted.
  assign file_base_lba = load_sector;
  assign img_h_o = 16'd720;
  assign write_en = fit_valid;
  assign write_data = {fit_pixel,8'd0};
  assign scan_done  = DIRECTORY_IMAGES ? scan_kicked : bmp_scan_done;
  assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));

  // ---- 【轮播周期】周期秒数由 carousel_period_cfg 给出；auto_step = 到点换图 ----
  wire auto_run = auto_on;
  assign auto_mode = auto_on ? period_code : 4'd0;  // DIG1 显示：0=关，1..F=档位
  // Thresholds change only on second ticks or configuration boundaries.
  // Clear these flags with every timer reset so a completed event cannot
  // retrigger on stale comparison data. Trigger may move one 100MHz clock.
  reg auto_due_q, auto_half_due_q;
  // A publication is distinct from a completed background read.
  wire image_publish = (commit_now && !(PREFETCH_EN && pf_state == PF_BUSY)) ||
      (PREFETCH_EN && pf_flip_pend && (fade_done_pulse || fade_wait_to));
  // The directory result is a peek, held through prefetch and discarded zoom
  // renders. Advance only when publishing a NEW image or skipping a bad one.
  reg current_sector_valid, load_from_stream, bad_round;
  reg [31:0] current_sector, first_bad_sector;
  reg stream_blocked;
  wire stream_load_error = load_busy && bmp_ready && image_load_error && !load_start_pulse;
  wire stream_skip = STREAM_IMAGES && stream_load_error && load_from_stream;
  wire stream_publish = STREAM_IMAGES && image_publish && load_from_stream && !vid_lock;
  assign stream_consume = sd_init_done && !vid_lock && (stream_skip || stream_publish);
  assign stream_failed = stream_blocked;
  wire next_available = !STREAM_IMAGES || (stream_valid && !stream_blocked &&
      !(bad_round && stream_lba == first_bad_sector) && !stream_consume);
  wire initial_available = !STREAM_IMAGES || current_sector_valid || next_available;
  always @(posedge clk or posedge rst) begin
    if(rst) begin
      current_sector_valid<=0; current_sector<=0;
      bad_round<=0; first_bad_sector<=0; stream_blocked<=0;
    end else if(!sd_init_done) begin
      current_sector_valid<=0; bad_round<=0; stream_blocked<=0;
    end else begin
      if(stream_publish) begin
        current_sector<=load_sector; current_sector_valid<=1;
        bad_round<=0; stream_blocked<=0;
      end
      if(stream_skip) begin
        if(!bad_round) first_bad_sector<=stream_lba;
        bad_round<=1;
      end
      if(bad_round && stream_valid && stream_lba==first_bad_sector) stream_blocked<=1;
    end
  end
  wire timer_control_reset = (key_auto_press || period_reseed) &&
      scan_done && (img_found_count > 3'd1);
  wire requested_small = ENABLE_ZOOM && zoom_small;
  wire zoom_reload = ENABLE_ZOOM && display_valid &&
      (display_zoom_small != requested_small);
  wire zoom_stale_prefetch = ENABLE_ZOOM && (pf_state == PF_DONE) &&
      (load_zoom_small != requested_small);
  wire auto_step = !zoom_reload && !zoom_stale_prefetch && auto_run && auto_due_q && (!image_load_error || STREAM_IMAGES) && !load_busy && !vid_lock &&
      !timer_control_reset && !pf_flip_pend && !switch_lock;  // 到点且当前空闲才换图

  assign next_from_current   = next_index_limited(img_idx, img_found_count);
  assign write_finish_pulse  = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
  assign img_loading         = load_busy || !bmp_ready;
  assign auto_mode_o         = auto_mode;
  // A new preset applies when auto is off or a bank is published.
  // Background read completion and failed loads are not display boundaries.
  assign cfg_boundary_o      = (!auto_on) || image_publish;
  assign auto_on_o           = auto_on;
  // 把"已缓存图片数"和"扫描完成"引给顶层，用于决定 phase B 是否发起
  assign found_count_o       = img_found_count;
  assign scan_done_o         = scan_done;
  assign firstimg_fallback_o = firstimg_fallback_seen;

  key_press_debounce #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .DEBOUNCE_MS(20)
  ) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
  );

  key_press_debounce #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .DEBOUNCE_MS(20)
  ) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
  );

  // Eight directory images; zero/one entry stays at index zero.
  function [2:0] next_index_limited;
    input [2:0] cur;
    input [3:0] count;
    reg [3:0] successor;
    begin
      successor = {1'b0, cur} + 4'd1;
      next_index_limited = (successor >= count) ? 3'd0 : successor[2:0];
    end
  endfunction

  function [31:0] sector_lut;
    input [2:0] idx;
    begin
      if(STREAM_IMAGES) sector_lut = (idx == img_idx && current_sector_valid) ? current_sector : stream_lba;
      else case (idx)
        3'd0: sector_lut = img_sector0;
        3'd1: sector_lut = img_sector1;
        3'd2: sector_lut = img_sector2;
        3'd3: sector_lut = img_sector3;
        3'd4: sector_lut = directory4;
        3'd5: sector_lut = directory5;
        3'd6: sector_lut = directory6;
        3'd7: sector_lut = directory7;
        default: sector_lut = img_sector0;
      endcase
    end
  endfunction

  function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input valid_now;
    begin
      if (!valid_now) next_buf_lut = 2'd0;  // 首图固定写 buffer0
      else if (cur_disp_buf == 2'd0) next_buf_lut = 2'd1;
      else next_buf_lut = 2'd0;
    end
  endfunction

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      wrfin_tgl_sync         <= 3'b000;
      scan_start_pulse       <= 1'b0;
      load_start_pulse       <= 1'b0;
      load_from_stream <= 0;
      load_sector            <= 32'd0;
      scan_kicked            <= 1'b0;
      first_image_committed  <= 1'b0;
      load_zoom_small <= 0;
      display_zoom_small <= 0;
      auto_on                <= 1'b0;
      sec_cnt                <= 10'd0;
      auto_due_q             <= 0;
      auto_half_due_q        <= 0;
      auto_cnt               <= 32'd0;
      // 预取控制状态复位
      pf_state               <= PF_IDLE;
      pf_idx                 <= 2'd0;
      pf_buf                 <= 2'd0;
      next_target            <= 2'd1;  // 首图是 0，下一张从 1 开始
      pf_flip_pend           <= 1'b0;
      img_found_count        <= 3'd0;
      img_idx                <= 2'd0;
      load_idx               <= 2'd0;
      pending_buf_idx        <= 2'd0;
      write_buf_idx          <= 2'd0;
      disp_buf_idx           <= 2'd0;
      img_sector0            <= 32'd0;
      img_sector1            <= 32'd0;
      img_sector2            <= 32'd0;
      img_sector3            <= 32'd0;
      next_req_pending       <= 1'b0;
      load_busy              <= 1'b0;
      pixel_wr_seen          <= 1'b0;
      fade_req_sent          <= 1'b0;
      fade_req_toggle        <= 1'b0;  // 必须复位：video 域靠它的"边沿"识别请求
      wrfin_seen             <= 1'b0;
      to_presc               <= 12'd0;
      to_cnt                 <= 17'd0;
      to_hit                 <= (TO_TICKS == 0);
      first_load_started     <= 1'b0;
      fb_diag                <= 4'd0;
      firstimg_fallback_seen <= 1'b0;
      source_done_seen       <= 1'b0;
      display_valid          <= 1'b0;
      load_wait_cnt          <= 32'd0;
      load_wait_hit          <= (LOAD_WAIT_MAX == 0);
    end else begin
      auto_due_q <= sec_cnt >= auto_period_sec;
      auto_half_due_q <= sec_cnt >= (auto_period_sec >> 1);
      wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};
      scan_start_pulse <= 1'b0;
      load_start_pulse <= 1'b0;

      if (!sd_init_done) begin
        scan_kicked            <= 1'b0;
        first_image_committed  <= 1'b0;
        auto_on                <= 1'b0;
        sec_cnt                <= 10'd0;
        auto_due_q             <= 0;
        auto_half_due_q        <= 0;
        auto_cnt               <= 32'd0;
        img_found_count        <= 3'd0;
        img_idx                <= 2'd0;
        load_idx               <= 2'd0;
        pending_buf_idx        <= 2'd0;
        write_buf_idx          <= 2'd0;
        disp_buf_idx           <= 2'd0;
        img_sector0            <= 32'd0;
        img_sector1            <= 32'd0;
        img_sector2            <= 32'd0;
        img_sector3            <= 32'd0;
        next_req_pending       <= 1'b0;
        load_busy              <= 1'b0;
        pixel_wr_seen          <= 1'b0;
        fade_req_sent          <= 1'b0;
        fade_req_toggle        <= 1'b0;
        wrfin_seen             <= 1'b0;
        to_presc               <= 12'd0;
        to_cnt                 <= 17'd0;
        to_hit                 <= (TO_TICKS == 0);
        first_load_started     <= 1'b0;
        fb_diag                <= 4'd0;
        firstimg_fallback_seen <= 1'b0;
        source_done_seen       <= 1'b0;
        display_valid          <= 1'b0;
        load_wait_cnt          <= 32'd0;
        load_wait_hit          <= (LOAD_WAIT_MAX == 0);
      end else begin
        if (load_busy && bmp_ready && !bmp_data_wr_en && !pixel_wr_seen) begin
          if (load_wait_hit) begin
            load_busy     <= 1'b0;
            load_wait_cnt <= 32'd0;
            load_wait_hit <= (LOAD_WAIT_MAX == 0);
            fade_req_sent <= 1'b0;
          end else begin
            load_wait_cnt <= load_wait_cnt + 32'd1;
            load_wait_hit <= load_wait_cnt == (LOAD_WAIT_MAX - 32'd1);
          end
        end else begin
          load_wait_cnt <= 32'd0;
          load_wait_hit <= (LOAD_WAIT_MAX == 0);
        end

        // 扫描阶段缓存前 4 张图的起始 sector
        if (scan_found_valid) begin
          case (img_found_count)
            3'd0: img_sector0 <= scan_found_sector;
            3'd1: img_sector1 <= scan_found_sector;
            3'd2: img_sector2 <= scan_found_sector;
            3'd3: img_sector3 <= scan_found_sector;
            default: ;
          endcase

          if (img_found_count < 3'd4) img_found_count <= img_found_count + 3'd1;
        end

        // Store the source and memory events independently; either
        // arrival order is valid, but both are required before publishing.
        if (load_busy && write_finish_pulse)
          wrfin_seen <= 1'b1;  // (1) 整帧已写进 SDRAM（事件锁存）
        if (bmp_data_wr_en) pixel_wr_seen <= 1'b1;  //   本帧确实在写像素
        if (load_busy && bmp_ready && pixel_wr_seen && !image_load_error)
          source_done_seen <= 1'b1;  // (2) 源图已读完（bmp_read 回 IDLE）

        // ---- 共享超时超时恢复时基（首图超时恢复 / 转场握手超时恢复 共用）----
        //   1024 分频后再计数：每 1024 拍 to_cnt+1，到 TO_TICKS(≈1.0s) 置 to_hit。
        //   计数窗口 = to_active（见上面定义），窗口一关就整体清零。
        if (to_active) begin
          if (to_tick) begin
            to_presc <= 12'd0;
            if (!to_hit) begin
              to_cnt <= to_cnt + 17'd1;
              to_hit <= to_cnt == (TO_TICKS - 17'd1);
            end
          end else begin
            to_presc <= to_presc + 12'd1;
          end
        end else begin
          to_presc <= 12'd0;
          to_cnt   <= 17'd0;
          to_hit   <= (TO_TICKS == 0);
        end

        // 超时恢复标记 + 诊断锁存（正常路径恒 0；上板 DIG3 直接显示 fb_diag 的十六进制位）
        if (load_busy && firstimg_to && !first_image_committed && !firstimg_ready) begin
          firstimg_fallback_seen <= 1'b1;
          fb_diag <= {wrfin_seen, source_done_seen, bmp_ready, pixel_wr_seen};
        end

        // Request fade only after source completion AND SDRAM completion.
        if (load_busy && firstimg_ready && first_image_committed && !fade_req_sent &&
            !(PREFETCH_EN && pf_state == PF_BUSY)) begin
          fade_req_sent   <= 1'b1;
          fade_req_toggle <= ~fade_req_toggle;
        end

        // ===================== 到点翻转显示 =====================
        //   预取就绪后，到点不装载、只翻转 disp_buf_idx。
        //   这里复用同一条 fade 握手：先发 fade_req_toggle，等 fade_done_pulse 再翻。
        if (PREFETCH_EN) begin
          if ((pf_state == PF_BUSY) && !load_busy) begin
            pf_state <= PF_IDLE;
          end
          // A manual next consumes the prepared next image, even if auto
          // has just been disabled. Never schedule a second load of it.
          if (!zoom_reload && !zoom_stale_prefetch && pf_state == PF_DONE && next_req_pending && !pf_flip_pend && !switch_lock &&
              !vid_lock) begin
            pf_flip_pend <= 1;
            next_req_pending <= 0;
          end
          if (pf_flip_pend && !fade_req_sent) begin
            fade_req_sent   <= 1'b1;
            fade_req_toggle <= ~fade_req_toggle;
          end
          if (pf_flip_pend && (fade_done_pulse || fade_wait_to)) begin
            disp_buf_idx     <= pf_buf;
            display_zoom_small <= load_zoom_small;
            img_idx          <= pf_idx;
            next_target      <= next_index_limited(pf_idx, img_found_count);
            pf_state         <= PF_IDLE;
            pf_flip_pend     <= 1'b0;
            next_req_pending <= 0;
            fade_req_sent    <= 1'b0;
            display_valid    <= 1'b1;
          end
        end

        // Discard only a completed, unpublished buffer. Active SD reads and
        // an acknowledged fade must finish their existing handshakes.
        if (ENABLE_ZOOM && pf_state == PF_DONE && !pf_flip_pend &&
            !fade_req_sent && (zoom_reload || zoom_stale_prefetch))
          pf_state <= PF_IDLE;

        // 提交点（唯一一处改 disp_buf_idx）
        if (commit_now) begin
          load_busy        <= 1'b0;
          source_done_seen <= 1'b0;
          pixel_wr_seen    <= 1'b0;
          wrfin_seen       <= 1'b0;
          fade_req_sent    <= 1'b0;
          to_presc         <= 12'd0;
          to_cnt           <= 17'd0;
          to_hit           <= (TO_TICKS == 0);
          // ---- 预取装载不提交显示，只记下"已备好" ----
          // "这次装载是预取吗" = pf_state==PF_BUSY。
          //   不再用独立的 pf_mode 寄存器（它会残留成"永远停第二张"）。
          if (PREFETCH_EN && (pf_state == PF_BUSY)) begin
            pf_state <= PF_DONE;
            pf_idx   <= load_idx;
            pf_buf   <= pending_buf_idx;
            // disp_buf_idx / img_idx 保持不变 —— 这是"后台"装载
          end else begin
            disp_buf_idx <= pending_buf_idx;
            display_zoom_small <= load_zoom_small;
            img_idx      <= load_idx;
            next_target  <= next_index_limited(load_idx, img_found_count);
          end
          display_valid         <= 1'b1;
          first_image_committed <= 1'b1;
        end

        // 上电后自动发起一次"扫描前 4 张 BMP"
        if (!scan_kicked && bmp_ready) begin
          scan_start_pulse      <= !DIRECTORY_IMAGES;
          scan_kicked           <= 1'b1;
          first_image_committed <= 1'b0;
          auto_on               <= 1'b0;
          sec_cnt               <= 10'd0;
          auto_due_q            <= 0;
          auto_half_due_q       <= 0;
          auto_cnt              <= 32'd0;
          img_found_count       <= STREAM_IMAGES ? ((directory_count>1)?4'd2:directory_count) :
                                   (DIRECTORY_IMAGES ? directory_count : 4'd0);
          if (DIRECTORY_IMAGES) begin
            img_sector0 <= directory0;
            img_sector1 <= directory1;
            img_sector2 <= directory2;
            img_sector3 <= directory3;
          end
          img_idx          <= 2'd0;
          load_idx         <= 2'd0;
          pending_buf_idx  <= 2'd0;
          write_buf_idx    <= 2'd0;
          disp_buf_idx     <= 2'd0;
          next_req_pending <= 1'b0;
          display_valid    <= 1'b0;
          load_busy        <= 1'b0;
          pixel_wr_seen    <= 1'b0;
          wrfin_seen       <= 1'b0;
          to_presc         <= 12'd0;
          to_cnt           <= 17'd0;
          to_hit           <= (TO_TICKS == 0);
          fade_req_sent    <= 1'b0;
          source_done_seen <= 1'b0;
        end else begin
          // 忙的时候也只记 1 次"下一张"请求，不会累积成连跳两张
          if (key_next_press && (img_found_count > 3'd0)) next_req_pending <= 1'b1;
          if (auto_step && !image_load_error && first_image_committed &&
              (img_found_count > 3'd1)) begin
            // 到点时：已备好 => 只翻转显示；否则装载完成后切换
            if (PREFETCH_EN && (pf_state == PF_DONE) && !pf_flip_pend) begin
              pf_flip_pend <= 1'b1;
            end else if (!(PREFETCH_EN && ((pf_state != PF_IDLE) || pf_flip_pend))) begin
              next_req_pending <= 1'b1;
            end
            // sec_cnt 的清零必须在下面的计数器块里做：
            //   本 always 块后写优先，写在这里会被计数器覆盖 => sec_cnt 卡在饱和值
            //   => auto_step 恒为 1 => 发出一次请求后就一直 pending => "切一张就停" 
          end

          // KEY4 短按 = 轮播 开/关（不再兼周期，避免与长按切歌混淆）
          if (key_auto_press && scan_done && (img_found_count > 3'd1)) begin
            auto_on <= ~auto_on;
            sec_cnt <= 10'd0;
            auto_due_q <= 0;
            auto_half_due_q <= 0;
            auto_cnt <= 32'd0;
          end
          // 键盘 D 单击 = 打开轮播并从这一张重新计时
          //   （周期档位已经交给扩展板拨码 exp_sw[3:0] 选择，这里不再切档）
          if (period_reseed && scan_done && (img_found_count > 3'd1)) begin
            auto_on <= 1'b1;
            sec_cnt <= 10'd0;
            auto_due_q <= 0;
            auto_half_due_q <= 0;
            auto_cnt <= 32'd0;
          end
          if (auto_run && first_image_committed && (img_found_count > 3'd1)) begin
            // Highest priority inside this last-writer block: explicit
            // restart and display publication clear seconds AND subsecond phase.
            if (timer_control_reset || image_publish) begin
              // Publication is the bank-select event, before the memory
              // scanout adopts it at a frame boundary. Prefetch does not reset.
              sec_cnt <= 10'd0;
              auto_due_q <= 0;
              auto_half_due_q <= 0;
              auto_cnt <= 32'd0;
            end else if (auto_step) begin
              // Disarm this request. Publication resets again, so slow reads
              // cannot shorten the next image's dwell or trigger catch-up.
              sec_cnt <= 10'd0;
              auto_due_q <= 0;
              auto_half_due_q <= 0;
              auto_cnt <= 32'd0;
            end else if (auto_tick) begin
              auto_cnt <= 32'd0;
              if ((sec_cnt + 10'd1) >= auto_period_sec)
                sec_cnt <= auto_period_sec;  // 饱和：到点后停在这里等空闲
              else sec_cnt <= sec_cnt + 10'd1;
            end else begin
              auto_cnt <= auto_cnt + 32'd1;
            end
          end else begin
            auto_cnt <= 32'd0;
            sec_cnt <= 10'd0;
            auto_due_q <= 0;
            auto_half_due_q <= 0;
          end

          if (!vid_lock && !scan_start2 && scan_done && !first_image_committed && bmp_ready &&
              !load_busy && (img_found_count != 3'd0) &&
              (!image_load_error || next_req_pending || STREAM_IMAGES) && initial_available) begin
            load_idx           <= image_load_error ? next_from_current : 2'd0;
            load_sector        <= STREAM_IMAGES ? (current_sector_valid ? current_sector : stream_lba) :
                                  (image_load_error ? sector_lut(next_from_current) : img_sector0);
            pending_buf_idx    <= 2'd0;
            write_buf_idx      <= 2'd0;
            load_zoom_small    <= requested_small;
            load_start_pulse   <= 1'b1;
            load_from_stream <= STREAM_IMAGES && !current_sector_valid;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b1;  // 超时恢复窗口起点（首图）
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            next_req_pending   <= 1'b0;
            auto_cnt           <= 32'd0;
            pf_state           <= PF_IDLE;  // 正常装载：显式回到 IDLE
          end  // 手动下一张优先：写到"非当前显示"的另一块 buffer
          else if (zoom_reload && pf_state == PF_IDLE && !pf_flip_pend &&
                   !scan_start2 && scan_done && bmp_ready && !load_busy &&
                   !switch_lock && !vid_lock &&
                   (!image_load_error || load_zoom_small != requested_small)) begin
            // Re-render the CURRENT image into the non-displayed bank.
            // Keep one queued manual-next request for after this transition.
            load_idx <= img_idx;
            load_sector <= sector_lut(img_idx);
            pending_buf_idx <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx <= next_buf_lut(disp_buf_idx, display_valid);
            load_zoom_small <= requested_small;
            load_start_pulse <= 1'b1;
            load_from_stream <= 0;
            load_busy <= 1'b1;
            pixel_wr_seen <= 0;
            wrfin_seen <= 0;
            source_done_seen <= 0;
            fade_req_sent <= 0;
            first_load_started <= 0;
            pf_state <= PF_IDLE;
            to_presc <= 0;
            to_cnt <= 0;
            to_hit <= (TO_TICKS == 0);
          end
          else if (!(PREFETCH_EN && (pf_state != PF_IDLE)) && !scan_start2 && scan_done &&
                   bmp_ready && display_valid && !load_busy && !switch_lock && !vid_lock &&
                   next_req_pending && next_available && (img_found_count != 3'd0)) begin
            load_idx           <= next_from_current;
            load_sector        <= sector_lut(next_from_current);
            pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
            load_zoom_small    <= requested_small;
            load_start_pulse   <= 1'b1;
            load_from_stream <= STREAM_IMAGES;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b0;  // 切图不改首图窗口
            pf_state           <= PF_IDLE;  // 正常装载：显式回到 IDLE
                                            //   即使上一次预取被中断，也不会残留"预取中"状态
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            next_req_pending   <= 1'b0;
            auto_cnt           <= 32'd0;
          end  // ===================== =====================
          else if (!zoom_reload && next_available && PREFETCH_EN && auto_run && (!image_load_error || STREAM_IMAGES) && (pf_state == PF_IDLE) &&
                   !pf_flip_pend && auto_half_due_q && !scan_start2 && scan_done && bmp_ready &&
                   display_valid && !load_busy && !switch_lock && !vid_lock &&
                   (img_found_count > 3'd1)) begin
            load_idx           <= next_target;
            load_sector        <= sector_lut(next_target);
            pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
            load_zoom_small    <= requested_small;
            load_start_pulse   <= 1'b1;
            load_from_stream <= STREAM_IMAGES;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b0;
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            pf_state           <= PF_BUSY;
          end  // 自动播放下一张：同样写到"非当前显示"的另一块 buffer
               // 预取非空闲时由预取提交路径负责换图，避免重复装载。
          else if (!(PREFETCH_EN && (pf_state != PF_IDLE)) && !scan_start2 && scan_done &&
                   bmp_ready && display_valid && !load_busy && !switch_lock && !vid_lock &&
                   auto_step && next_available && (!image_load_error || STREAM_IMAGES) && (img_found_count > 3'd1)) begin
            load_idx           <= next_from_current;
            load_sector        <= sector_lut(next_from_current);
            pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
            write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
            load_zoom_small    <= requested_small;
            load_start_pulse   <= 1'b1;
            load_from_stream <= STREAM_IMAGES;
            load_busy          <= 1'b1;
            pixel_wr_seen      <= 1'b0;
            wrfin_seen         <= 1'b0;
            to_presc           <= 12'd0;
            to_cnt             <= 17'd0;
            to_hit             <= (TO_TICKS == 0);
            first_load_started <= 1'b0;
            fade_req_sent      <= 1'b0;
            source_done_seen   <= 1'b0;
            auto_cnt           <= 32'd0;
          end
        end
        // The reader clears its previous error when accepting load_start.
        // Do not cancel the fresh request using that stale error on this edge.
        if (load_busy && bmp_ready && image_load_error && !load_start_pulse) begin
          load_busy <= 0;
          pf_state <= PF_IDLE;
          pf_flip_pend <= 0;
          next_req_pending <= STREAM_IMAGES;
          pixel_wr_seen <= 0;
          source_done_seen <= 0;
          wrfin_seen <= 0;
          fade_req_sent <= 0;
          first_load_started <= 0;
        end
        if (vid_lock) begin
          load_busy <= 0;
          load_start_pulse <= 0;
          pf_state <= PF_IDLE;
          pf_flip_pend <= 0;
          next_req_pending <= STREAM_IMAGES;
          pixel_wr_seen <= 0;
          source_done_seen <= 0;
          wrfin_seen <= 0;
          fade_req_sent <= 0;
          first_load_started <= 0;
          first_image_committed <= 0;
          display_valid <= 0;
          sec_cnt <= 10'd0;
          auto_due_q <= 0;
          auto_half_due_q <= 0;
          auto_cnt <= 0;
        end
      end
    end
  end

  bmp_read #(
    .SCAN_INIT_BUDGET(SCAN_INIT_BUDGET),
    .FRAME_WORDS     (FRAME_WORDS),
    .SCALING_EN      (1'b1)
  ) bmp_read_m0 (
    .clk            (clk),
    .rst            (rst),
    .ready          (bmp_ready),
    .load_error     (image_load_error),
    .source_top_down(source_top_down),

    .scan_start(DIRECTORY_IMAGES ? 1'b0 : scan_start_pulse),
    .load_abort(vid_lock),
    .sd_error(sd_error),
    .sd_grant(sd_grant),
    .scan_abort(first_image_committed && (next_req_pending || key_next_press || auto_step)),
    .scan_start_sector(scan_start_sector),
    .scan_start_sector2(scan_start_sector2),
    .scan_start2(DIRECTORY_IMAGES ? 1'b0 : scan_start2),
    .scan_max_sector(SCAN_MAX_SECTOR),
    .scan_target_count(scan_start2 ? (SCAN_TARGET_COUNT - img_found_count) : SCAN_TARGET_COUNT),
    .scan_limited(scan_limited),  // 1 = phase A（受限）
    .scan_done(bmp_scan_done),
    .scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector),
    .scan_found_total(scan_found_total),

    .load_start (load_start_pulse),
    .load_sector(load_sector),

    .sd_init_done(sd_init_done),
    .state_code(state_code),
    .bmp_width(bmp_width),
    .bmp_height(bmp_height),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .write_almost_full(reader_high_q),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .bmp_data_wr_en(bmp_data_wr_en),
    .bmp_data(bmp_data),
    .img_h_o(img_h_raw),  // BMP 源图高度。
    .aspect_h_o(img_aspect_h),
    .img_w_o(img_src_w),  // BMP 源图宽度。
    .scan_sector_o(scan_sector)
  );

endmodule


module key_press_debounce #(
  parameter integer CLK_FREQ_HZ = 100_000_000,
  parameter integer DEBOUNCE_MS = 20
) (
  input  wire clk,
  input  wire rst,
  input  wire button_in,   // 默认：松开=1，按下=0
  output reg  press_pulse
);

  localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

  reg button_sync0;
  reg button_sync1;
  reg button_stable;
  reg [31:0] cnt;
  localparam [31:0] DB_LIMIT = DEBOUNCE_CYCLES - 1;
  reg db_due;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      button_sync0  <= 1'b1;
      button_sync1  <= 1'b1;
      button_stable <= 1'b1;
      cnt           <= 32'd0;
      db_due        <= (DB_LIMIT == 0);
      press_pulse   <= 1'b0;
    end else begin
      button_sync0 <= button_in;
      button_sync1 <= button_sync0;
      press_pulse  <= 1'b0;

      if (button_sync1 == button_stable) begin
        cnt <= 32'd0;
        db_due <= (DB_LIMIT == 0);
      end else begin
        if (db_due) begin
          if (button_stable && !button_sync1) press_pulse <= 1'b1;
          button_stable <= button_sync1;
          cnt           <= 32'd0;
          db_due        <= (DB_LIMIT == 0);
        end else begin
          cnt <= cnt + 32'd1;
          db_due <= cnt == (DB_LIMIT - 1'b1);
        end
      end
    end
  end

endmodule
