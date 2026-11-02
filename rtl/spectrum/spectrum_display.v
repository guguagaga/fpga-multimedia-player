// Overlay frequency bars, optional interpolation and beat-triggered notes.
// Read neighboring bar heights from the display memory ports.
// Keep pixel data and display-valid signals aligned through the overlay pipeline.
module spectrum_display #(
  // BAR_W 控制柱内可见宽度；PITCH 决定柱高采样区间。
  // 几何参数与地址范围保持一致，避免边缘读越界。
  parameter [3:0] BAR_W = 4'd5,
  // GLOW_R 和 GLOW_MIX 控制柱顶光晕范围及混色强度。
  // INTERP_EN 选择相邻柱插值或独立柱高，常量关闭时相关逻辑可被综合裁剪。
  parameter INTERP_EN = 1'b0,
  parameter GRID_EN = 1'b0,  // fixed horizontal lines disabled for image viewing
  parameter GLOW_EN = 1'b1,  // 关掉柱顶发光（省混合逻辑，面积紧张时用）
  parameter [3:0] GLOW_R = 4'd6,
  parameter [3:0] GLOW_MIX = 4'd3,
  // 底部波段复用柱高数据，根据幅值门限和分段掩码绘制。
  parameter BAND_EN = 1'b1,
  parameter [9:0] BAND_Y = 10'd406,
  parameter [3:0] BAND_H = 4'd1,
  parameter [7:0] BAND_MIN = 8'd24,
  parameter [3:0] BAND_MIX = 4'd2,
  parameter [2:0] BAND_DASH = 3'd1
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        de,
  input  wire        vs,
  input  wire [23:0] din_rgb,
  // 使能关闭时使用相同流水延迟的背景像素，保持 RGB 与有效信号对齐。
  input  wire        en,
  input  wire [ 7:0] bar_data,    // bar[i-1] (p0)
  output wire [ 6:0] bar_addr,
  input  wire [ 7:0] bar_data2,   // bar[i]   (p1)
  output wire [ 6:0] bar_addr2,
  input  wire [ 7:0] bar_data3,   // bar[i+1] (p2)
  output wire [ 6:0] bar_addr3,
  input  wire [ 7:0] bar_data4,   // bar[i+2] (p3)
  output wire [ 6:0] bar_addr4,
  input  wire        beat_pulse,  // 1-cycle pulse on bass beat
  output reg         de_out,
  output reg         vs_out,
  output reg  [23:0] dout_rgb
);

  // ---- layout constants ----
  localparam [9:0] X0 = 10'd32;
  localparam [9:0] PITCH = 10'd18;  // 数组节距 18px (32*18 = 576) —— 只决定取哪个柱
  // LINE_PITCH 定义可见线条间距，PITCH 定义频带取值间距。
  // 二者独立设置，使显示几何与频带存储规模解耦。
  localparam [9:0] LINE_PITCH = 10'd6;  // 6px 一条 -> 576/6 = 96 条
  localparam [3:0] BAR_W_LINE = 4'd3;  // 亮 3px + 暗 3px = 50% 占空
  localparam [9:0] X1 = 10'd608;
  localparam [9:0] Y0 =
      10'd405;  // spectrum baseline (上移到 OSD 播放栏上方，避免重叠)

  // ---- alpha blending (Q4, 0..16): 16=opaque, 0=invisible ----
  localparam [4:0] ALPHA = 5'd12;  // spectrum fill opacity (12 = 75%)

  // ---- rainbow gradient LUT (48 bars, blue -> red) ----
  function [23:0] grad_lut;
    input [5:0] idx;
    begin
      case (idx)
        6'd0: grad_lut = 24'h0000FF;
        6'd1: grad_lut = 24'h0016FF;
        6'd2: grad_lut = 24'h002BFF;
        6'd3: grad_lut = 24'h0041FF;
        6'd4: grad_lut = 24'h0057FF;
        6'd5: grad_lut = 24'h006DFF;
        6'd6: grad_lut = 24'h0082FF;
        6'd7: grad_lut = 24'h0098FF;
        6'd8: grad_lut = 24'h00AEFF;
        6'd9: grad_lut = 24'h00C4FF;
        6'd10: grad_lut = 24'h00D9FF;
        6'd11: grad_lut = 24'h00EFFF;
        6'd12: grad_lut = 24'h00FFFA;
        6'd13: grad_lut = 24'h00FFE4;
        6'd14: grad_lut = 24'h00FFCF;
        6'd15: grad_lut = 24'h00FFB9;
        6'd16: grad_lut = 24'h00FFA3;
        6'd17: grad_lut = 24'h00FF8D;
        6'd18: grad_lut = 24'h00FF78;
        6'd19: grad_lut = 24'h00FF62;
        6'd20: grad_lut = 24'h00FF4C;
        6'd21: grad_lut = 24'h00FF36;
        6'd22: grad_lut = 24'h00FF21;
        6'd23: grad_lut = 24'h00FF0B;
        6'd24: grad_lut = 24'h0BFF00;
        6'd25: grad_lut = 24'h21FF00;
        6'd26: grad_lut = 24'h36FF00;
        6'd27: grad_lut = 24'h4CFF00;
        6'd28: grad_lut = 24'h62FF00;
        6'd29: grad_lut = 24'h78FF00;
        6'd30: grad_lut = 24'h8DFF00;
        6'd31: grad_lut = 24'hA3FF00;
        6'd32: grad_lut = 24'hB9FF00;
        6'd33: grad_lut = 24'hCFFF00;
        6'd34: grad_lut = 24'hE4FF00;
        6'd35: grad_lut = 24'hFAFF00;
        6'd36: grad_lut = 24'hFFEF00;
        6'd37: grad_lut = 24'hFFD900;
        6'd38: grad_lut = 24'hFFC400;
        6'd39: grad_lut = 24'hFFAE00;
        6'd40: grad_lut = 24'hFF9800;
        6'd41: grad_lut = 24'hFF8200;
        6'd42: grad_lut = 24'hFF6D00;
        6'd43: grad_lut = 24'hFF5700;
        6'd44: grad_lut = 24'hFF4100;
        6'd45: grad_lut = 24'hFF2B00;
        6'd46: grad_lut = 24'hFF1600;
        6'd47: grad_lut = 24'hFF0000;
        default: grad_lut = 24'hFF0000;
      endcase
    end
  endfunction

  // ---- musical note sprite (16x16, 1 bit/pixel) ----
  function [15:0] note_row;
    input [3:0] r;
    begin
      case (r)
        4'd0: note_row = 16'h0000;
        4'd1: note_row = 16'h0000;
        4'd2: note_row = 16'h0000;
        4'd3: note_row = 16'h0000;
        4'd4: note_row = 16'h0380;
        4'd5: note_row = 16'h0780;
        4'd6: note_row = 16'h0F80;
        4'd7: note_row = 16'h1D80;
        4'd8: note_row = 16'h3980;
        4'd9: note_row = 16'h0180;
        4'd10: note_row = 16'h01F8;
        4'd11: note_row = 16'h01FC;
        4'd12: note_row = 16'h00FC;
        4'd13: note_row = 16'h0078;
        4'd14: note_row = 16'h0000;
        4'd15: note_row = 16'h0000;
        default: note_row = 16'h0000;
      endcase
    end
  endfunction

  // ---- fraction (x_in_bar 0..11) -> Q4 (0..15) ----
  // 输入 k = x_in_bar (0 .. PITCH-1)，输出 = round(k*16/PITCH)。
  // PITCH=12 -> x_in_bar 0..11，共 12 项；仍是 12 个不同采样点
  // 列内插值位置按当前 PITCH 映射到定点比例。
  // 4 bit 权重让插值乘法只用 4 个移位项 + 3 个加法器实现（无 DSP）。
  function [3:0] frac_lut;
    input [4:0] k;
    begin
      case (k)
        4'd0: frac_lut = 4'd0;
        4'd1: frac_lut = 4'd1;
        4'd2: frac_lut = 4'd3;
        4'd3: frac_lut = 4'd4;
        4'd4: frac_lut = 4'd5;
        4'd5: frac_lut = 4'd7;
        4'd6: frac_lut = 4'd8;
        4'd7: frac_lut = 4'd9;
        4'd8: frac_lut = 4'd11;
        4'd9: frac_lut = 4'd12;
        4'd10: frac_lut = 4'd13;
        4'd11: frac_lut = 4'd15;
        4'd12: frac_lut = 4'd1;
        4'd13: frac_lut = 4'd2;
        4'd14: frac_lut = 4'd4;
        4'd15: frac_lut = 4'd6;
        default: frac_lut = 4'd8;
      endcase
    end
  endfunction

  // ---- note fade color (by remaining life) ----
  function [23:0] note_color;
    input [1:0] lv;
    begin
      case (lv)
        2'd3: note_color = 24'hFFE070;
        2'd2: note_color = 24'hC0A854;
        2'd1: note_color = 24'h807038;
        2'd0: note_color = 24'h40381C;
      endcase
    end
  endfunction

  // ---- alpha blend (Q4) : fg over bg ----
  // NOTE: products must be held in explicit 13-bit locals; writing the
  // expression inline in an 8-bit context truncates each multiply to 8
  // bits (Verilog context sizing) and washes the whole spectrum to black.
  function [7:0] alpha_blend;
    input [7:0] fg;
    input [7:0] bg;
    input [4:0] a;
    reg [12:0] m_f, m_b;
    begin
      m_f = fg * a;
      m_b = bg * (5'd16 - a);
      alpha_blend = (m_f + m_b) >> 4;
    end
  endfunction

  // ---- coordinate rebuild (1 cycle) ----
  reg [9:0] active_x, active_y;
  reg [2:0] x_phase, y_phase;
  reg de_d, vs_d;
  wire vs_nedge = vs_d & ~vs;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_x <= 10'd0;
      x_phase  <= 0;
      active_y <= 10'd0;
      y_phase  <= 0;
      de_d     <= 1'b0;
      vs_d     <= 1'b0;
    end else begin
      de_d <= de;
      vs_d <= vs;
      if (vs_nedge) begin
        active_y <= 10'd0;
        y_phase  <= 0;
        active_x <= 10'd0;
        x_phase  <= 0;
      end else if (de) begin
        active_x <= active_x + (x_phase != 0);
        x_phase  <= (x_phase == 1) ? 0 : x_phase + 1'b1;
      end else if (de_d) begin
        active_y <= active_y + (y_phase != 0);
        y_phase  <= (y_phase == 2) ? 0 : y_phase + 1'b1;
        active_x <= 10'd0;
        x_phase  <= 0;
      end
    end
  end

  // ---- bar index / fraction from X ----
  wire       in_xrange = (active_x >= X0) && (active_x < X1);
  wire [9:0] bx = active_x - X0;
  wire [6:0] bar_index = bx / PITCH;
  wire [4:0] x_in_bar = bx - (bar_index * PITCH);  // 0..17

  // 相邻频带地址在有效范围内环回，防止边缘插值访问越界。
  wire [6:0] i = bar_index;
  wire [6:0] i_m1 = (i == 7'd0) ? 7'd31 : (i - 7'd1);
  wire [6:0] i_p1 = (i == 7'd31) ? 7'd0 : (i + 7'd1);
  wire [6:0] i_p2 = (i == 7'd30) ? 7'd0 : (i == 7'd31) ? 7'd1 : (i + 7'd2);

  assign bar_addr  = i_m1;  // Peak input address.
  assign bar_addr2 = i;  // p1 = bar[i]
  assign bar_addr3 = i_p1;  // p2 = bar[i+1]
  assign bar_addr4 = i_p2;  // p3 = bar[i+2]（未使用）

  // ---- pipeline (align with sync bar read) ----
  reg [9:0] ay_q_pre, ax_q_pre;
  reg [6:0] bar_index_q_pre;
  reg [4:0] x_in_bar_q_pre;
  reg de_q_pre, vs_q_pre;
  reg [23:0] rgb_q_pre;
  reg        in_xrange_q_pre;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ay_q_pre        <= 10'd0;
      ax_q_pre        <= 10'd0;
      bar_index_q_pre <= 7'd0;
      x_in_bar_q_pre  <= 5'd0;
      de_q_pre        <= 1'b0;
      vs_q_pre        <= 1'b0;
      rgb_q_pre       <= 24'd0;
      in_xrange_q_pre <= 1'b0;
    end else begin
      ay_q_pre        <= active_y;
      ax_q_pre        <= active_x;
      bar_index_q_pre <= bar_index;
      x_in_bar_q_pre  <= x_in_bar;
      de_q_pre        <= de_d;
      vs_q_pre        <= vs_d;
      rgb_q_pre       <= din_rgb;
      in_xrange_q_pre <= in_xrange;
    end
  end

  // ---- LINEAR interpolation (multiplier-free, replaces Catmull-Rom) ----
  // y = p1 + (p2 - p1) * F / 16 ,  F = 0..15 (Q4 fraction inside the bar)
  // The product (p2-p1)*F is assembled from 4 gated shift terms plus 3 small
  // adders: bit k of F selects (p2-p1)<<k.  No '*' operator anywhere, so no
  // hardware multiplier (DSP) is inferred and the 3 Catmull-Rom 23x7
  // pipelined multipliers (-6 DSP) are removed.
  // The cubic's p0 (bar_data) / p3 (bar_data4) control points are no longer
  // used; the ports and their read addresses are kept so that the module
  // port list, and therefore the instantiation in top_tf_hdmi_audio.v,
  // stays byte-for-byte identical.
  wire [7:0] p1 = bar_data2;  // bar[i]   (left point)
  wire [7:0] p2 = bar_data3;  // bar[i+1] (right point)
  wire signed [8:0] p1_9 = {1'b0, p1};
  wire signed [8:0] p2_9 = {1'b0, p2};
  wire signed [8:0] diff = p2_9 - p1_9;  // -248 .. +248

  wire [3:0] F = frac_lut(x_in_bar_q_pre);  // Q4 fraction, 0..15

  // gated shift terms, summed in 13-bit signed (|sum| <= 248*15 = 3720)
  wire signed [12:0] tp0 = F[0] ? {{4{diff[8]}}, diff} : 13'sd0;
  wire signed [12:0] tp1 = F[1] ? {{3{diff[8]}}, diff, 1'b0} : 13'sd0;
  wire signed [12:0] tp2 = F[2] ? {{2{diff[8]}}, diff, 2'b00} : 13'sd0;
  wire signed [12:0] tp3 = F[3] ? {{1{diff[8]}}, diff, 3'b000} : 13'sd0;
  wire signed [12:0] prod = tp0 + tp1 + tp2 + tp3;

  wire signed [10:0] p1_11 = {3'b0, p1};
  wire signed [10:0] frac_term = prod >>> 4;  // (p2-p1)*F/16, |.| <= 232
  wire signed [10:0] yline = p1_11 + frac_term;  // -232 .. +480

  // clamp curve_pre height to 0..248 (same clamp/saturation as before)
  // 插值结果（INTERP_EN=1 时用）
  wire [7:0] curve_interp = (yline < 11'sd0) ? 8'd0 : (yline > 11'sd248) ? 8'd248 : yline[7:0];

  // 最终柱高 INTERP_EN=0 时直接用本柱高度 ⇒ 矩形柱、锯齿清晰
  wire [7:0] curve_pre = INTERP_EN ? curve_interp : bar_data2;

  // One matched stage splits RAM/interpolation from geometry/color.
  // The bypass RGB and syncs receive the same latency, including en changes.
  // Evaluate the palette before the existing geometry boundary. The colour
  // keeps the same pixel alignment while removing LUT/index logic from blend.
  reg [23:0] grad;
  reg [9:0] ay_q, ax_q, bx_q;
  reg [6:0] bar_index_q;
  reg [4:0] x_in_bar_q;
  reg de_q, vs_q, in_xrange_q, en_q;
  reg [23:0] rgb_q;
  reg [7:0] curve, peak_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ay_q <= 0;
      ax_q <= 0;
      bx_q <= 0;
      bar_index_q <= 0;
      grad <= 24'h0000FF;
      x_in_bar_q <= 0;
      de_q <= 0;
      vs_q <= 0;
      in_xrange_q <= 0;
      en_q <= 0;
      rgb_q <= 0;
      curve <= 0;
      peak_q <= 0;
    end else begin
      ay_q <= ay_q_pre;
      ax_q <= ax_q_pre;
      bx_q <= bx;
      bar_index_q <= bar_index_q_pre;
      grad <= grad_lut(bar_index_q_pre + (bar_index_q_pre >> 1));
      x_in_bar_q <= x_in_bar_q_pre;
      de_q <= de_q_pre;
      vs_q <= vs_q_pre;
      in_xrange_q <= in_xrange_q_pre;
      en_q <= en;
      rgb_q <= rgb_q_pre;
      curve <= curve_pre;
      peak_q <= bar_data;
    end
  end

  // ---- curve geometry ----
  wire [9:0] curve_top = Y0 - {2'b0, curve};
  // 可见性掩码只选择柱内亮列，柱高保持不变；线条相位由列内位置计算。
  wire [3:0] line_col = (x_in_bar_q >= 5'd12) ? (x_in_bar_q - 5'd12) : (x_in_bar_q >= 5'd6) ?
      (x_in_bar_q - 5'd6) : x_in_bar_q[3:0];  // 0..5  (18 = 3x6)
  wire in_bar_w = (line_col < BAR_W_LINE);  // 3 亮 3 灭 -> 96 条
  wire in_fill = in_xrange_q && in_bar_w && (ay_q >= curve_top) && (ay_q <= Y0);
  wire in_edge = in_fill && (ay_q < (curve_top + 10'd3));

  // 峰值标记采用对应读端口的数据，不跨柱平均；可见性受绘制区域和参数控制。
  wire [7:0] pk1 = peak_q;  // peak[i]，来自 capture 的 mem[]
  wire [7:0] peak = pk1;
  wire [9:0] peak_top = Y0 - {2'b0, peak};

  // 白点：柱体范围内、柱顶 3 像素
  wire in_peakdot = in_xrange_q && in_bar_w && (ay_q >= curve_top) &&  // 必须落在柱体内
  (ay_q <= peak_top) &&  // 不高于峰值
  (ay_q >= (peak_top > 10'd3 ? peak_top - 10'd3 : 10'd0));

  // （白点配色 pk_r/pk_g/pk_b 在下方 edge_*2 声明之后定义 —— Verilog 要求先声明后使用）

  // 柱顶光晕在限定半径内将背景混向柱色，采用移位加减实现。
  wire [9:0] glow_lo = (curve_top > {6'b0, GLOW_R}) ? (curve_top - {6'b0, GLOW_R}) : 10'd0;
  wire in_glow = GLOW_EN && in_xrange_q && in_bar_w && (ay_q < curve_top) && (ay_q >= glow_lo) &&
      (glow_lo != curve_top);

  // 32 个频带按 i+i/2 映射到 48 项渐变表，覆盖蓝到红的完整色域。
  // 渐变颜色与坐标、背景在同一流水级对齐。
  wire [7:0] gr = grad[23:16];
  wire [7:0] gg = grad[15:8];
  wire [7:0] gb = grad[7:0];
  wire [7:0] edge_r = (gr >> 1) + 8'd128;
  wire [7:0] edge_g = (gg >> 1) + 8'd128;
  wire [7:0] edge_b = (gb >> 1) + 8'd128;

  // ---- background : album art dimmed to ~75% ----
  wire [7:0] bg_r = rgb_q[23:16] - (rgb_q[23:16] >> 2);
  wire [7:0] bg_g = rgb_q[15:8] - (rgb_q[15:8] >> 2);
  wire [7:0] bg_b = rgb_q[7:0] - (rgb_q[7:0] >> 2);

  // 可选水平网格按显示高度位置绘制，仅作为相对高度参考。
  // 网格处于柱体下层，GRID_EN 控制是否叠加。
  localparam [9:0] GRID_25  = Y0 - 10'd62;
  localparam [9:0] GRID_50  = Y0 - 10'd124;
  localparam [9:0] GRID_75  = Y0 - 10'd186;
  localparam [9:0] GRID_100 = Y0 - 10'd248;

  wire in_gridline = GRID_EN && in_xrange_q &&
      ((ay_q == GRID_25) || (ay_q == GRID_50) || (ay_q == GRID_75) || (ay_q == GRID_100)) &&
      !in_fill;  // 柱子优先，网格不划断柱子

  wire [7:0] grid_r = bg_r + (bg_r >> 2);
  wire [7:0] grid_g = bg_g + (bg_g >> 2);
  wire [7:0] grid_b = bg_b + (bg_b >> 2);

  // ---- alpha blend : spectrum over background (translucent / glass) ----
  // out = (spectrum*ALPHA + bg*(16-ALPHA)) >> 4
  wire [7:0] fill_r = alpha_blend(gr, bg_r, ALPHA);
  wire [7:0] fill_g = alpha_blend(gg, bg_g, ALPHA);
  wire [7:0] fill_b = alpha_blend(gb, bg_b, ALPHA);
  wire [7:0] edge_r2 = alpha_blend(edge_r, bg_r, ALPHA);
  wire [7:0] edge_g2 = alpha_blend(edge_g, bg_g, ALPHA);
  wire [7:0] edge_b2 = alpha_blend(edge_b, bg_b, ALPHA);

  // 峰值标记通过移位和常数加法提亮，输出按 8 位表达式截取。
  wire [7:0] pk_r = (edge_r2 >> 1) + 8'd160;
  wire [7:0] pk_g = (edge_g2 >> 1) + 8'd160;
  wire [7:0] pk_b = (edge_b2 >> 1) + 8'd160;

  // 光晕使用无符号凸组合：(bg*(2^N-1)+edge)>>N。
  // 扩展位宽后执行移位加减，避免直接相减导致下溢。
  wire [11:0] glow_r12 = (({4'b0, bg_r} << GLOW_MIX) - {4'b0, bg_r} + {4'b0, edge_r2}) >> GLOW_MIX;
  wire [11:0] glow_g12 = (({4'b0, bg_g} << GLOW_MIX) - {4'b0, bg_g} + {4'b0, edge_g2}) >> GLOW_MIX;
  wire [11:0] glow_b12 = (({4'b0, bg_b} << GLOW_MIX) - {4'b0, bg_b} + {4'b0, edge_b2}) >> GLOW_MIX;
  wire [7:0] glow_r = glow_r12[7:0];
  wire [7:0] glow_g = glow_g12[7:0];
  wire [7:0] glow_b = glow_b12[7:0];

  wire band_dash_on = (BAND_DASH == 3'd0) ? 1'b1 : (bx_q[BAND_DASH-1:0] != {BAND_DASH{1'b0}});
  wire in_band = BAND_EN && (ay_q >= BAND_Y) && (ay_q < (BAND_Y + {6'b0, BAND_H})) &&
      (curve > BAND_MIN) && band_dash_on;
  //   亮度：背景朝柱色凸组合（同 C，全程无符号 ⇒ 必落在 [min,max]）
  wire [11:0] band_r12 = (({4'b0, bg_r} << BAND_MIX) - {4'b0, bg_r} + {4'b0, edge_r2}) >> BAND_MIX;
  wire [11:0] band_g12 = (({4'b0, bg_g} << BAND_MIX) - {4'b0, bg_g} + {4'b0, edge_g2}) >> BAND_MIX;
  wire [11:0] band_b12 = (({4'b0, bg_b} << BAND_MIX) - {4'b0, bg_b} + {4'b0, edge_b2}) >> BAND_MIX;
  wire [7:0] band_r = band_r12[7:0];
  wire [7:0] band_g = band_g12[7:0];
  wire [7:0] band_b = band_b12[7:0];

  // ---- beat-reactive notes ----
  reg [15:0] lfsr;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) lfsr <= 16'hACE1;
    else lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
  end

  wire [9:0] bass_x0 = X0 + (lfsr[3:0] * PITCH) + 10'd4;
  wire [9:0] bass_x1 = X0 + (lfsr[7:4] * PITCH) + 10'd4;
  wire [9:0] bass_x2 = X0 + (lfsr[11:8] * PITCH) + 10'd4;

  reg  [9:0] note_x                                         [0:7];
  reg  [9:0] note_y                                         [0:7];
  reg  [6:0] note_life                                      [0:7];  // 0..63, 0 = inactive
  reg  [2:0] note_next;  // round-robin spawn pointer (0..7)

  // NOTE_EN 为常量关闭时，音符粒子更新和绘制逻辑可由综合器裁剪。
  localparam NOTE_EN = 1'b0;

  integer nk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      note_next <= 3'd0;
      for (nk = 0; nk < 8; nk = nk + 1) begin
        note_x[nk]    <= 10'd0;
        note_y[nk]    <= 10'd0;
        note_life[nk] <= 7'd0;
      end
    end else if (NOTE_EN) begin
      // spawn 3 notes on each beat
      if (beat_pulse) begin
        note_x[note_next]             <= bass_x0;
        note_y[note_next]             <= 10'd400;
        note_life[note_next]          <= 7'd63;
        note_x[(note_next+1)&3'd7]    <= bass_x1;
        note_y[(note_next+1)&3'd7]    <= 10'd400;
        note_life[(note_next+1)&3'd7] <= 7'd63;
        note_x[(note_next+2)&3'd7]    <= bass_x2;
        note_y[(note_next+2)&3'd7]    <= 10'd400;
        note_life[(note_next+2)&3'd7] <= 7'd63;
        note_next                     <= (note_next + 3) & 3'd7;
      end
      // float up + decay each frame
      if (vs_nedge) begin
        for (nk = 0; nk < 8; nk = nk + 1) begin
          if (note_life[nk] > 7'd0) begin
            note_y[nk]    <= note_y[nk] - 10'd2;
            note_life[nk] <= note_life[nk] - 7'd1;
          end
        end
      end
    end
  end

  // per-note pixel test
  reg [7:0] note_hit;
  integer nk2;
  always @(*) begin
    note_hit = 8'd0;
    for (nk2 = 0; nk2 < 8; nk2 = nk2 + 1) begin
      if (note_life[nk2] > 7'd0 && ax_q >= note_x[nk2] && ax_q < (note_x[nk2] + 10'd16) &&
          ay_q >= note_y[nk2] && ay_q < (note_y[nk2] + 10'd16)) begin
        if ((note_row(ay_q[3:0] - note_y[nk2][3:0]) >> (ax_q[3:0] - note_x[nk2][3:0])) & 1'b1)
          note_hit[nk2] = 1'b1;
      end
    end
  end
  wire any_note = |note_hit;

  // priority: which hit note's life (for fade color)
  reg [1:0] hit_lv;
  always @(*) begin
    hit_lv = 2'd0;
    if (note_hit[0]) hit_lv = note_life[0][5:4];
    else if (note_hit[1]) hit_lv = note_life[1][5:4];
    else if (note_hit[2]) hit_lv = note_life[2][5:4];
    else if (note_hit[3]) hit_lv = note_life[3][5:4];
    else if (note_hit[4]) hit_lv = note_life[4][5:4];
    else if (note_hit[5]) hit_lv = note_life[5][5:4];
    else if (note_hit[6]) hit_lv = note_life[6][5:4];
    else if (note_hit[7]) hit_lv = note_life[7][5:4];
  end

  // 按前景优先级选择音符、峰值、柱体、光晕、波段、网格和背景。
  reg [23:0] color_sel;
  always @(*) begin
    if (any_note) color_sel = note_color(hit_lv);
    else if (in_peakdot) color_sel = {pk_r, pk_g, pk_b};  // 峰值保持白点
    else if (in_edge) color_sel = {edge_r2, edge_g2, edge_b2};
    else if (in_fill) color_sel = {fill_r, fill_g, fill_b};
    else if (in_glow) color_sel = {glow_r, glow_g, glow_b};
    else if (in_band) color_sel = {band_r, band_g, band_b};  // 底部波段图层
    else if (in_gridline) color_sel = {grid_r, grid_g, grid_b};  // dB 参考网格
    else color_sel = {bg_r, bg_g, bg_b};
  end

  // ---- output register ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      de_out   <= 1'b0;
      vs_out   <= 1'b0;
      dout_rgb <= 24'd0;
    end else begin
      de_out <= de_q;
      vs_out <= vs_q;
      if (de_q) dout_rgb <= en_q ? color_sel : rgb_q;  // en=0 -> 原样直通
      else dout_rgb <= 24'd0;
    end
  end

endmodule
