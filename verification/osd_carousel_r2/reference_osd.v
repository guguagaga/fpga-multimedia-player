//===================================================================
// osd_player_ui : bottom player bar (progress + time + song title)
//===================================================================
// Overlays a professional music-player HUD at the bottom of the video:
//   - song title (8-char 8.3 short name) on the top-left of the bar
//   - a progress bar (played = bright, unplayed = dim, dot at cursor)
//   - current time "m:ss" (left) and total "m:ss" (right) under the bar
//
// Text is drawn with the shared 8x16 char_rom. Everything is blended
// over the background (translucent glass look) using the same Q4 alpha
// blend used by the spectrum.
//
// Inputs tot_sec/cur_sec/progress/song_name are slow (already CDC-synced
// into video_clk by the top level). The mm:ss split uses two serial
// dividers (tot once, cur every ~1s).
//===================================================================
module reference_osd #(
  parameter [26:0] TICK_CYCLES = 27'd74_249_999  // ~1s @ 25 MHz (cur_sec refresh)
) (
  input  wire        clk,          // video_clk (25 MHz)
  input  wire        rst_n,
  input  wire        de,
  input  wire        vs,
  input  wire [10:0] screen_x,
  input  wire [ 9:0] screen_y,
  input  wire [ 7:0] video_r,
  input  wire [ 7:0] video_g,
  input  wire [ 7:0] video_b,
  input  wire [15:0] tot_sec,      // total length (seconds)
  input  wire [15:0] cur_sec,      // elapsed (seconds)
  input  wire [ 7:0] progress,     // Q8 0..255
  input  wire [63:0] song_name,    // 8-byte ASCII (8.3 short name)
  input  wire [31:0] sample_rate,
  input  wire [15:0] channels,
  input  wire [15:0] bit_depth,
  input  wire [ 4:0] volume,       // 0..31
  input  wire        pause,        // 1 = paused
  // [Design note bc-osd]参数拨码档位（video 域已同步的稳定值）：
  //   SW[1:0] = 亮度档、SW[3:2] = 对比度档；变化后显示约 3 秒。
  input  wire [ 3:0] sw_deg,
  // ---- 键盘自检页（调试用）----
  input  wire        kp_debug,     // 1 = 显示键盘自检面板
  input  wire [15:0] kp_image,     // 4x4 键位图，bit{row,col} = 该键被读到闭合
  input  wire [ 1:0] kp_row,       // 当前扫描行
  input  wire [ 3:0] kp_col,       // 当前列读数
  input  wire [ 3:0] kp_key,       // 当前键码 0..15
  output reg         de_out,
  output reg         vs_out,
  output wire [ 7:0] osd_r,
  output wire [ 7:0] osd_g,
  output wire [ 7:0] osd_b
);

  reg de_stage,vs_stage;
  reg [23:0] color_out_q;
  // Scale the entire proven layout, including fonts/logo, by 5/4.
  wire [10:0] y2 = {screen_y, 1'b0};
  wire [ 9:0] pixel_x = screen_x[10:1];
  wire [ 9:0] pixel_y = y2 / 3;

  // ================= layout (640x480) =================
  // 顶部信息栏（标题 + 音频格式，体现多媒体播放器完整性）
  localparam [9:0] HDR_Y = 10'd12;  // 顶部文字 y
  localparam [9:0] TITLE_HX = 10'd40;  // "MUSIC SPECTRUM" (14 chars)
  localparam [9:0] FMT_HX = 10'd416;  // "48kHz 16bit 2ch" (16 chars)
  localparam [9:0] HDR_PANEL_X0 = 10'd24;  // 顶部底板
  localparam [9:0] HDR_PANEL_X1 = 10'd616;
  localparam [9:0] HDR_PANEL_Y0 = 10'd8;
  localparam [9:0] HDR_PANEL_Y1 = 10'd36;
  localparam [9:0] TITLE_X = 10'd40;
  localparam [9:0] TITLE_Y = 10'd430;
  localparam [9:0] PROG_X0 = 10'd40;
  localparam [9:0] PROG_X1 = 10'd600;
  localparam [9:0] PROG_Y = 10'd450;
  localparam [9:0] PROG_H = 10'd4;
  localparam [9:0] TIME_Y = 10'd458;
  localparam [9:0] CUR_X = 10'd40;
  localparam [9:0] TOT_X = 10'd560;  // right-aligned (5 chars x 8px)
  localparam [9:0] VOL_X = 10'd170;  // "VOL xx" (6 chars) 顶部栏
  localparam [9:0] STATE_X = 10'd250;  // "PLAY "/"PAUSE" (5 chars) 顶部栏
  // [Design note bc-osd]参数区 "B:+16 C:160" (11 chars x 8px = 88px)
  //   顶部栏中间空档：STATE 尾(290) .. FMT 头(416) 之间，取 304 起步。
  localparam [9:0] PARAM_X = 10'd304;
  // [Design note scroll-osd]滚动标语带 + 运行时间戳区
  //   滚动带：y=44..59 全宽 16px（顶栏底板 8..35 与频谱 y>=151 之间的干净横带）；
  //   标语 33 字符 + 尾部空白补齐到 114 字符（912px 周期）——屏幕宽 640px，
  //   周期必须 > 640+264=904px 才能保证【同一时刻屏上只有一段标语】；
  //   相位每 vs 下降沿 +1px（≈59.5px/s），整周 ≈15.3s（文本改字符表即可）。
  localparam [9:0] SCROLL_Y = 10'd44;
  // Full-width ticker; the centered brand panel is composited above it.
  localparam [9:0] UPT_X = 10'd544;

  // ========== [Design note brand]顶部品牌条：安路 logo + 「anlogic 多媒体播放系统」==========
  //   位置：滚动带那一行（y=40..63），正好在顶栏底板(8..35)下方、频谱(y>=151)上方。
  //   内容：左边 94x18 的安路 logo（红条纹 A + LOGIC），右边
  //         "anlogic "（8 个 8px ASCII，用原 char_rom）+ 9 个汉字（16x16，用 osd_brand_rom）。
  //   底板：半透明暗色（复用顶栏 panel 的混合色），保证白底图片上也看得清。
  //   BRAND_ON=0 时整块回到原来的滚动英文标语（行为与改动前一致）。
  localparam BRAND_ON = 1'b1;
  // Move the original brand group right by 140 logical pixels: the
  // 344-pixel panel now centers at x=320. Keep all vertical coordinates.
  localparam [9:0] BRAND_X0 = 10'd148;  // 底板
  localparam [9:0] BRAND_X1 = 10'd492;
  localparam [9:0] BRAND_Y0 = 10'd40;
  localparam [9:0] BRAND_Y1 = 10'd64;
  localparam [9:0] LOGO_X = 10'd158;  // logo 左上角
  localparam [9:0] LOGO_Y = 10'd43;
  localparam [9:0] LOGO_W = 10'd94;  // 与 anlogic_logo.mem 一致
  localparam [9:0] LOGO_H = 10'd18;
  localparam [9:0] BRAND_TX = 10'd264;  // 文字起点
  localparam [9:0] BRAND_TY = 10'd44;
  localparam [9:0] BRAND_AW = 10'd64;  // "anlogic " = 8 个 ASCII x 8px
  localparam [9:0] BRAND_CW = 10'd144;  // 9 个汉字 x 16px

  // ================= 键盘自检面板布局 (4x4 键位图 + 原始读数) =================
  // 放在屏幕中部偏左，避开底部频谱柱和顶部/底部 OSD 栏
  localparam [9:0] KPDB_X0 = 10'd56;  // 面板底板
  localparam [9:0] KPDB_Y0 = 10'd160;
  localparam [9:0] KPDB_X1 = 10'd272;
  localparam [9:0] KPDB_Y1 = 10'd360;
  localparam [9:0] KPD_TITLE_X = 10'd88;  // "KEYPAD" (6 chars)
  localparam [9:0] KPD_TITLE_Y = 10'd172;
  localparam [9:0] KPD_GRID_X = 10'd96;  // 4x4 键位格左上角（格宽 12，格高 16）
  localparam [9:0] KPD_GRID_Y = 10'd196;
  // "BMP=xxxx"：位图的十六进制值（4 位），可以逐个数字读出来
  localparam [9:0] KPD_BMP_X = 10'd88;
  localparam [9:0] KPD_BMP_Y = 10'd268;
  localparam [9:0] KPD_ROW_X = 10'd88;  // "R=x"
  localparam [9:0] KPD_COL_X = 10'd136;  // "C=x"
  localparam [9:0] KPD_INFO_Y = 10'd296;
  localparam [9:0] KPD_CNT_X = 10'd88;  // "K=x"
  localparam [9:0] KPD_CNT_Y = 10'd324;

  // 深色半透明底板区域（覆盖歌名+进度条+时间，提升白底对比度）
  localparam [9:0] PANEL_X0 = 10'd24;
  localparam [9:0] PANEL_X1 = 10'd616;
  localparam [9:0] PANEL_Y0 = 10'd415;
  localparam [9:0] PANEL_Y1 = 10'd477;

  localparam [7:0] TEXT_R = 8'hFF, TEXT_G = 8'hFF, TEXT_B = 8'hFF;

  // ================= mm:ss split（【面积回收 2 · 2026-10-07】改成常数除法）=================
  // cur: 每 ~1s 刷新一次；tot: tot_sec 变化时刷新
  reg [26:0] timer;
  reg        tick;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      timer <= 27'd0;
      tick  <= 1'b0;
    end else begin
      tick <= 1'b0;
      if (timer == TICK_CYCLES) begin
        timer <= 27'd0;
        tick  <= 1'b1;
      end else begin
        timer <= timer + 27'd1;
      end
    end
  end

  reg [15:0] tot_sec_d;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) tot_sec_d <= 16'd0;
    else tot_sec_d <= tot_sec;
  end
  wire tot_changed = (tot_sec != tot_sec_d);

  // [Design note bc-osd]参数区显隐：sw_deg 变化 ⇒ 显示约 3 秒后自动消失。
  //   复用上面的 ~1s tick：变化时计时器置 3，每 tick 减 1（3 个 tick ≈ 3 秒）。
  //   pad 级同步（top 侧）已保证 sw_deg 是稳定值，这里只做"变化"检测。
  reg [3:0] sw_deg_d;
  reg [1:0] pshow_cnt;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sw_deg_d  <= 4'd0;
      pshow_cnt <= 2'd0;
    end else begin
      sw_deg_d <= sw_deg;
      if (sw_deg != sw_deg_d) pshow_cnt <= 2'd3;  // 变化：重新显示 3 秒
      else if (tick && (pshow_cnt != 2'd0)) pshow_cnt <= pshow_cnt - 2'd1;
    end
  end
  wire       pshow = (pshow_cnt != 2'd0);

  // [Design note scroll-osd]帧时基：vs 下降沿 = 场边界（video_coord 同极性）
  //   ⇒ 滚动相位每帧 +1px，实现平滑左移。
  reg        vs_d;
  reg  [9:0] sc_ph;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vs_d  <= 1'b1;
      sc_ph <= 10'd0;
    end else begin
      vs_d <= vs;
      if (vs_d && !vs)  // vs 下降沿
        sc_ph <= (sc_ph == 10'd911) ? 10'd0 : sc_ph + 10'd1;
    end
  end

  // [Design note scroll-osd]运行时间秒表（零除法 BCD；tick = 1s）
  //   显示 "UP mm:ss"；59:59 后回 00:00。
  reg [3:0] upt_sec_o, upt_sec_t, upt_min_o, upt_min_t;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      upt_sec_o <= 4'd0;
      upt_sec_t <= 4'd0;
      upt_min_o <= 4'd0;
      upt_min_t <= 4'd0;
    end else if (tick) begin
      if (upt_sec_o != 4'd9) begin
        upt_sec_o <= upt_sec_o + 4'd1;
      end else begin
        upt_sec_o <= 4'd0;
        if (upt_sec_t != 4'd5) begin
          upt_sec_t <= upt_sec_t + 4'd1;
        end else begin
          upt_sec_t <= 4'd0;
          if (upt_min_o != 4'd9) begin
            upt_min_o <= upt_min_o + 4'd1;
          end else begin
            upt_min_o <= 4'd0;
            upt_min_t <= (upt_min_t == 4'd5) ? 4'd0 : upt_min_t + 4'd1;
          end
        end
      end
    end
  end

  // 原来这里挂了两个 div_u32（各 ~106 FF + ~180 LUT）。它们的除数是常数 60、
  // 被除数只有 16 位，所以换成本文件末尾那个专用的 16 拍 restoring 除法器
  // `reference_div60_16`（rem 恒 < 60 ⇒ 只要 7 位），面积约为 div_u32 的 1/3。
  //   ⚠ 一开始我试过"纯组合常数除法"（x/15 用移位相加再 >>2），
  //     被 TB 的全量穷举否掉了：x=60 会算成 0（应为 1）、x=3600 算成 59:60，
  //     共 4152 个错值。那个恒等式在有截断时并不精确，所以放弃。
  //   现在的 reference_div60_16 由 `div60_const_tb.v` 对 x=0..65535 全量穷举证明精确。
  //
  // 【声明顺序纪律】cur_start/tot_start 必须在被 reference_div60_16 实例引用之前声明：
  //   曾经把实例放在声明前面 ⇒ TD 报 HDL-7225 "already implicitly declared"，
  //   把它们当成未驱动的 1 位隐式 wire ⇒ 除法器永远不启动、mm:ss 不刷新。
  //   （这条坑本项目已踩过多次，务必保持"先声明后使用"。）
  reg cur_start, tot_start;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cur_start <= 1'b0;
      tot_start <= 1'b0;
    end else begin
      cur_start <= tick;
      tot_start <= tot_changed;
    end
  end

  wire cur_done, tot_done;
  wire [15:0] cur_q, tot_q;
  wire [6:0] cur_r7, tot_r7;
  reference_div60_16 u_div60_cur (
    .clk  (clk),
    .rst_n(rst_n),
    .start(cur_start),
    .x    (cur_sec),
    .done (cur_done),
    .q    (cur_q),
    .r    (cur_r7)
  );
  reference_div60_16 u_div60_tot (
    .clk  (clk),
    .rst_n(rst_n),
    .start(tot_start),
    .x    (tot_sec),
    .done (tot_done),
    .q    (tot_q),
    .r    (tot_r7)
  );

  // 【面积回收 2 · 2026-10-07】两个 div_u32 已换成 reference_div60_16（见上）。
  //   值在除法 done 的那一拍锁存，与原实现时序语义完全一致。
  reg [7:0] cur_min, cur_secmod, tot_min, tot_secmod;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cur_min <= 8'd0;
      cur_secmod <= 8'd0;
      tot_min <= 8'd0;
      tot_secmod <= 8'd0;
    end else begin
      if (cur_done) begin
        cur_min <= cur_q[7:0];
        cur_secmod <= {1'b0, cur_r7};
      end
      if (tot_done) begin
        tot_min <= tot_q[7:0];
        tot_secmod <= {1'b0, tot_r7};
      end
    end
  end

  // BCD digits (constant divide, small ranges)
  wire [3:0] cur_min_tens = cur_min / 10, cur_min_ones = cur_min % 10;
  wire [3:0] cur_sec_tens = cur_secmod / 10, cur_sec_ones = cur_secmod % 10;
  wire [3:0] tot_min_tens = tot_min / 10, tot_min_ones = tot_min % 10;
  wire [3:0] tot_sec_tens = tot_secmod / 10, tot_sec_ones = tot_secmod % 10;
  wire [3:0] vol_ten = volume / 10, vol_one = volume % 10;

  // [Design note bc-osd]参数区显示数字（查表，零除法）：
  //   ⚠ 档位↔数值映射必须与 top 的 bc_bright / bc_contrast 保持一致！
  reg        b_sign;  // 1 = 负
  reg [3:0] b_tens, b_ones;  // 亮度两位十进制
  reg [3:0] c_hun, c_tens, c_ones;  // 对比度三位十进制
  always @(*) begin
    case (sw_deg[1:0])  // 亮度档: -48 / -16 / +16 / +48
      2'd0: begin
        b_sign = 1'b1;
        b_tens = 4'd4;
        b_ones = 4'd8;
      end
      2'd1: begin
        b_sign = 1'b1;
        b_tens = 4'd1;
        b_ones = 4'd6;
      end
      2'd2: begin
        b_sign = 1'b0;
        b_tens = 4'd1;
        b_ones = 4'd6;
      end
      default: begin
        b_sign = 1'b0;
        b_tens = 4'd4;
        b_ones = 4'd8;
      end
    endcase
    case (sw_deg[3:2])  // 对比度档: 096 / 128 / 160 / 192
      2'd0: begin
        c_hun  = 4'd0;
        c_tens = 4'd9;
        c_ones = 4'd6;
      end
      2'd1: begin
        c_hun  = 4'd1;
        c_tens = 4'd2;
        c_ones = 4'd8;
      end
      2'd2: begin
        c_hun  = 4'd1;
        c_tens = 4'd6;
        c_ones = 4'd0;
      end
      default: begin
        c_hun  = 4'd1;
        c_tens = 4'd9;
        c_ones = 4'd2;
      end
    endcase
  end

  // [Design note scroll-osd]滚动相位映射（放在字符表之前——声明顺序纪律）
  //   pos = pixel_x + 相位（0..958）：字形列 = pos[2:0]。
  //   循环取模 + 单段周期（两轮板测修复合并）：
  //     ① 首版（"≥33 即空格"）⇒ 文字只滚出、右侧无新字（只在左半滚动）；
  //     ② 二版（mod 40 = 320px 周期）⇒ 屏宽 640 > 320，同一时刻显示【两段】；
  //        ⇒ 周期取 114 字符 = 912px（> 屏宽 640 + 文字 264 = 904）⇒ 屏上恒
  //        只有一段；文字滚完约 4.4s，整屏空白约 10.9s 后下一段进入。
  //     取模实现：pos>>3 <= 193 < 2x114 ⇒ 一次比较减法即可，零除法。
  //       相位 911→0 与 114 字符周期天然衔接（912 = 114x8）。
  // Keep one continuous scrolling phase across the entire screen.
  wire [10:0] sc_pos = {1'b0, pixel_x} + {1'b0, sc_ph};  // 0..1550（11 位防溢出）
  wire [ 7:0] sc_i8 = sc_pos[10:3];  // 0..193
  wire [ 7:0] sc_i_m = (sc_i8 >= 8'd114) ? (sc_i8 - 8'd114) : sc_i8;
  wire [ 6:0] sc_i = sc_i_m[6:0];  // 0..113（<=127）

  // [Design note scroll-osd]滚动标语字符表
  //   "WELCOME TO FPGA MULTIMEDIA PLAYER"（33 字符）+ 空格补齐；
  //   33 及以后全部走 default 空格 ⇒ 文字与空白共 40 格循环左移。
  reg  [ 7:0] sc_char;
  always @(*) begin
    case (sc_i)
      7'd0: sc_char = "W";
      7'd1: sc_char = "E";
      7'd2: sc_char = "L";
      7'd3: sc_char = "C";
      7'd4: sc_char = "O";
      7'd5: sc_char = "M";
      7'd6: sc_char = "E";
      7'd7: sc_char = " ";
      7'd8: sc_char = "T";
      7'd9: sc_char = "O";
      7'd10: sc_char = " ";
      7'd11: sc_char = "F";
      7'd12: sc_char = "P";
      7'd13: sc_char = "G";
      7'd14: sc_char = "A";
      7'd15: sc_char = " ";
      7'd16: sc_char = "M";
      7'd17: sc_char = "U";
      7'd18: sc_char = "L";
      7'd19: sc_char = "T";
      7'd20: sc_char = "I";
      7'd21: sc_char = "M";
      7'd22: sc_char = "E";
      7'd23: sc_char = "D";
      7'd24: sc_char = "I";
      7'd25: sc_char = "A";
      7'd26: sc_char = " ";
      7'd27: sc_char = "P";
      7'd28: sc_char = "L";
      7'd29: sc_char = "A";
      7'd30: sc_char = "Y";
      7'd31: sc_char = "E";
      7'd32: sc_char = "R";
      default: sc_char = " ";
    endcase
  end

  // 音频格式：采样率 kHz + 位深 + 声道（case 映射，避免大位宽除法）
  reg [3:0] sr_tens, sr_ones;  // 采样率 kHz 十位/个位
  reg [3:0] bd_tens, bd_ones;  // 位深 十位/个位
  reg [3:0] ch_digit;  // 声道数字 1/2
  always @(*) begin
    case (sample_rate)
      32'd32000: begin
        sr_tens = 4'd3;
        sr_ones = 4'd2;
      end
      32'd44100: begin
        sr_tens = 4'd4;
        sr_ones = 4'd4;
      end
      32'd48000: begin
        sr_tens = 4'd4;
        sr_ones = 4'd8;
      end
      32'd88200: begin
        sr_tens = 4'd8;
        sr_ones = 4'd8;
      end
      32'd96000: begin
        sr_tens = 4'd9;
        sr_ones = 4'd6;
      end
      default: begin
        sr_tens = 4'd4;
        sr_ones = 4'd8;
      end  // 默认 48k
    endcase
    case (bit_depth)
      16'd8: begin
        bd_tens = 4'd0;
        bd_ones = 4'd8;
      end
      16'd16: begin
        bd_tens = 4'd1;
        bd_ones = 4'd6;
      end
      16'd24: begin
        bd_tens = 4'd2;
        bd_ones = 4'd4;
      end
      16'd32: begin
        bd_tens = 4'd3;
        bd_ones = 4'd2;
      end
      default: begin
        bd_tens = 4'd1;
        bd_ones = 4'd6;
      end  // 默认 16bit
    endcase
    ch_digit = (channels >= 16'd2) ? 4'd2 : 4'd1;
  end

  // ================= text region decode =================
  wire in_title = (pixel_x >= TITLE_X) && (pixel_x < TITLE_X + 10'd64) &&
                    (pixel_y >= TITLE_Y) && (pixel_y < TITLE_Y + 10'd16);
  wire in_cur   = (pixel_x >= CUR_X)   && (pixel_x < CUR_X + 10'd40) &&
                    (pixel_y >= TIME_Y)  && (pixel_y < TIME_Y + 10'd16);
  wire in_tot   = (pixel_x >= TOT_X)   && (pixel_x < TOT_X + 10'd40) &&
                    (pixel_y >= TIME_Y)  && (pixel_y < TIME_Y + 10'd16);

  wire [2:0] title_idx = (pixel_x - TITLE_X) >> 3;
  wire [2:0] cur_idx = (pixel_x - CUR_X) >> 3;
  wire [2:0] tot_idx = (pixel_x - TOT_X) >> 3;

  // 顶部信息栏区域
  wire in_hdr_t = (pixel_y >= HDR_Y) && (pixel_y < HDR_Y + 10'd16) &&
                    (pixel_x >= TITLE_HX) && (pixel_x < TITLE_HX + 10'd112);
  wire in_hdr_f = (pixel_y >= HDR_Y) && (pixel_y < HDR_Y + 10'd16) &&
                    (pixel_x >= FMT_HX) && (pixel_x < FMT_HX + 10'd128);
  wire [3:0] hdr_t_idx = (pixel_x - TITLE_HX) >> 3;
  wire [3:0] hdr_f_idx = (pixel_x - FMT_HX) >> 3;

  // 音量 + 播放状态区域（顶部栏中间空隙）
  wire in_vol = (pixel_x >= VOL_X) && (pixel_x < VOL_X + 10'd48) &&
                  (pixel_y >= HDR_Y) && (pixel_y < HDR_Y + 10'd16);
  wire in_state = (pixel_x >= STATE_X) && (pixel_x < STATE_X + 10'd40) &&
                    (pixel_y >= HDR_Y) && (pixel_y < HDR_Y + 10'd16);
  wire [2:0] vol_idx = (pixel_x - VOL_X) >> 3;
  wire [2:0] state_idx = (pixel_x - STATE_X) >> 3;

  // [Design note bc-osd]参数区区域与字符索引（仅 pshow 期间"存在"）
  wire in_param = pshow &&
                    (pixel_x >= PARAM_X) && (pixel_x < PARAM_X + 10'd88) &&
                    (pixel_y >= HDR_Y) && (pixel_y < HDR_Y + 10'd16);
  wire [3:0] param_idx = (pixel_x - PARAM_X) >> 3;

  // [Design note scroll-osd]滚动带区域与运行时间区域
  //   （sc_pos / sc_i 已上移到字符表之前——声明顺序纪律：先用后声明会变 1 位隐式线）
  wire in_scroll = (pixel_y >= SCROLL_Y) && (pixel_y < SCROLL_Y + 10'd16);
  wire in_upt = (pixel_y >= HDR_Y) && (pixel_y < HDR_Y + 10'd16) &&
                  (pixel_x >= UPT_X) && (pixel_x < UPT_X + 10'd64);
  wire [2:0] upt_idx = (pixel_x - UPT_X) >> 3;

  // ================= [Design note brand]顶部品牌条区域 =================
  wire in_brand_bg = BRAND_ON && (pixel_x >= BRAND_X0) && (pixel_x < BRAND_X1) &&
                       (pixel_y >= BRAND_Y0) && (pixel_y < BRAND_Y1);
  wire in_logo     = BRAND_ON && (pixel_x >= LOGO_X) && (pixel_x < LOGO_X + LOGO_W) &&
                       (pixel_y >= LOGO_Y) && (pixel_y < LOGO_Y + LOGO_H);
  wire in_brand_a  = BRAND_ON && (pixel_y >= BRAND_TY) && (pixel_y < BRAND_TY + 10'd16) &&
                       (pixel_x >= BRAND_TX) && (pixel_x < BRAND_TX + BRAND_AW);
  wire in_brand_c  = BRAND_ON && (pixel_y >= BRAND_TY) && (pixel_y < BRAND_TY + 10'd16) &&
                       (pixel_x >= BRAND_TX + BRAND_AW) &&
                       (pixel_x < BRAND_TX + BRAND_AW + BRAND_CW);
  wire [2:0] brand_a_idx = (pixel_x - BRAND_TX) >> 3;
  wire [9:0] brand_c_rel = pixel_x - (BRAND_TX + BRAND_AW);
  wire [3:0] brand_c_gly = brand_c_rel[7:4];  // 0..8 = 安路多媒体播放系统
  wire [3:0] brand_c_col = brand_c_rel[3:0];  // 0..15
  wire [3:0] brand_c_row = pixel_y - BRAND_TY;  // 0..15

  // 品牌标语文字层（英文 8 个 ASCII + 9 个汉字）
  wire in_brand_txt = in_brand_a || in_brand_c;

  // ================= 键盘自检面板：区域与字符索引 =================
  wire in_kpd_title = (pixel_x >= KPD_TITLE_X) && (pixel_x < KPD_TITLE_X + 10'd48) &&
                        (pixel_y >= KPD_TITLE_Y) && (pixel_y < KPD_TITLE_Y + 10'd16);
  // 4x4 键位格：宽 12（48/12 = 4，必须整除！），高 16（刚好放 8x16 字形）
  // 注意 1：不能用 16 的横向步长 —— 48/16 只有 3，第 4 列会整个跑到区域外。
  // 注意 2：格子高度必须 >= 字形高度 16，否则字形会溢出到下一格，
  //         表现为相邻格子互相"串亮"。
  wire in_kpd_grid  = (pixel_x >= KPD_GRID_X)  && (pixel_x < KPD_GRID_X + 10'd48) &&
                        (pixel_y >= KPD_GRID_Y)  && (pixel_y < KPD_GRID_Y + 10'd64);
  wire [1:0] kpd_gx = (pixel_x - KPD_GRID_X) / 10'd12;  // 列 0..3
  wire [1:0] kpd_gy = (pixel_y - KPD_GRID_Y) >> 4;  // 行 0..3
  wire [3:0] kpd_bit = {kpd_gy, kpd_gx};
  wire in_kpd_row   = (pixel_x >= KPD_ROW_X)  && (pixel_x < KPD_ROW_X + 10'd40) &&
                        (pixel_y >= KPD_INFO_Y) && (pixel_y < KPD_INFO_Y + 10'd16);
  wire in_kpd_col   = (pixel_x >= KPD_COL_X)  && (pixel_x < KPD_COL_X + 10'd40) &&
                        (pixel_y >= KPD_INFO_Y) && (pixel_y < KPD_INFO_Y + 10'd16);
  wire in_kpd_cnt   = (pixel_x >= KPD_CNT_X)  && (pixel_x < KPD_CNT_X + 10'd40) &&
                        (pixel_y >= KPD_CNT_Y)  && (pixel_y < KPD_CNT_Y + 10'd16);
  // "BMP=xxxx"：位图十六进制，8 字符 = 64px
  wire in_kpd_bmp   = (pixel_x >= KPD_BMP_X)  && (pixel_x < KPD_BMP_X + 10'd64) &&
                        (pixel_y >= KPD_BMP_Y)  && (pixel_y < KPD_BMP_Y + 10'd16);
  wire [3:0] kpd_bi = (pixel_x - KPD_BMP_X) >> 3;
  wire [2:0] kpd_ri = (pixel_x - KPD_ROW_X) >> 3;
  wire [2:0] kpd_ci = (pixel_x - KPD_COL_X) >> 3;
  wire [3:0] kpd_ni = (pixel_x - KPD_CNT_X) >> 3;

  // 本格对应的键位是否当前被读到闭合。
  // 用实时位图（每帧刷新，约 8us）而不是"已受理"的锁存值：
  // 排查硬件时最关键的问题是"这个键到底有没有被读到"，
  // 而受理值要经过消抖+表决，读不到的键什么都看不到 —— 正好丢掉线索。
  wire kpd_hit = kp_image[kpd_bit];

  // 位图十六进制数字：第 0 个字符格是最高 4 位，第 3 个是最低 4 位。
  // （这里踩过坑：kpd_bi 是"第几个字符格"，从 0 开始递增，
  //   所以要映射成 n=3,2,1,0，写反了显示出来的十六进制是倒序的。）
  function [3:0] nib;
    input [15:0] v;
    input [1:0] n;  // 0 = 最低 4 位
    begin
      case (n)
        2'd3: nib = v[15:12];
        2'd2: nib = v[11:8];
        2'd1: nib = v[7:4];
        default: nib = v[3:0];
      endcase
    end
  endfunction
  wire [3:0] kpd_nib = nib(kp_image, 2'd3 - kpd_bi[1:0]);
  wire [7:0] kpd_hex = (kpd_nib < 4'd10) ? (8'h30 + {4'b0, kpd_nib})
                                           : (8'h41 + {4'b0, kpd_nib} - 8'd10);

  // character code for the pixel's cell (combinational)
  reg [7:0] char_code;
  always @(*) begin
    char_code = 8'h20;  // space
    if (in_hdr_t) begin
      case (hdr_t_idx)
        4'd0: char_code = "M";
        4'd1: char_code = "U";
        4'd2: char_code = "S";
        4'd3: char_code = "I";
        4'd4: char_code = "C";
        4'd5: char_code = " ";
        4'd6: char_code = "S";
        4'd7: char_code = "P";
        4'd8: char_code = "E";
        4'd9: char_code = "C";
        4'd10: char_code = "T";
        4'd11: char_code = "R";
        4'd12: char_code = "U";
        4'd13: char_code = "M";
        default: char_code = " ";
      endcase
    end else if (in_hdr_f) begin
      case (hdr_f_idx)
        4'd0: char_code = 8'h30 + sr_tens;
        4'd1: char_code = 8'h30 + sr_ones;
        4'd2: char_code = "k";
        4'd3: char_code = "H";
        4'd4: char_code = "z";
        4'd5: char_code = " ";
        4'd6: char_code = 8'h30 + bd_tens;
        4'd7: char_code = 8'h30 + bd_ones;
        4'd8: char_code = "b";
        4'd9: char_code = "i";
        4'd10: char_code = "t";
        4'd11: char_code = " ";
        4'd12: char_code = 8'h30 + ch_digit;
        4'd13: char_code = "c";
        4'd14: char_code = "h";
        default: char_code = " ";
      endcase
    end else if (in_vol) begin
      case (vol_idx)
        3'd0: char_code = "V";
        3'd1: char_code = "O";
        3'd2: char_code = "L";
        3'd3: char_code = " ";
        3'd4: char_code = 8'h30 + vol_ten;
        3'd5: char_code = 8'h30 + vol_one;
        default: char_code = " ";
      endcase
    end else if (in_param) begin
      // [Design note bc-osd]"B:+16 C:160"（11 字符固定模板）
      case (param_idx)
        4'd0: char_code = "B";
        4'd1: char_code = ":";
        4'd2: char_code = b_sign ? "-" : "+";
        4'd3: char_code = 8'h30 + b_tens;
        4'd4: char_code = 8'h30 + b_ones;
        4'd5: char_code = " ";
        4'd6: char_code = "C";
        4'd7: char_code = ":";
        4'd8: char_code = 8'h30 + c_hun;
        4'd9: char_code = 8'h30 + c_tens;
        default: char_code = 8'h30 + c_ones;
      endcase
    end else if (in_brand_a) begin
      // [Design note brand]品牌条前半段 "anlogic "（8px ASCII，用原 char_rom）
      case (brand_a_idx)
        3'd0: char_code = "a";
        3'd1: char_code = "n";
        3'd2: char_code = "l";
        3'd3: char_code = "o";
        3'd4: char_code = "g";
        3'd5: char_code = "i";
        3'd6: char_code = "c";
        default: char_code = " ";
      endcase
    end else if (in_scroll) begin
      // [Design note scroll-osd]滚动标语（相位已折算进字符号/列映射）
      char_code = sc_char;
    end else if (in_upt) begin
      // [Design note scroll-osd]运行时间 "UP mm:ss"
      case (upt_idx)
        3'd0:    char_code = "U";
        3'd1:    char_code = "P";
        3'd2:    char_code = " ";
        3'd3:    char_code = 8'h30 + upt_min_t;
        3'd4:    char_code = 8'h30 + upt_min_o;
        3'd5:    char_code = 8'h3A;  // ':'
        3'd6:    char_code = 8'h30 + upt_sec_t;
        default: char_code = 8'h30 + upt_sec_o;
      endcase
    end else if (in_state) begin
      if (pause) begin
        case (state_idx)
          3'd0: char_code = "P";
          3'd1: char_code = "A";
          3'd2: char_code = "U";
          3'd3: char_code = "S";
          3'd4: char_code = "E";
          default: char_code = " ";
        endcase
      end else begin
        case (state_idx)
          3'd0: char_code = "P";
          3'd1: char_code = "L";
          3'd2: char_code = "A";
          3'd3: char_code = "Y";
          3'd4: char_code = " ";
          default: char_code = " ";
        endcase
      end
    end else if (in_title) begin
      case (title_idx)
        3'd0: char_code = song_name[63:56];
        3'd1: char_code = song_name[55:48];
        3'd2: char_code = song_name[47:40];
        3'd3: char_code = song_name[39:32];
        3'd4: char_code = song_name[31:24];
        3'd5: char_code = song_name[23:16];
        3'd6: char_code = song_name[15:8];
        3'd7: char_code = song_name[7:0];
      endcase
    end else if (in_cur) begin
      case (cur_idx)
        3'd0: char_code = 8'h30 + cur_min_tens;
        3'd1: char_code = 8'h30 + cur_min_ones;
        3'd2: char_code = 8'h3A;  // ':'
        3'd3: char_code = 8'h30 + cur_sec_tens;
        3'd4: char_code = 8'h30 + cur_sec_ones;
      endcase
    end else if (in_tot) begin
      case (tot_idx)
        3'd0: char_code = 8'h30 + tot_min_tens;
        3'd1: char_code = 8'h30 + tot_min_ones;
        3'd2: char_code = 8'h3A;
        3'd3: char_code = 8'h30 + tot_sec_tens;
        3'd4: char_code = 8'h30 + tot_sec_ones;
      endcase
    end else if (kp_debug && in_kpd_title) begin
      case (kpd_ni)
        4'd0: char_code = "K";
        4'd1: char_code = "E";
        4'd2: char_code = "Y";
        4'd3: char_code = "P";
        4'd4: char_code = "A";
        4'd5: char_code = "D";
        default: char_code = " ";
      endcase
    end else if (kp_debug && in_kpd_grid) begin
      // 该键被读到闭合显示 '#'，否则显示 '.'，方便远距离辨认
      char_code = kpd_hit ? "#" : ".";
    end else if (kp_debug && in_kpd_row) begin
      // "R=x"：最近一次按下的行（锁存值，不是实时扫描行）
      case (kpd_ri)
        3'd0: char_code = "R";
        3'd1: char_code = "=";
        3'd2: char_code = 8'h30 + {2'b00, kp_row};
        default: char_code = " ";
      endcase
    end else if (kp_debug && in_kpd_col) begin
      // "C=x"：最近一次按下的列（锁存值）
      case (kpd_ci)
        3'd0: char_code = "C";
        3'd1: char_code = "=";
        3'd2: char_code = (kp_col < 4'd10) ? (8'h30 + kp_col) : (8'h41 + kp_col - 4'd10);
        default: char_code = " ";
      endcase
    end else if (kp_debug && in_kpd_bmp) begin
      // "BMP=xxxx"：位图的十六进制值，可直接逐位读出
      case (kpd_bi)
        4'd0: char_code = "B";
        4'd1: char_code = "M";
        4'd2: char_code = "P";
        4'd3: char_code = "=";
        4'd4: char_code = kpd_hex;  // 高 4 位
        4'd5: char_code = kpd_hex;  // 见下方 kpd_hex 的按位选择
        4'd6: char_code = kpd_hex;
        4'd7: char_code = kpd_hex;
        default: char_code = " ";
      endcase
    end else if (kp_debug && in_kpd_cnt) begin
      // "K=x"：最近一次受理的键码（0..15 用 0-9A-F 显示）
      case (kpd_ni)
        4'd0: char_code = "K";
        4'd1: char_code = "=";
        4'd2: char_code = (kp_key < 4'd10) ? (8'h30 + kp_key) : (8'h41 + kp_key - 4'd10);
        4'd3: char_code = " ";
        4'd4: char_code = "(";
        4'd5: char_code = "l";
        4'd6: char_code = "a";
        4'd7: char_code = "s";
        4'd8: char_code = "t";
        4'd9: char_code = ")";
        default: char_code = " ";
      endcase
    end
  end

  // common col/row within a character cell (use intermediate nets to
  // avoid the ternary + bit-select ambiguity)
  wire kpd_in_row = kp_debug && in_kpd_row;
  wire kpd_in_col = kp_debug && in_kpd_col;
  wire [9:0] row_base = (in_title)             ? (pixel_y - TITLE_Y)
                        : (in_hdr_t || in_hdr_f || in_vol || in_state || in_param || in_upt) ? (pixel_y - HDR_Y)
                        : (in_brand_a)           ? (pixel_y - BRAND_TY)   // [Design note brand]"anlogic" 段
  : (in_scroll) ? (pixel_y - SCROLL_Y)  // [Design note scroll-osd]
  : (kp_debug && in_kpd_title) ? (pixel_y - KPD_TITLE_Y)
                        : (kpd_in_row || kpd_in_col) ? (pixel_y - KPD_INFO_Y)
                        : (kp_debug && in_kpd_bmp)   ? (pixel_y - KPD_BMP_Y)
                        : (kp_debug && in_kpd_cnt)   ? (pixel_y - KPD_CNT_Y)
                                                     : (pixel_y - TIME_Y);
  wire [3:0] row = row_base[3:0];
  wire [9:0] col_base = (in_title) ? (pixel_x - TITLE_X)
                        : (in_hdr_t) ? (pixel_x - TITLE_HX)
                        : (in_hdr_f) ? (pixel_x - FMT_HX)
                        : (in_vol)   ? (pixel_x - VOL_X)
                        : (in_state) ? (pixel_x - STATE_X)
                        : (in_param) ? (pixel_x - PARAM_X)   // [Design note bc-osd-fix2]参数区列举地址（漏 ⇒ 落到 560 下溢、字形被截）
  : (in_upt) ? (pixel_x - UPT_X)  // [Design note scroll-osd]
  : (in_brand_a) ? (pixel_x - BRAND_TX) // [Design note brand]"anlogic" 段（漏了会落到 TOT_X 下溢）
  : (in_scroll)? {7'd0, sc_pos[2:0]}   // [Design note scroll-osd]列=相位后的列（不是屏内 x 低位）
  : (kp_debug && in_kpd_title) ? (pixel_x - KPD_TITLE_X)
                        : (kpd_in_row)               ? (pixel_x - KPD_ROW_X)
                        : (kpd_in_col)               ? (pixel_x - KPD_COL_X)
                        : (kp_debug && in_kpd_bmp)   ? (pixel_x - KPD_BMP_X)
                        : (kp_debug && in_kpd_cnt)   ? (pixel_x - KPD_CNT_X)
                        : (kp_debug && in_kpd_grid)  ? (pixel_x - KPD_GRID_X)
                        : ((in_cur)  ? (pixel_x - CUR_X) : (pixel_x - TOT_X));
  wire [2:0] col = col_base[2:0];

  // 2026-10-10 修复（声明顺序）：`char_code_safe` 的声明【上移到首次使用之前】。
  //   原文 L468 先用了它、L470 才声明 ⇒ 两个独立工具都报：
  //     · ModelSim: Error vlog-2730 (Undefined variable) + vlog-2388 (already declared)
  //     · TD      : HDL-5373 WARNING "identifier 'char_code_safe' is used before its declaration ... (468)"
  //   ⇒ 隐式 1 位网 ⇒ 后被真实 8 位声明取代 ⇒ 改为先声明再使用（不动任何逻辑 ）
  // guard: non-printable bytes (e.g. 0x00 in a short name) -> space
  // The printable range maps to 0..94; invalid bytes map to space (0).
  // Subtracting 32 modulo 128 leaves the low five bits unchanged. Compute
  // its high two bits directly and gate the final index, avoiding a guarded
  // byte mux followed by arithmetic on the coordinate-to-font-ROM path.
  wire char_printable = !char_code[7] && (|char_code[6:5]) &&
                        (char_code[6:0] != 7'h7f);
  wire [6:0] char_index = {7{char_printable}} &
                         {~(char_code[6] ^ char_code[5]), ~char_code[5], char_code[4:0]};
  wire [10:0] rom_addr = {char_index, row};
  wire [7:0] rom_data;
  char_rom u_char_rom (
    .clk (clk),
    .addr(rom_addr),
    .dout(rom_data)
  );

  // ================= [Design note brand]品牌字模 / logo 位图 ROM =================
  //   cjk_addr  = 汉字序号*16 + 行号（0..143），16 位一行（bit15 = 最左列）
  //   logo_addr = (y-LOGO_Y)*LOGO_W + (x-LOGO_X)，一个字节一个像素
  //               0=透明 1=红(A 的条纹) 2=白(LOGIC)
  //   两个口都是同步读（外面不套 if）⇒ 综合器映射进 ERAM，不占 LUT。
  wire [7:0] cjk_addr = {brand_c_gly, brand_c_row};
  // [Design note brand]logo 行基址 (y-LOGO_Y)*94 用移位相加实现：
  //   94 = 64+16+8+4+2，写成移位相加后综合成纯 LUT/加法，不占 DSP
  //   （原来直接写 `* LOGO_W` 被映射成 1 个 DSP；带频谱时 DSP 一共只有 29 个，
  //     FFT 的 butterfly 就要 4 个，不能在这里浪费）。
  wire [10:0] logo_row = {1'b0, (pixel_y - LOGO_Y)};
  wire [10:0] logo_base = (logo_row << 6) + (logo_row << 4) + (logo_row << 3)
                          + (logo_row << 2) + (logo_row << 1);
  wire [10:0] logo_rel = logo_base + {1'b0, (pixel_x - LOGO_X)};
  wire [15:0] cjk_data;
  wire [7:0] logo_data;
  osd_brand_rom u_brand_rom (
    .clk      (clk),
    .cjk_addr (cjk_addr),
    .cjk_dout (cjk_data),
    .logo_addr(logo_rel[10:0]),
    .logo_dout(logo_data)
  );

  // delay 1 cycle for synchronous font ROM
  reg [2:0] col_d;
  reg       text_on_d;
  reg       in_state_d;
  reg       in_vol_d;
  // 键盘格子的区域/命中必须跟着像素流水线一起延迟一拍：
  // pix_on 来自同步读的 char_rom（比坐标晚 1 拍），若用"当前"坐标
  // 判断会错开一个像素 —— 每格最后一列字形会读到下一格（空格），
  // 表现为最右一列/最后一行格子整格不亮。
  reg       in_kpd_grid_d;
  reg       kpd_hit_d;
  // [Design note brand]汉字位/logo 像素都要跟着同步读延后一拍
  //   汉字：选择位 = bit(15 - 列)，列号必须用延后一拍的列号
  //   logo: ROM output already has one-cycle latency, matching the delayed region.
  reg [3:0] brand_c_col_d;
  reg       in_brand_c_d;
  reg       in_logo_d;
  reg       in_brand_bg_d;
  reg       in_brand_txt_d;
  reg       in_scroll_d;
  reg [7:0] video_r_d, video_g_d, video_b_d;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_d <= 3'd0;
      text_on_d <= 1'b0;
      in_kpd_grid_d <= 1'b0;
      kpd_hit_d <= 1'b0;
      brand_c_col_d <= 4'd0;
      in_brand_c_d <= 1'b0;
      in_logo_d <= 1'b0;
      in_brand_bg_d <= 1'b0;
      in_brand_txt_d <= 1'b0;
      in_scroll_d <= 1'b0;
      video_r_d <= 8'd0;
      video_g_d <= 8'd0;
      video_b_d <= 8'd0;
      de_stage <= 1'b0;
      vs_stage <= 1'b0;
    end else begin
      col_d <= col;
      text_on_d <= (in_title | in_cur | in_tot | in_hdr_t | in_hdr_f | in_vol | in_state
                          | in_param   // [Design note bc-osd-fix]参数区文字层白名单
      | in_scroll | in_upt  // [Design note scroll-osd]滚动带 / 运行时间
      | in_brand_a  // [Design note brand]"anlogic" 那段
      | in_brand_c  // [Design note brand]9 个汉字（走 cjk 位选择）
      | (kp_debug & (in_kpd_title | in_kpd_grid | in_kpd_row | in_kpd_col
                                        | in_kpd_cnt | in_kpd_bmp))) && de;
      brand_c_col_d <= brand_c_col;
      in_brand_c_d <= in_brand_c && de;
      in_logo_d <= in_logo && de;
      in_brand_bg_d <= in_brand_bg && de;
      in_brand_txt_d <= in_brand_txt && de;
      in_scroll_d <= in_scroll && de;
      in_state_d <= in_state;
      in_vol_d <= in_vol;
      in_kpd_grid_d <= in_kpd_grid && kp_debug;
      kpd_hit_d <= kpd_hit;
      video_r_d <= video_r;
      video_g_d <= video_g;
      video_b_d <= video_b;
      de_stage <= de;
      vs_stage <= vs;
    end
  end
  wire pix_on = rom_data[7-col_d];
  // [Design note brand]汉字当前像素：cjk_data 是同步读出来的，列号用延后一拍的
  wire pix_cjk = cjk_data[4'd15-brand_c_col_d];
  // Select one font source: ticker ASCII must never leak into the CJK glyphs.
  wire pix_on_all = in_brand_c_d ? pix_cjk : pix_on;

  // ================= panel region (深色半透明底板) =================
  wire in_panel = (pixel_x >= PANEL_X0) && (pixel_x < PANEL_X1) &&
                    (pixel_y >= PANEL_Y0) && (pixel_y < PANEL_Y1);
  wire in_hdr_panel = (pixel_x >= HDR_PANEL_X0) && (pixel_x < HDR_PANEL_X1) &&
                        (pixel_y >= HDR_PANEL_Y0) && (pixel_y < HDR_PANEL_Y1);

  // ================= progress bar (geometry) =================
  wire in_prog_y = (pixel_y >= PROG_Y) && (pixel_y < PROG_Y + PROG_H);
  wire in_prog_x = (pixel_x >= PROG_X0) && (pixel_x < PROG_X1);
  wire [9:0] prog_w = PROG_X1 - PROG_X0;  // 560
  // v109 routed worst display path started at progress_s1, through
  // multiplication, comparisons and color selection (21.147ns).
  // Register slow metadata arithmetic; raster RGB/DE/VS latency is unchanged.
  reg [17:0] prog_mul;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) prog_mul <= 18'd0;
    else prog_mul <= prog_w * progress;
  wire [9:0] prog_px = prog_mul[17:8];  // 560*progress/256
  wire prog_played = (pixel_x < (PROG_X0 + prog_px));
  // cursor dot: a 2px vertical bright line at the playhead
  wire in_cursor = (pixel_x >= (PROG_X0 + prog_px - 10'd1)) &&
                     (pixel_x <= (PROG_X0 + prog_px)) &&
                     (pixel_y >= (PROG_Y - 10'd2)) && (pixel_y < (PROG_Y + PROG_H + 10'd2));

  // ================= 键盘自检底板 =================
  wire in_kpd_panel = kp_debug && (pixel_x >= KPDB_X0) && (pixel_x < KPDB_X1) &&
                                   (pixel_y >= KPDB_Y0) && (pixel_y < KPDB_Y1);

  // ================= alpha blend (Q4) =================
  function [7:0] alpha_blend;
    input [7:0] fg;
    input [7:0] bg;
    input [4:0] a;
    reg [12:0] m_f, m_b;
    begin
      // Exact Q4 constants used by the UI. Explicit 13-bit operands
      // avoid DSP mapping and preserve both truncation stages of nested blends.
      case (a)
        5'd11: begin
          m_f = ({5'd0,fg} << 3) + ({5'd0,fg} << 1) + {5'd0,fg};
          m_b = ({5'd0,bg} << 2) + {5'd0,bg};
        end
        5'd13: begin
          m_f = ({5'd0,fg} << 3) + ({5'd0,fg} << 2) + {5'd0,fg};
          m_b = ({5'd0,bg} << 1) + {5'd0,bg};
        end
        5'd15: begin
          m_f = ({5'd0,fg} << 4) - {5'd0,fg};
          m_b = {5'd0,bg};
        end
        default: begin m_f = fg * a; m_b = bg * (5'd16 - a); end
      endcase
      alpha_blend = (m_f + m_b) >> 4;
    end
  endfunction

  // blended colors（文字/进度条画在深色底板上，接近实心保证清晰）
  wire [ 7:0] panel_r = alpha_blend(8'h08, video_r_d, 5'd11);
  wire [ 7:0] panel_g = alpha_blend(8'h08, video_g_d, 5'd11);
  wire [ 7:0] panel_b = alpha_blend(8'h0E, video_b_d, 5'd11);
  wire [ 7:0] text_r = alpha_blend(TEXT_R, panel_r, 5'd15);
  wire [ 7:0] text_g = alpha_blend(TEXT_G, panel_g, 5'd15);
  wire [ 7:0] text_b = alpha_blend(TEXT_B, panel_b, 5'd15);
  wire [ 7:0] play_r = alpha_blend(8'hFF, panel_r, 5'd15);
  wire [ 7:0] play_g = alpha_blend(8'hFF, panel_g, 5'd15);
  wire [ 7:0] play_b = alpha_blend(8'hFF, panel_b, 5'd15);
  wire [ 7:0] idle_r = alpha_blend(8'h70, panel_r, 5'd15);
  wire [ 7:0] idle_g = alpha_blend(8'h70, panel_g, 5'd15);
  wire [ 7:0] idle_b = alpha_blend(8'h70, panel_b, 5'd15);
  // 音量绿 / 暂停橙 / 播放绿
  wire [ 7:0] vol_r = alpha_blend(8'h40, panel_r, 5'd15);
  wire [ 7:0] vol_g = alpha_blend(8'hFF, panel_g, 5'd15);
  wire [ 7:0] vol_b = alpha_blend(8'h40, panel_b, 5'd15);
  wire [ 7:0] st_r = alpha_blend(8'hFF, panel_r, 5'd15);
  wire [ 7:0] st_g = alpha_blend(8'h80, panel_g, 5'd15);
  wire [ 7:0] st_b = alpha_blend(8'h00, panel_b, 5'd15);

  // 键盘自检面板配色（深蓝底，保证白底图片上也看得清）
  wire [ 7:0] kpdp_r = alpha_blend(8'h10, video_r_d, 5'd13);
  wire [ 7:0] kpdp_g = alpha_blend(8'h14, video_g_d, 5'd13);
  wire [ 7:0] kpdp_b = alpha_blend(8'h30, video_b_d, 5'd13);
  wire [ 7:0] kp_hit_r = alpha_blend(8'hFF, kpdp_r, 5'd15);  // 闭合键：橙黄
  wire [ 7:0] kp_hit_g = alpha_blend(8'hD0, kpdp_g, 5'd15);
  wire [ 7:0] kp_hit_b = alpha_blend(8'h20, kpdp_b, 5'd15);
  wire [ 7:0] kp_off_r = alpha_blend(8'h60, kpdp_r, 5'd15);  // 未闭合：暗灰
  wire [ 7:0] kp_off_g = alpha_blend(8'h60, kpdp_g, 5'd15);
  wire [ 7:0] kp_off_b = alpha_blend(8'h68, kpdp_b, 5'd15);

  // ================= color select =================
  reg  [23:0] color_sel;
  always @(*) begin
    // Composite the complete brand group above the full-width ticker.
    // Transparent logo pixels reveal its original panel, suppressing the ticker below.
    if (in_brand_bg_d) begin
      if (in_logo_d && (logo_data == 8'd1)) color_sel = {8'hE0, 8'h28, 8'h24};
      else if (in_logo_d && (logo_data == 8'd2)) color_sel = {8'hF4, 8'hF4, 8'hF4};
      else if (in_brand_txt_d && pix_on_all) color_sel = {text_r, text_g, text_b};
      else color_sel = {panel_r, panel_g, panel_b};
    end else if (in_cursor) color_sel = {text_r, text_g, text_b};
    else if (in_kpd_grid_d && text_on_d && pix_on)
      color_sel = kpd_hit_d ? {kp_hit_r, kp_hit_g, kp_hit_b} : {kp_off_r, kp_off_g, kp_off_b};
    else if (text_on_d && pix_on_all) begin
      if (in_vol_d) color_sel = {vol_r, vol_g, vol_b};
      else if (in_state_d) color_sel = pause ? {st_r, st_g, st_b} : {vol_r, vol_g, vol_b};
      else color_sel = {text_r, text_g, text_b};
    end
        // [Design note scroll-osd]滚动带底：半透明暗色（图片透出 = 多图层混合；
        //   文字像素已在上面的"文字优先"分支处理）。复用顶栏 panel 的混合色。
    else if (in_scroll_d) color_sel = {panel_r, panel_g, panel_b};
    else if (in_prog_x && in_prog_y && prog_played) color_sel = {play_r, play_g, play_b};
    else if (in_prog_x && in_prog_y) color_sel = {idle_r, idle_g, idle_b};
    else if (in_kpd_panel) color_sel = {kpdp_r, kpdp_g, kpdp_b};
    else if (in_panel || in_hdr_panel) color_sel = {panel_r, panel_g, panel_b};
    else color_sel = {video_r_d, video_g_d, video_b_d};
  end

  // Register the final OSD mux before the spectrum blending cone.
  // DE and VS travel with RGB; the downstream AXIS converter uses these
  // aligned signals, so this adds latency without shifting visible pixels.
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin color_out_q<=0;de_out<=0;vs_out<=0;end
    else begin color_out_q<=color_sel;de_out<=de_stage;vs_out<=vs_stage;end
  end
  assign osd_r = color_out_q[23:16];
  assign osd_g = color_out_q[15:8];
  assign osd_b = color_out_q[7:0];

endmodule

//===================================================================

// reference_div60_16 : 【面积回收 2 · 2026-10-07】专用 16 拍 restoring 除法器（除数恒为 60）

//-------------------------------------------------------------------

// 为什么不用 div_u32：osd 只需要 x/60 与 x%60，且 x < 65536。div_u32 要

//   acc[63:0] + d[31:0] + 32 位比较/减法（~106 FF）。这里余数恒 < 60，

//   所以 rem 只要 7 位、只需 16 拍 shift-subtract：

//     每拍: rem = (rem<<1) | x[msb]; 若 rem >= 60 则 rem -= 60 且商该位为 1

//   ⇒ ~40 FF + ~40 LUT，约为 div_u32 的 1/3。

// 精确性：由 tb/div60_const_tb.v 对 x = 0..65535 全量穷举比对 q=x/60、r=x%60。

//===================================================================

module reference_div60_16 (

  input wire clk,

  input wire rst_n,

  input wire start,  // 1 拍脉冲启动

  input wire [15:0] x,  // 被除数

  output reg done,  // 结果就绪（1 拍脉冲）

  output reg [15:0] q,  // 商 = x/60

  output reg [6:0] r  // 余数 = x%60（恒 < 60）

);

  reg  [ 4:0] step;  // 剩余迭代次数（16 -> 0）

  reg  [15:0] dvd;  // 被除数移位寄存器

  reg  [ 6:0] rem;  // 当前余数

  reg  [15:0] quo;  // 正在拼装的商



  wire [ 7:0] rem_sh = {rem, dvd[15]};  // rem<<1 | 当前位

  wire        ge = (rem_sh >= 8'd60);

  wire [ 7:0] rem_nx = ge ? (rem_sh - 8'd60) : rem_sh;



  always @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      step <= 5'd0;
      dvd <= 16'd0;
      rem <= 7'd0;
      quo <= 16'd0;

      done <= 1'b0;
      q <= 16'd0;
      r <= 7'd0;

    end else begin

      done <= 1'b0;

      if (start) begin

        dvd  <= x;
        rem  <= 7'd0;
        quo  <= 16'd0;
        step <= 5'd16;

      end else if (step != 5'd0) begin

        dvd  <= {dvd[14:0], 1'b0};

        rem  <= rem_nx[6:0];

        quo  <= {quo[14:0], ge};

        step <= step - 5'd1;

        if (step == 5'd1) begin  // 最后一位：直接输出最终结果

          q    <= {quo[14:0], ge};

          r    <= rem_nx[6:0];

          done <= 1'b1;

        end

      end

    end

  end

endmodule
