//===================================================================
// spectrum_display : flat SMOOTH spectrum (linear interp) + beat-reactive
//                    floating notes (no disc, no ring)
//===================================================================
// Layout:
//   - smooth filled spectrum curve along the bottom, log-frequency
//     (blue bass -> red treble), 48 control bars joined by LINEAR
//     interpolation (Q4 fraction) so it stays one continuous curve.
//     Multiplier-free: only gated shifts + adders, 0 DSP.
//   - musical notes spray upward from the bass bars on each bass beat,
//     floating up and fading out.
//   - background : album art dimmed to ~75%.
//
// No CORDIC, no hardware multiplier. Bar index from pixel X (const divide).
//===================================================================
module spectrum_display #(
    // 【第4步 A · 2026-10-07】柱宽（pitch 内实际画出来的列数，1..PITCH）。
    //   只影响"哪些列可见"，`curve`（插值出来的柱高）与 `frac_lut` 一字不改
    //   ⇒ 数值行为逐位不变。想现场调粗细只改这一个参数。
    //   PITCH=8，BAR_W=5 ⇒ 柱 5px + 间隙 3px。
    //   ★2026-10-17 柱数 48 -> 72★（用户要求"竖线条数越多观感越好"）
    //     绘图区宽 X1-X0 = 576，PITCH 必须整除它：
    //         PITCH=12 -> 48 柱   （原来）
    //         PITCH= 8 -> 72 柱   （现在）
    //         PITCH= 6 -> 96 柱   （实测 slices 97.54%，余量吃光，未采用）
    //     ★改柱数时必须成套改这些地方，漏一处就会显示不全：
    //       spectrum_display : PITCH, BAR_W, bar_index/bar_addr 位宽、
    //                          i_m1/i_p1/i_p2 的回绕阈值
    //       spectrum_capture : mem/b1/b2/tilt_mem 的深度、rd_addr* 位宽、
    //                          log_map 的位宽与表、commit 阶段范围、
    //                          两个 48 项衰减/清零循环的上界
    //       top_tf_hdmi_audio: bar_addr* 四条 wire 的位宽
    //     已用 tools/bump_bars.py 做过成套检查（锚点必须唯一命中才写入）。
    parameter [3:0] BAR_W = 4'd5,
    // 【第4步 C · 2026-10-07】柱顶柔和光晕（bloom 近似）：
    //   GLOW_R   = 光晕从柱顶向上延伸多少像素（0 或 GLOW_EN=0 即关闭）
    //   GLOW_MIX = 混色强度（背景朝柱色混 1/2^GLOW_MIX；越小越亮，3=1/8）
    // ================================================================
    // ★2026-10-17 INTERP_EN：跨柱线性插值开关（默认关闭）★
    //
    //   参考图（专业示波器/RTA）的观感是"每根柱独立、之间有明确间隙、
    //   高度锯齿跳变"。而打开插值时，48 根柱会被抹成一条**光滑曲线**，
    //   永远出不来那种尖刺感 —— 这就是"对比不明显"的主因（不是倾斜）。
    //
    //   INTERP_EN = 0 : curve = bar_data2  （每根柱一个高度，矩形，锯齿）
    //   INTERP_EN = 1 : 原来的线性插值（平滑曲线）
    //   关掉后那一片 13 位乘法/加法逻辑会被综合器裁掉，还可能省面积。
    // ================================================================
    parameter        INTERP_EN = 1'b0,
    parameter        GRID_EN = 1'b0, // fixed horizontal lines disabled for image viewing
    parameter        GLOW_EN  = 1'b1,   // 关掉柱顶发光（省混合逻辑，面积紧张时用）
    parameter [3:0]  GLOW_R   = 4'd6,
    parameter [3:0]  GLOW_MIX = 4'd3,
    // 【第4步 D · 2026-10-07】底部细密波段（**独立图层，与音符精灵共存**，不碰 note_x/note_life）
    //   BAND_Y    = 绝对行号（默认 406 = 基线 Y0=405 下方 1px，在柱体之外，互不遮挡）
    //   BAND_H    = 厚度（行数）
    //   BAND_MIN  = 该列插值柱高超过它才点亮（跟幅度走，静音自动消失）
    //   BAND_MIX  = 亮度混色（背景朝柱色混 1/2^N）
    //   BAND_DASH = 分段：每 2^BAND_DASH 列亮 (2^BAND_DASH - 1) 列（细密分段感）
    //   只用既有 curve（已有插值结果）⇒ 不新增任何 BRAM/阵列，0 DSP ✓
    // 【2026-10-07 观感微调·纯参数】用户反馈"比之前好很多，但希望每根线更细、或线更多"：
    //   BAND_H    2 -> 1 : 线更细（1 行）
    //   BAND_DASH 2 -> 1 : 3亮1灭 -> 1亮1灭，线更多更密
    //   纯 parameter 改动，逻辑一字未动；0 DSP、面积几乎免费。
    parameter        BAND_EN   = 1'b1,
    parameter [9:0]  BAND_Y    = 10'd406,
    parameter [3:0]  BAND_H    = 4'd1,
    parameter [7:0]  BAND_MIN  = 8'd24,
    parameter [3:0]  BAND_MIX  = 4'd2,
    parameter [2:0]  BAND_DASH = 3'd1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire        vs,
    input  wire [23:0] din_rgb,
    // 【2026-10-17 视频】1 = 画频谱柱，0 = **纯直通**（原样输出 din_rgb）。
    //   用户要求放视频时不要频谱。做成直通而不是"停掉模块"，是因为
    //   rgb_q <= din_rgb 已经和 de_q 同拍延迟了 2 拍，直接选它就能做到
    //   像素级无差别的直通，不会引入 1 拍错位（错位 1 拍 = 整屏横移一列）。
    input  wire        en,
    input  wire [7:0]  bar_data,      // bar[i-1] (p0)
    output wire [6:0]  bar_addr,
    input  wire [7:0]  bar_data2,     // bar[i]   (p1)
    output wire [6:0]  bar_addr2,
    input  wire [7:0]  bar_data3,     // bar[i+1] (p2)
    output wire [6:0]  bar_addr3,
    input  wire [7:0]  bar_data4,     // bar[i+2] (p3)
    output wire [6:0]  bar_addr4,
    input  wire        beat_pulse,    // 1-cycle pulse on bass beat
    output reg         de_out,
    output reg         vs_out,
    output reg  [23:0] dout_rgb
);

    // ---- layout constants ----
    localparam [9:0] X0      = 10'd32;
    localparam [9:0] PITCH   = 10'd18;    // 数组节距 18px (32*18 = 576) —— 只决定**取哪个柱**
    // ★2026-10-17 竖线数与数组深度解耦★
    //   LINE_PITCH 决定画多少条线，PITCH 决定从哪个柱取值。
    //   两者独立 ⇒ 48 个采样点也能画 96 条线（显示层本来就线性插值）。
    //   ★2026-10-17 再加密：LINE_PITCH 6 -> 4，竖线 96 -> 144 条★
    //   12 能被 4 整除 ⇒ x_in_bar mod 4 = x_in_bar[1:0]，
    //   相位直接取两位，比 6px 版的「减 6 + 比较」还便宜。
    // ★2026-10-17 节距改 6px、占空 50%★
    //   参考图（专业示波器/RTA）的柱是【亮一半、暗一半】，之间有明确间隙。
    //   之前 4px 节距 + 3px 亮 = 75% 占空，柱子连成一片，看不出"独立的柱"。
    //   现在 6px 节距 + 3px 亮 = 50% 占空 -> 576/6 = 96 条，间隙清晰。
    //   ⚠ 每根柱高跨 12px（PITCH），所以每 2 条竖线共用同一高度 ——
    //     这是"96 条线 / 48 个柱高"的必然结果（数组只有 48 深）。
    localparam [9:0] LINE_PITCH = 10'd6;   // 6px 一条 -> 576/6 = 96 条
    localparam [3:0] BAR_W_LINE = 4'd3;   // 亮 3px + 暗 3px = 50% 占空
    localparam [9:0] X1      = 10'd608;
    localparam [9:0] Y0      = 10'd405;   // spectrum baseline (上移到 OSD 播放栏上方，避免重叠)

    // ---- alpha blending (Q4, 0..16): 16=opaque, 0=invisible ----
    localparam [4:0] ALPHA      = 5'd12;  // spectrum fill opacity (12 = 75%)

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
                4'd0:  note_row = 16'h0000;
                4'd1:  note_row = 16'h0000;
                4'd2:  note_row = 16'h0000;
                4'd3:  note_row = 16'h0000;
                4'd4:  note_row = 16'h0380;
                4'd5:  note_row = 16'h0780;
                4'd6:  note_row = 16'h0F80;
                4'd7:  note_row = 16'h1D80;
                4'd8:  note_row = 16'h3980;
                4'd9:  note_row = 16'h0180;
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
    // (每个柱内 12 px 一步)，与旧 Q6 表的分辨率完全相同。
    // 4 bit 权重让插值乘法只用 4 个移位项 + 3 个加法器实现（无 DSP）。
    function [3:0] frac_lut;
        input [4:0] k;
        begin
            case (k)
                4'd0:  frac_lut = 4'd0;
                4'd1:  frac_lut = 4'd1;
                4'd2:  frac_lut = 4'd3;
                4'd3:  frac_lut = 4'd4;
                4'd4:  frac_lut = 4'd5;
                4'd5:  frac_lut = 4'd7;
                4'd6:  frac_lut = 4'd8;
                4'd7:  frac_lut = 4'd9;
                4'd8:  frac_lut = 4'd11;
                4'd9:  frac_lut = 4'd12;
                4'd10:  frac_lut = 4'd13;
                4'd11:  frac_lut = 4'd15;
                4'd12:  frac_lut = 4'd1;
                4'd13:  frac_lut = 4'd2;
                4'd14:  frac_lut = 4'd4;
                4'd15:  frac_lut = 4'd6;
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
    reg       de_d, vs_d;
    wire vs_nedge = vs_d & ~vs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_x <= 10'd0; x_phase <= 0;
            active_y <= 10'd0; y_phase <= 0;
            de_d     <= 1'b0;
            vs_d     <= 1'b0;
        end else begin
            de_d <= de;
            vs_d <= vs;
            if (vs_nedge) begin
                active_y <= 10'd0; y_phase <= 0;
                active_x <= 10'd0; x_phase <= 0;
            end else if (de) begin
                active_x <= active_x + (x_phase != 0);
                x_phase <= (x_phase == 1) ? 0 : x_phase + 1'b1;
            end else if (de_d) begin
                active_y <= active_y + (y_phase != 0);
                y_phase <= (y_phase == 2) ? 0 : y_phase + 1'b1;
                active_x <= 10'd0; x_phase <= 0;
            end
        end
    end

    // ---- bar index / fraction from X ----
    wire       in_xrange = (active_x >= X0) && (active_x < X1);
    wire [9:0] bx        = active_x - X0;
    wire [6:0] bar_index = bx / PITCH;
    wire [4:0] x_in_bar  = bx - (bar_index * PITCH);   // 0..17

    // ★2026-10-17 回绕阈值必须跟着柱数走★
    //   72 柱 => 合法下标 0..71，所以：
    //     i_m1 : (i==0)  ? 71 : i-1
    //     i_p1 : (i==71) ? 0  : i+1
    //     i_p2 : (i==70) ? 0 : (i==71) ? 1 : i+2
    //   ⚠ 从 96 柱改 72 柱时这三个数曾**漏改**（还留着 95/94），
    //     会让柱 71 读到越界地址、柱 70 的右邻居索引错位 —— 表现为最右侧
    //     一两根柱异常。已修正为下面的值。
    //   以后改柱数时，这三个阈值必须与 PITCH 一起改（清单见文件顶部）。
    wire [6:0] i    = bar_index;
    wire [6:0] i_m1 = (i == 7'd0)  ? 7'd31 : (i - 7'd1);
    wire [6:0] i_p1 = (i == 7'd31) ? 7'd0  : (i + 7'd1);
    wire [6:0] i_p2 = (i == 7'd30) ? 7'd0  : (i == 7'd31) ? 7'd1 : (i + 7'd2);

    assign bar_addr  = i_m1;   // ★2026-10-17 p0 = bar[i-1] 现在是**峰值保持**★
    assign bar_addr2 = i;      // p1 = bar[i]
    assign bar_addr3 = i_p1;   // p2 = bar[i+1]
    assign bar_addr4 = i_p2;   // p3 = bar[i+2]（未使用）

    // ---- pipeline (align with sync bar read) ----
    reg [9:0]  ay_q, ax_q;
    reg [6:0]  bar_index_q;
    reg [4:0]  x_in_bar_q;
    reg        de_q, vs_q;
    reg [23:0] rgb_q;
    reg        in_xrange_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ay_q        <= 10'd0;
            ax_q        <= 10'd0;
            bar_index_q <= 7'd0;
            x_in_bar_q  <= 5'd0;
            de_q        <= 1'b0;
            vs_q        <= 1'b0;
            rgb_q       <= 24'd0;
            in_xrange_q <= 1'b0;
        end else begin
            ay_q        <= active_y;
            ax_q        <= active_x;
            bar_index_q <= bar_index;
            x_in_bar_q  <= x_in_bar;
            de_q        <= de_d;
            vs_q        <= vs_d;
            rgb_q       <= din_rgb;
            in_xrange_q <= in_xrange;
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
    wire [7:0]        p1 = bar_data2;              // bar[i]   (left point)
    wire [7:0]        p2 = bar_data3;              // bar[i+1] (right point)
    wire signed [8:0] p1_9 = {1'b0, p1};
    wire signed [8:0] p2_9 = {1'b0, p2};
    wire signed [8:0] diff = p2_9 - p1_9;          // -248 .. +248

    wire [3:0] F = frac_lut(x_in_bar_q);           // Q4 fraction, 0..15

    // gated shift terms, summed in 13-bit signed (|sum| <= 248*15 = 3720)
    wire signed [12:0] tp0 = F[0] ? {{4{diff[8]}}, diff}         : 13'sd0;
    wire signed [12:0] tp1 = F[1] ? {{3{diff[8]}}, diff, 1'b0}   : 13'sd0;
    wire signed [12:0] tp2 = F[2] ? {{2{diff[8]}}, diff, 2'b00}  : 13'sd0;
    wire signed [12:0] tp3 = F[3] ? {{1{diff[8]}}, diff, 3'b000} : 13'sd0;
    wire signed [12:0] prod = tp0 + tp1 + tp2 + tp3;

    wire signed [10:0] p1_11     = {3'b0, p1};
    wire signed [10:0] frac_term = prod >>> 4;     // (p2-p1)*F/16, |.| <= 232
    wire signed [10:0] yline     = p1_11 + frac_term;  // -232 .. +480

    // clamp curve height to 0..248 (same clamp/saturation as before)
    // 插值结果（INTERP_EN=1 时用）
    wire [7:0] curve_interp = (yline < 11'sd0) ? 8'd0 :
                              (yline > 11'sd248) ? 8'd248 : yline[7:0];

    // ★最终柱高★ INTERP_EN=0 时直接用本柱高度 ⇒ 矩形柱、锯齿清晰
    wire [7:0] curve = INTERP_EN ? curve_interp : bar_data2;

    // ---- curve geometry ----
    wire [9:0] curve_top = Y0 - {2'b0, curve};
    // 【第4步 A】可见性掩码：pitch 内前 BAR_W 列画柱，其余留作间隙。
    //   注意这里**只**屏蔽列，不改 curve/frac_lut ⇒ 可见列的柱高数值与改动前逐位相同。
    // ★2026-10-17 竖线相位从 x_in_bar_q 直接取★
    //   PITCH=12 能被 LINE_PITCH=6 整除 ⇒ bx mod 6 == x_in_bar mod 6，
    //   所以不需要把 bx 打进流水线，也不需要除法器，只要一次
    //   "减 6 / 比较"。
    //   LINE_PITCH=6 时，柱内相位 = x_in_bar mod 6
    //   （12 是 6 的倍数 ⇒ bx mod 6 == x_in_bar mod 6）。
    //   x_in_bar ∈ 0..11，所以 mod 6 只差一次「减 6」。
    wire [3:0] line_col = (x_in_bar_q >= 5'd12) ? (x_in_bar_q - 5'd12)
                                            : (x_in_bar_q >= 5'd6) ? (x_in_bar_q - 5'd6)
                                              : x_in_bar_q[3:0];   // 0..5  (18 = 3x6)
    wire in_bar_w = (line_col < BAR_W_LINE);   // 3 亮 3 灭 -> 96 条
    wire in_fill = in_xrange_q && in_bar_w && (ay_q >= curve_top) && (ay_q <= Y0);
    wire in_edge = in_fill && (ay_q < (curve_top + 10'd3));

    // ==================================================================
    // ★2026-10-17 峰值保持白点（PEAK HOLD DOT）—— 专业频谱的招牌★
    //
    //   来源：spectrum_capture 的 mem[]，经 p0（bar_data）输出。
    //   它与柱体 b1/b2 用**不同的释放速度**（峰值 -1/帧，柱体 -2/帧），
    //   所以白点会比柱子慢半拍回落 —— 这正是要的观感。
    //
    //   插值：**单点、不跨柱插值**。峰值是"保持"量，本来就不该被邻柱平均掉。
    //
    //   画法：白点 3px 高，且**必须落在柱体内部**（ay_q >= curve_top）——
    //   否则当柱子回落而峰值还高时，白点会浮在柱子上面，看起来像噪点。
    //   因为峰值衰减比柱体慢，正常情况 peak >= curve 恒成立，
    //   所以白点总是贴着柱顶出现。
    //
    //   配色：白点用"柱色提亮到接近白"而不是纯白，这样在亮背景上也看得见
    //   （用 (edge>>1)+160 而不是 255，纯白在浅色专辑封面上会糊掉）。
    //   纯比较器 + 移位 + 加减 ⇒ **0 BRAM / 0 DSP**。
    // ==================================================================
    // ⚠ 只用 p0（bar_data）这一个抽头，**不在柱间做插值**：
    //   p3（bar_data4）在 capture 侧恒 0（该读端口没有对应存储体），
    //   拿它当第二个控制点会把峰值曲线拉塌。单点即足够，
    //   因为峰值本身是"保持"量，本来就不该被邻柱平均掉。
    wire [7:0] pk1 = bar_data;                    // peak[i]，来自 capture 的 mem[]
    wire [7:0] peak = pk1;
    wire [9:0]        peak_top = Y0 - {2'b0, peak};

    // 白点：柱体范围内、柱顶 3 像素
    wire in_peakdot = in_xrange_q && in_bar_w &&
                      (ay_q >= curve_top) &&               // 必须落在柱体内
                      (ay_q <= peak_top) &&                 // 不高于峰值
                      (ay_q >= (peak_top > 10'd3 ? peak_top - 10'd3 : 10'd0));

    // （白点配色 pk_r/pk_g/pk_b 在下方 edge_*2 声明之后定义 —— Verilog 要求先声明后使用）

    // ================= 【第4步 C · 2026-10-07】柱顶柔和光晕（bloom 近似）=================
    // 参考图里柱子周围有一圈柔和白光。这里用最省的做法做"顶端光晕"：
    //   柱顶之上 GLOW_R 像素、且仍在柱宽范围内 ⇒ 背景按 1/2^GLOW_MIX 的比例混向柱色。
    //   纯比较器 + 移位 + 加减 ⇒ **0 BRAM / 0 DSP** ✓（红线要求）。
    //   半径与混色比例都是**参数**，现场可调；GLOW_EN=0 即完全关闭（回到只有 edge/fill/bg）。
    wire [9:0] glow_lo = (curve_top > {6'b0, GLOW_R}) ? (curve_top - {6'b0, GLOW_R}) : 10'd0;
    wire in_glow = GLOW_EN && in_xrange_q && in_bar_w &&
                   (ay_q < curve_top) && (ay_q >= glow_lo) && (glow_lo != curve_top);

    // ---- gradient colors ----
    // 【2026-10-20 32 柱】渐变表仍是 48 项（蓝→红），柱数变成 32，
    //   所以下标按 1.5 倍展开（i + i/2 = 0..46），让整条彩虹仍然铺满全屏。
    //   不做这一步会只用到表的前 32 项 —— 右端看不到红色。
    wire [23:0] grad  = grad_lut(bar_index_q + (bar_index_q >> 1));
    wire [7:0]  gr    = grad[23:16];
    wire [7:0]  gg    = grad[15:8];
    wire [7:0]  gb    = grad[7:0];
    wire [7:0]  edge_r = (gr >> 1) + 8'd128;
    wire [7:0]  edge_g = (gg >> 1) + 8'd128;
    wire [7:0]  edge_b = (gb >> 1) + 8'd128;

    // ---- background : album art dimmed to ~75% ----
    wire [7:0] bg_r = rgb_q[23:16] - (rgb_q[23:16] >> 2);
    wire [7:0] bg_g = rgb_q[15:8]  - (rgb_q[15:8]  >> 2);
    wire [7:0] bg_b = rgb_q[7:0]   - (rgb_q[7:0]   >> 2);

    // ==================================================================
    // ★2026-10-17 dB 参考网格线（GRID）—— 专业分析仪的标尺★
    //
    //   任何一台专业 RTA / 频谱分析仪的背景都有一组水平参考线。
    //   没有它，柱子多高全靠感觉；有了它，才像"仪器"而不是"动画"。
    //
    //   刻度换算（本设计的柱高是**对数**刻度，柱高本身就是 dB 标尺）：
    //       bar = contrast_lut(leading_one(mag))
    //     mag 每翻一倍 ⇒ leading_one +1 ⇒ 柱高升一档 ⇒ 约 6.02 dB。
    //   这里取 4 条线，按柱高满量程（248）均分：
    //       25%(62) / 50%(124) / 75%(186) / 100%(248，满刻度参考)
    //
    //   实现：**只叠在背景上**（条件带 `!in_fill`），柱子永远盖住线，
    //   不会把柱子"划断"。颜色是背景提亮 1/4（移位+加，0 DSP）。
    //   4 个比较器 + 3 个加法 ⇒ 约 60-100 LUT。
    //
    //   ⚠ 为什么不做垂直频率线：本设计的柱位是**按 bin 混合分区**
    //     （低频 2 bin/柱、高频 3 bin/柱），不是严格等倍频程；
    //     画"倍频程"竖线会与柱位对不齐，反而显得不专业。宁可只画水平线。
    // ==================================================================
    localparam [9:0] GRID_25  = Y0 - 10'd62;
    localparam [9:0] GRID_50  = Y0 - 10'd124;
    localparam [9:0] GRID_75  = Y0 - 10'd186;
    localparam [9:0] GRID_100 = Y0 - 10'd248;

    wire in_gridline = GRID_EN && in_xrange_q &&
                       ((ay_q == GRID_25) || (ay_q == GRID_50) ||
                        (ay_q == GRID_75) || (ay_q == GRID_100)) &&
                       !in_fill;                   // 柱子优先，网格不划断柱子

    wire [7:0] grid_r = bg_r + (bg_r >> 2);
    wire [7:0] grid_g = bg_g + (bg_g >> 2);
    wire [7:0] grid_b = bg_b + (bg_b >> 2);

    // ---- alpha blend : spectrum over background (translucent / glass) ----
    // out = (spectrum*ALPHA + bg*(16-ALPHA)) >> 4
    wire [7:0] fill_r  = alpha_blend(gr,     bg_r, ALPHA);
    wire [7:0] fill_g  = alpha_blend(gg,     bg_g, ALPHA);
    wire [7:0] fill_b  = alpha_blend(gb,     bg_b, ALPHA);
    wire [7:0] edge_r2 = alpha_blend(edge_r, bg_r, ALPHA);
    wire [7:0] edge_g2 = alpha_blend(edge_g, bg_g, ALPHA);
    wire [7:0] edge_b2 = alpha_blend(edge_b, bg_b, ALPHA);

    // ---- ★2026-10-17 峰值保持白点配色★ ----
    //   用"柱色提亮到接近白"而不是纯白 255：
    //   浅色专辑封面上纯白会糊掉，提亮到 ~200 既醒目又保留柱色identity。
    //   (edge>>1)+160 是**凸组合**，全程无符号，结果必然在 [160, 288] 内，
    //   8 位加法器会自然截到 255 —— 不需要额外的饱和逻辑。
    wire [7:0] pk_r = (edge_r2 >> 1) + 8'd160;
    wire [7:0] pk_g = (edge_g2 >> 1) + 8'd160;
    wire [7:0] pk_b = (edge_b2 >> 1) + 8'd160;

    // ---- 【第4步 C】光晕色：背景朝柱色混 1/2^GLOW_MIX（纯移位加法，0 DSP）----
    //   ⚠ 不要写 (edge-bg)>>N 那种"带符号差值"形式：柱色可能比背景**暗**，
    //     8 位无符号会下溢回绕（实测 glow_r 算出 206 而 bg=144/edge=132 ✗）。
    //   改成**凸组合**形式，全程无符号、结果必然落在 [min(bg,edge), max(bg,edge)] 内 ✓：
    //       glow = (bg*(2^N-1) + edge) >> N        （N=3 即 7/8 背景 + 1/8 柱色）
    //   bg*(2^N-1) 用 (bg<<N) - bg 实现 ⇒ 仍是移位+加减，0 DSP ✓
    wire [11:0] glow_r12 = (({4'b0, bg_r} << GLOW_MIX) - {4'b0, bg_r} + {4'b0, edge_r2}) >> GLOW_MIX;
    wire [11:0] glow_g12 = (({4'b0, bg_g} << GLOW_MIX) - {4'b0, bg_g} + {4'b0, edge_g2}) >> GLOW_MIX;
    wire [11:0] glow_b12 = (({4'b0, bg_b} << GLOW_MIX) - {4'b0, bg_b} + {4'b0, edge_b2}) >> GLOW_MIX;
    wire [7:0]  glow_r = glow_r12[7:0];
    wire [7:0]  glow_g = glow_g12[7:0];
    wire [7:0]  glow_b = glow_b12[7:0];

    // ---- 【第4步 D】底部细密波段（独立图层）----
    //   ⚠ 与音符精灵**共存**：本图层不读写 note_x/note_life/note_next，只在颜色选择里
    //     排在音符之后（音符像素仍然优先）⇒ 两者互不干扰 ✓
    //   分段图案：active_x 的低 BAND_DASH 位非零 ⇒ 亮（默认 3 亮 1 灭，细密感）
    wire        band_dash_on = (BAND_DASH == 3'd0) ? 1'b1 : (bx[BAND_DASH-1:0] != {BAND_DASH{1'b0}});
    wire        in_band = BAND_EN && (ay_q >= BAND_Y) && (ay_q < (BAND_Y + {6'b0, BAND_H})) &&
                          (curve > BAND_MIN) && band_dash_on;
    //   亮度：背景朝柱色凸组合（同 C，全程无符号 ⇒ 必落在 [min,max]）
    wire [11:0] band_r12 = (({4'b0, bg_r} << BAND_MIX) - {4'b0, bg_r} + {4'b0, edge_r2}) >> BAND_MIX;
    wire [11:0] band_g12 = (({4'b0, bg_g} << BAND_MIX) - {4'b0, bg_g} + {4'b0, edge_g2}) >> BAND_MIX;
    wire [11:0] band_b12 = (({4'b0, bg_b} << BAND_MIX) - {4'b0, bg_b} + {4'b0, edge_b2}) >> BAND_MIX;
    wire [7:0]  band_r = band_r12[7:0];
    wire [7:0]  band_g = band_g12[7:0];
    wire [7:0]  band_b = band_b12[7:0];

    // ---- beat-reactive notes ----
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    wire [9:0] bass_x0 = X0 + (lfsr[3:0]  * PITCH) + 10'd4;
    wire [9:0] bass_x1 = X0 + (lfsr[7:4]  * PITCH) + 10'd4;
    wire [9:0] bass_x2 = X0 + (lfsr[11:8] * PITCH) + 10'd4;

    reg [9:0] note_x [0:7];
    reg [9:0] note_y [0:7];
    reg [6:0] note_life [0:7];   // 0..63, 0 = inactive
    reg [2:0] note_next;         // round-robin spawn pointer (0..7)

    // ========================================================================
    // 【2026-10-20 面积】NOTE_EN = 0 把整个音符精灵图层做成**死逻辑**：
    //   本块（spawn + 上浮 + 衰减）是 8 个粒子 ×(10+10+7) = **216 个 FF**，
    //   它们的写使能全在这里。NOTE_EN=0 时下面 else 分支恒不执行 ⇒ 综合器可以
    //   把 note_x/note_y/note_life 全部剪掉；绘制侧读到的 note_life 恒 0，
    //   于是 "note_life>0" 的 8 组比较、16×16 精灵表、优先级链也一起消失。
    //   代价：柱底不再有小音符上浮（纯装饰）。
    //   要恢复：把 NOTE_EN 改回 1'b1，其余一行都不用动。
    // ========================================================================
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
                note_x[note_next]              <= bass_x0;
                note_y[note_next]              <= 10'd400;
                note_life[note_next]           <= 7'd63;
                note_x[(note_next + 1) & 3'd7] <= bass_x1;
                note_y[(note_next + 1) & 3'd7] <= 10'd400;
                note_life[(note_next + 1) & 3'd7] <= 7'd63;
                note_x[(note_next + 2) & 3'd7] <= bass_x2;
                note_y[(note_next + 2) & 3'd7] <= 10'd400;
                note_life[(note_next + 2) & 3'd7] <= 7'd63;
                note_next <= (note_next + 3) & 3'd7;
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
            if (note_life[nk2] > 7'd0 &&
                ax_q >= note_x[nk2] && ax_q < (note_x[nk2] + 10'd16) &&
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
        if (note_hit[0])      hit_lv = note_life[0][5:4];
        else if (note_hit[1]) hit_lv = note_life[1][5:4];
        else if (note_hit[2]) hit_lv = note_life[2][5:4];
        else if (note_hit[3]) hit_lv = note_life[3][5:4];
        else if (note_hit[4]) hit_lv = note_life[4][5:4];
        else if (note_hit[5]) hit_lv = note_life[5][5:4];
        else if (note_hit[6]) hit_lv = note_life[6][5:4];
        else if (note_hit[7]) hit_lv = note_life[7][5:4];
    end

    // ---- color select ----
    //   优先级：音符精灵 > ★峰值白点★ > 柱顶亮边 > 柱体填充 > 柱顶光晕 > 底部波段 > ★dB网格★ > 背景
    //   ★2026-10-17：白点插在音符之后、亮边之前 —— 它要盖住亮边，
    //     但不能盖住音符精灵（精灵是前景动效，优先级最高）。
    //     dB 网格排在最后（仅次于背景）—— 它只是标尺，任何实际内容都要盖住它。
    reg [23:0] color_sel;
    always @(*) begin
        if (any_note)         color_sel = note_color(hit_lv);
        else if (in_peakdot)  color_sel = {pk_r, pk_g, pk_b};          // ★峰值保持白点★
        else if (in_edge)     color_sel = {edge_r2, edge_g2, edge_b2};
        else if (in_fill)     color_sel = {fill_r, fill_g, fill_b};
        else if (in_glow)     color_sel = {glow_r, glow_g, glow_b};
        else if (in_band)     color_sel = {band_r, band_g, band_b};   // 【第4步 D】底部细密波段
        else if (in_gridline) color_sel = {grid_r, grid_g, grid_b};   // ★dB 参考网格★
        else                  color_sel = {bg_r, bg_g, bg_b};
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
            if (de_q)
                dout_rgb <= en ? color_sel : rgb_q;   // en=0 -> 原样直通
            else
                dout_rgb <= 24'd0;
        end
    end

endmodule
