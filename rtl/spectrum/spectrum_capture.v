// 256 点 FFT 结果映射为 32 个显示频带。
// 幅值近似、频率增益、数量级映射和包络提交分阶段执行。
// 独立同步读显示存储提供所需端口，衰减运算按频带分时复用。
module spectrum_capture #(
  // 可选三抽头 FIR 按到达顺序平滑幅值，当前由 FIR_EN 控制是否启用。
  parameter       FIR_EN    = 1'b0,
  parameter [1:0] FIR_W0    = 2'd1,
  parameter [1:0] FIR_W1    = 2'd2,
  parameter [1:0] FIR_W2    = 2'd1,
  parameter [2:0] FIR_SHIFT = 3'd2
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        fft_valid,
  input  wire [15:0] fft_re,
  input  wire [15:0] fft_im,
  input  wire [ 5:0] rd_addr,    // 0..31
  output reg  [ 7:0] rd_data,    // bar height 0..248 (synchronous read)
  input  wire [ 5:0] rd_addr2,   // 0..31 (2nd read port)
  output reg  [ 7:0] rd_data2,
  input  wire [ 5:0] rd_addr3,   // 0..31 (3rd read port)
  output reg  [ 7:0] rd_data3,
  input  wire [ 5:0] rd_addr4,   // 0..31 (4th read port)
  output reg  [ 7:0] rd_data4,
  output reg         beat_pulse  // 1-cycle pulse on bass beat (video_clk domain)
);

  // 工作存储保存各频带的当前包络，读改写时使用同地址前递。

  // 显示存储使用独立同步读端口，避免多端口组合读取形成宽选择网络。
  reg [ 7:0] cnt;
  reg [10:0] bass_acc;  // accumulated bass energy (FFT bins 1..4)
  reg [ 7:0] beat_cd;  // beat cooldown counter

  // 低于 NOISE_FLOOR 的柱高归零，抑制低幅值残留。
  // 门限作用于显示高度，幅值到高度的映射由下方查表决定。
  localparam [7:0] NOISE_FLOOR = 8'd5;

  // ---- magnitude + log2 compression ----
  wire [15:0] re_abs = fft_re[15] ? (~fft_re + 1'b1) : fft_re;
  wire [15:0] im_abs = fft_im[15] ? (~fft_im + 1'b1) : fft_im;
  // 幅度采用 max(|Re|,|Im|)+min(|Re|,|Im|)/2 的移位加法近似。
  // 连续值相对高估上界约 11.8%，整数右移另有取整误差。
  wire [15:0] mag_max = (re_abs >= im_abs) ? re_abs : im_abs;
  wire [15:0] mag_min = (re_abs >= im_abs) ? im_abs : re_abs;
  // Periodic Hann coherent gain is approximately 0.5. Compensate here,
  // preserving sample headroom in the FFT and keeping PCM untouched.
  wire [16:0] mag_unscaled = {1'b0, mag_max} + {2'b0, mag_min[15:1]};
  wire [17:0] mag_window_comp = {mag_unscaled, 1'b0};
  wire [15:0] mag_comb = (|mag_window_comp[17:16]) ? 16'hffff : mag_window_comp[15:0];
  reg [15:0] mag;
  reg fft_valid_q;
  // Register magnitude before log/tilt/peak processing to shorten the arithmetic path.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mag <= 0;
      fft_valid_q <= 0;
    end else begin
      mag <= mag_comb;
      fft_valid_q <= fft_valid;
    end
  end

  function [3:0] leading_one;
    input [15:0] x;
    integer i;
    begin
      leading_one = 4'd0;
      for (i = 0; i < 16; i = i + 1) if (x[i]) leading_one = i[3:0];
    end
  endfunction

  // 数量级索引经非线性查表映射为柱高，突出较强频带的节奏变化。
  // 该高度属于相对显示尺度。
  function [7:0] contrast_lut;
    input [3:0] n;
    begin
      case (n)
        4'd0: contrast_lut = 8'd0;
        4'd1: contrast_lut = 8'd0;
        4'd2: contrast_lut = 8'd0;
        4'd3: contrast_lut = 8'd0;
        4'd4: contrast_lut = 8'd2;
        4'd5: contrast_lut = 8'd7;
        4'd6: contrast_lut = 8'd16;
        4'd7: contrast_lut = 8'd28;
        4'd8: contrast_lut = 8'd43;
        4'd9: contrast_lut = 8'd62;
        4'd10: contrast_lut = 8'd84;
        4'd11: contrast_lut = 8'd110;
        4'd12: contrast_lut = 8'd140;
        4'd13: contrast_lut = 8'd172;
        4'd14: contrast_lut = 8'd208;
        4'd15: contrast_lut = 8'd248;
        default: contrast_lut = 8'd0;
      endcase
    end
  endfunction

  // 频率增益在幅值域通过移位加法施加，再进行数量级检测和柱高映射。
  reg [7:0] pipeline_bin;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) pipeline_bin <= 0;
    else if (fft_valid_q) pipeline_bin <= pipeline_bin + 1'b1;
  end
  wire [1:0] tilt_sel = (pipeline_bin >= 8'd57) ?
      2'd3 : (pipeline_bin >= 8'd40) ? 2'd2 : (pipeline_bin >= 8'd20) ? 2'd1 : 2'd0;

  reg [18:0] mag_t;
  always @(*) begin
    case (tilt_sel)
      // 高频补偿采用分档增益，并与显示门限共同控制低幅值残留。
      2'd0:    mag_t = {3'b000, mag};  // x1.00  +0.0 dB
      2'd1:    mag_t = {3'b000, mag} + {5'b0, mag[15:2]};  // x1.25  +1.9 dB
      2'd2:    mag_t = {2'b00, mag, 1'b0} - {5'b0, mag[15:2]};  // x1.75  +4.9 dB
      default: mag_t = {1'b0, mag, 2'b0} + {5'b0, mag[15:2]};  // x2.25  +7.0 dB
    endcase
  end

  // 19 位版 leading_one（x5 会把 16 位 mag 撑到 19 位）
  function [4:0] leading_one19;
    input [18:0] x;
    integer i;
    begin
      leading_one19 = 5'd0;
      for (i = 0; i < 19; i = i + 1) if (x[i]) leading_one19 = i[4:0];
    end
  endfunction

  reg [18:0] mag_t_q;
  reg tilt_valid;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mag_t_q <= 0;
      tilt_valid <= 0;
    end else begin
      mag_t_q <= mag_t;
      tilt_valid <= fft_valid_q;
    end
  end
  wire [4:0] n_tilt = leading_one19(mag_t_q);
  wire [3:0] n_clamp = (n_tilt > 5'd15) ? 4'd15 : n_tilt[3:0];
  wire [7:0] bar = contrast_lut(n_clamp);

  // 提交暂存保存频带包络，使显示端读取与工作存储更新分离。
  (* ram_style="bram" *)reg  [7:0] tilt_mem                                         [0:31];

  // 三抽头平滑采用移位加法，结果与当前频带索引同拍对齐。
  reg  [7:0] bar_fir0;  // x[n-1]
  reg  [7:0] bar_fir1;  // x[n-2]
  function [9:0] wmul;  // 8bit 值 × 2bit 权重（0/1/2/3，全部移位加法）
    input [7:0] v;
    input [1:0] w;
    begin
      case (w)
        2'd0:    wmul = 10'd0;
        2'd1:    wmul = {2'b0, v};
        2'd2:    wmul = {1'b0, v, 1'b0};
        default: wmul = {v, 1'b0} + {2'b0, v};  // 3 = v*2 + v
      endcase
    end
  endfunction
  wire [9:0] fir_sum = wmul(bar, FIR_W0) + wmul(bar_fir0, FIR_W1) + wmul(bar_fir1, FIR_W2);
  wire [7:0] bar_sm = FIR_EN ? (fir_sum >> FIR_SHIFT) : bar;

  // 分档倾斜函数对输入幅值作定点缩放，并限制输出范围。
  localparam [4:0] TILT_MID_IDX = 5'd16;
  localparam [4:0] TILT_HI_IDX  = 5'd21;

  function [7:0] apply_tilt;
    input [7:0] v;
    input [1:0] tier;
    reg [8:0] s;
    begin
      s = {1'b0, v} + {2'b00, v[7:3]};  // v + v/8
      if (tier == 2'd0) apply_tilt = v;
      else if (tier == 2'd1) begin
        if (s > 9'd248) apply_tilt = 8'd248;
        else apply_tilt = s[7:0];
      end else begin
        s = {1'b0, v} + {2'b00, v[7:2]};  // v + v/4
        if (s > 9'd248) apply_tilt = 8'd248;
        else apply_tilt = s[7:0];
      end
    end
  endfunction

  // 倾斜档位：按当前 cnt（即当前 bin）组合译码一次。
  // 上升写入与提交阶段复用同一个 tilt_now，避免重复生成译码逻辑。
  wire [1:0]
      tilt_now = (cnt[5:0] >= TILT_HI_IDX) ? 2'd2 : ((cnt[5:0] >= TILT_MID_IDX) ? 2'd1 : 2'd0);

  // 每拍只计算一次频带映射，并将结果复用于相关读写路径。
  // 映射保持组合时序，确保频带地址与当前 FFT 数据对齐。
  wire [5:0] lm = log_map(cnt[6:0]);

  // log_map 的 128 项 ROM 将有效 FFT bin 映射到 32 个显示频带。
  // 频带编号随 bin 单调推进；直流和未参与统计的频点由捕获条件屏蔽。
  function [4:0] log_map;
    input [6:0] bin;
    begin
      case (bin)
        0: log_map = 0;
        1: log_map = 0;
        2: log_map = 0;
        3: log_map = 1;
        4: log_map = 2;
        5: log_map = 2;
        6: log_map = 3;
        7: log_map = 4;
        8: log_map = 4;
        9: log_map = 5;
        10: log_map = 6;
        11: log_map = 6;
        12: log_map = 7;
        13: log_map = 8;
        14: log_map = 8;
        15: log_map = 9;
        16: log_map = 10;
        17: log_map = 10;
        18: log_map = 11;
        19: log_map = 12;
        20: log_map = 12;
        21: log_map = 13;
        22: log_map = 14;
        23: log_map = 14;
        24: log_map = 15;
        25: log_map = 16;
        26: log_map = 16;
        27: log_map = 17;
        28: log_map = 18;
        29: log_map = 18;
        30: log_map = 18;
        31: log_map = 18;
        32: log_map = 19;
        33: log_map = 19;
        34: log_map = 20;
        35: log_map = 20;
        36: log_map = 20;
        37: log_map = 20;
        38: log_map = 21;
        39: log_map = 21;
        40: log_map = 22;
        41: log_map = 22;
        42: log_map = 22;
        43: log_map = 22;
        44: log_map = 23;
        45: log_map = 23;
        46: log_map = 24;
        47: log_map = 24;
        48: log_map = 24;
        49: log_map = 24;
        50: log_map = 25;
        51: log_map = 25;
        52: log_map = 26;
        53: log_map = 26;
        54: log_map = 26;
        55: log_map = 26;
        56: log_map = 27;
        57: log_map = 27;
        58: log_map = 28;
        59: log_map = 28;
        60: log_map = 28;
        61: log_map = 28;
        62: log_map = 29;
        63: log_map = 29;
        64: log_map = 30;
        65: log_map = 30;
        66: log_map = 30;
        67: log_map = 30;
        68: log_map = 31;
        69: log_map = 31;
        70: log_map = 31;
        71: log_map = 31;
        72: log_map = 31;
        73: log_map = 31;
        74: log_map = 31;
        75: log_map = 31;
        76: log_map = 31;
        77: log_map = 31;
        78: log_map = 31;
        79: log_map = 31;
        80: log_map = 31;
        81: log_map = 31;
        82: log_map = 31;
        83: log_map = 31;
        84: log_map = 31;
        85: log_map = 31;
        86: log_map = 31;
        87: log_map = 31;
        88: log_map = 31;
        89: log_map = 31;
        90: log_map = 31;
        91: log_map = 31;
        92: log_map = 31;
        93: log_map = 31;
        94: log_map = 31;
        95: log_map = 31;
        96: log_map = 31;
        97: log_map = 31;
        98: log_map = 31;
        99: log_map = 31;
        100: log_map = 31;
        101: log_map = 31;
        102: log_map = 31;
        103: log_map = 31;
        104: log_map = 31;
        105: log_map = 31;
        106: log_map = 31;
        107: log_map = 31;
        108: log_map = 31;
        109: log_map = 31;
        110: log_map = 31;
        111: log_map = 31;
        112: log_map = 31;
        113: log_map = 31;
        114: log_map = 31;
        115: log_map = 31;
        116: log_map = 31;
        117: log_map = 31;
        118: log_map = 31;
        119: log_map = 31;
        120: log_map = 31;
        121: log_map = 31;
        122: log_map = 31;
        123: log_map = 31;
        124: log_map = 31;
        125: log_map = 31;
        126: log_map = 31;
        127: log_map = 31;
        default: log_map = 5'd0;
      endcase
    end
  endfunction

  // ---- 3-tap spatial smoothing REMOVED ----
  // 曾用 [1 2 1]/4 在 commit 阶段对 bar 做邻域平均。但 spectrum_display.v
  // 已做 Catmull-Rom 三次样条平滑，控制点无需预先平滑。此处 3 个 mem 组合读
  // (48:1 mux) 是布线拥塞的主要来源，已移除以降低布线资源占用。

  // 独立同步 RAM 读端口；复位有效标志，使数据阵列能够映射为块 RAM。
  // 在 32 个提交时隙逐项执行衰减及显示拷贝，共享一条运算通路。
  wire [4:0] update_index = cnt[7] ? cnt[4:0] : lm[4:0];
  // One-cycle working-RAM stage. Forward the preceding write for adjacent
  // FFT bins mapped to the same bar (read-during-write returns old data).
  reg [7:0] working_q, bar_d, cnt_d, last_value;
  reg [4:0] index_d, last_index;
  reg valid_d, working_ready, last_write;
  wire [7:0] update_old = last_write && last_index == index_d ? last_value :
      working_ready ? working_q : 8'd0;
  wire [7:0] update_decay = (update_old > 8'd2) ? update_old - 8'd2 : 8'd0;
  (* ram_style = "bram" *) reg [7:0] display_a[0:31];
  (* ram_style = "bram" *) reg [7:0] display_b[0:31];
  // First commit writes bar0..31 in order; a high-water mark replaces
  // a per-bar bitmap without changing validity during the first sweep.
  reg [5:0] display_count;
  reg read2_valid, read3_valid;
  reg [7:0] read2_raw, read3_raw;
  wire display_write = rst_n && valid_d && (cnt_d >= 8'd128) && (cnt_d < 8'd160);
  // During the first monotonic sweep every mapped bar is explicitly
  // written, including zero/noise bins. Until bin127, only the latest bar
  // can be revisited; the forwarding register contains that exact value.
  // Thus one ready bit replaces a 32-bit validity bitmap and its muxes.
  wire capture_write = rst_n && valid_d && cnt_d >= 1 && cnt_d < 127;
  wire working_write = display_write || capture_write;
  wire [7:0] working_value = display_write ?
      update_decay : (bar_d >= NOISE_FLOOR && bar_d >= update_old ? bar_d : update_old);
  always @(posedge clk) begin
    working_q <= tilt_mem[update_index];
    if (working_write) tilt_mem[index_d] <= working_value;
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      working_ready <= 0;
      valid_d <= 0;
      last_write <= 0;
      bar_d <= 0;
      cnt_d <= 0;
      index_d <= 0;
      last_index <= 0;
      last_value <= 0;
    end else begin
      valid_d <= tilt_valid;
      cnt_d   <= cnt;
      bar_d   <= bar_sm;
      index_d <= update_index;
      if (valid_d && cnt_d == 127) working_ready <= 1;
      if (working_write) begin
        last_write <= 1;
        last_index <= index_d;
        last_value <= working_value;
      end
    end
  end
  always @(posedge clk) begin
    if (display_write) begin
      display_a[index_d] <= update_decay;
      display_b[index_d] <= update_decay;
    end
    read2_raw <= display_a[rd_addr2[4:0]];
    read3_raw <= display_b[rd_addr3[4:0]];
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      display_count <= 0;
      read2_valid   <= 0;
      read3_valid   <= 0;
    end else begin
      if (display_write && !display_count[5]) display_count <= {1'b0, index_d} + 1'b1;
      read2_valid <= rd_addr2 < display_count;
      read3_valid <= rd_addr3 < display_count;
    end
  end
  always @(*) begin
    rd_data2 = read2_valid ? read2_raw : 8'd0;
    rd_data3 = read3_valid ? read3_raw : 8'd0;
  end


  integer i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= 8'd0;
      rd_data <= 8'd0;
      rd_data4 <= 8'd0;
      bass_acc <= 11'd0;
      beat_cd <= 8'd0;
      beat_pulse <= 1'b0;
    end else begin
      beat_pulse <= 1'b0;
      // ---- display synchronous reads (continuous) ----
      // 4 个端口读同一个 win 阵列的不同地址（延迟与合并前一致）
      rd_data <=
          8'd0;  // 白点关闭（面积不足，改用更密竖线，见 display 的 BAR_W_LINE）
      rd_data4 <= 8'd0;  // 【面积回收 1.5】p3 未被 spectrum_display 使用

      if (tilt_valid) begin
        // 可选三抽头平滑在捕获前完成，帧边界清理延迟样本，避免跨帧混合。
        bar_fir1 <= bar_fir0;
        bar_fir0 <= bar;
        // 组合平滑结果与当前频带索引同拍对齐。捕获范围由下方 cnt 条件定义。
        if ((cnt < 8'd127) && (cnt >= 8'd1) && (bar_sm >= NOISE_FLOOR)) begin
          // 频带包络由工作 RAM 读改写流水线提交，避免并行写入同一存储。
        end
        // accumulate bass energy (bins 1..4 = 187..750Hz)
        if (cnt >= 8'd1 && cnt <= 8'd4) bass_acc <= bass_acc + {3'b0, bar};
        // 固定步长衰减并在零处饱和，使低幅值包络能够完全回落。
        if ((cnt >= 8'd128) && (cnt < 8'd160)) begin
          // Decay is committed by the same working-RAM stage.
        end
        // ---- commit: copy bars into display banks (bars 0..47) ----
        // 频谱倾斜补偿（spectral tilt）：音乐的频谱包络大致按
        // -6dB/倍频程滚降，而 contrast_lut 是对数压缩，所以高频柱子
        // 天生比低频矮一大截 —— 视觉上右侧几乎不动，看起来"只有低音
        // 在跳"。补偿在上升写入时已完成（见 apply_tilt / tilt_now），
        // 这里只把算好的 tilt_mem 同步到 4 个显示 bank。
        // 想调强/调弱只改 apply_tilt 的移位量和 TILT_MID_IDX/TILT_HI_IDX。
        if ((cnt >= 8'd128) && (cnt < 8'd160)) begin
          // 【面积回收 1.5】只写 b1/b2（b0/b3 已删）

        end
        // ---- beat detection (once per FFT frame) ----
        if (cnt == 8'd160) begin
          bar_fir0 <= 8'd0;
          bar_fir1 <= 8'd0;
          if (beat_cd > 8'd0) beat_cd <= beat_cd - 8'd1;
          else if (bass_acc > 11'd280) begin
            beat_pulse <= 1'b1;
            beat_cd <= 8'd30;
          end
          bass_acc <= 11'd0;
        end
        cnt <= cnt + 8'd1;
      end
    end
  end

endmodule
