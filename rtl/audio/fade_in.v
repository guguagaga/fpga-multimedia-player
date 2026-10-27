//===================================================================
// fade_in : 图像层淡入/淡出转场（【无乘法器】重写版，2026-10-07）
//===================================================================
// 【为什么要重写】
//   旧实现是  x × alpha / 256  —— 3 个 8x8 变系数乘法器，占 2 个 DSP，
//   而且 TD 的 pr.timing 里 video_clk 域最差 setup 违例的终点就是
//   `u_fade_in/mult0_syn_1.a[2]`（Fmax 23.933MHz < 25MHz，slack -1.783ns）。
//   这里改成"移位 + 加减"逼近同一个亮度系数，【0 乘法器 / 0 DSP】。
//
// 【作用位置（由顶层决定）】只作用于【图像层】，接在顶层
//   `assign vout_data = display_valid ? fade_img : 24'd0;` 那一句上，
//   也就是在 osd_player_ui / spectrum_display 【之前】 —— 这样转场期间
//   OSD（字幕/进度条/按键格子）和 FFT 频谱柱保持不透明，只有图片淡。
//   数据通路是【纯组合】（无流水寄存），所以像素的时间位置与没插转场时相同。
//
// 【亮度系数怎么算（关键：不用乘法器）】
//   设 x 为某通道 8bit，s = x >> k（k=0..7，三通道各自独立右移、零填充），
//   t = s >> 1（纯布线，零 LUT）。两种模式：
//      移位模式(mode_shift=1)： out = s + e×t        -> coeff = 2^-k + e×2^-(k+1)
//      子模式  (mode_shift=0)： out = x - (s + e×t)  -> coeff = 1 - 2^-k - e×2^-(k+1)
//   k=0 时 s = x，于是：移位模式给出 out = x（全亮，精确透传）；
//   子模式给出 out = x - x = 0（全黑）。所以 18 级电平表能覆盖 1.0 -> 0，
//   且两端都能精确落点，不需要额外的旁路 mux（S_LIVE 恒为 lvl=0 -> 精确透传）。
//   代价：3 x (3 级 8bit 桶形移位器 + 1 加法器 + 1 减法器 + 1 二选一)，纯 LUT。
//
// 【18 级电平表】见 lvl2ctl()，级号 0 = 全亮，17 = 全黑，1 级/帧：
//   1.000 0.984 0.969 0.938 0.906 0.875 0.813 0.750 0.625 0.500
//   0.375 0.250 0.188 0.125 0.094 0.063 0.031 0.000
//   （亮端密、暗端也密；按感知 gamma 折算，中段最大级差约 4%/255，肉眼连续）
//
// 【时序】@59.52Hz（(800x525)/25MHz）
//   淡出 = 16 帧 ≈ 269ms（fade_req 后从 0.984 一路到全黑）
//   淡入 = 16 帧 ≈ 269ms（黑 -> 全亮），结束那一帧 busy 拉低
//   合计 ≈ 32 帧 ≈ 538ms（与旧版 32 帧完全一致）
//
// 【与 sd_card_bmp 的两段式提交握手（消除"硬切黑闪"）】
//   sd 域  : 新帧已进 SDRAM(write_finish) -> 【先不换 buffer】，发 fade_req(toggle)
//   video 域: fade_req -> 旧图淡出到全黑 -> 回 fade_done(toggle)
//   sd 域  : 收到 fade_done -> 再切 disp_buf_idx（新 buffer 下一帧起被读）
//   video 域: 淡出完成同时立刻开始淡入新图
//   => 观感是"旧图渐隐 -> 黑 -> 新图渐显"，黑的那几帧本来就是黑的（读取新
//      buffer 要等下一个 vsync），所以看不出黑闪。
//   兜底：若发生"没有握手的硬切"（img_switch 脉冲），直接"从黑淡入"（旧行为）。
//
// 【首图不转场】首图提交时 disp_buf_idx 是 0->0，不产生 img_switch；且 sd 侧
//   对首图不发 fade_req。所以开机依旧"立刻出图"，不会多 0.5s 黑屏。
//
// 【斜坡计数器只由 vs 下降沿驱动】绝不用 de / display_valid 当计数使能 ——
//   否则转场中途 display_valid 掉落会把计数器卡在半途，画面永久停在半黑。
//===================================================================
module fade_in (
    input  wire        clk,          // video_clk (25MHz)
    input  wire        rst_n,        // 低有效
    input  wire        vs,           // video_clk 域帧同步（下降沿 = 一帧边界）
    input  wire        fade_req,     // 1 拍脉冲：开始淡出（顶层同步过的 sd->video 请求）
    output reg         fade_done,    // toggle：淡出完成（顶层同步回 sd 域去换 buffer）
    input  wire        img_switch,   // 1~2 拍脉冲：无握手硬切的兜底触发（直接从黑淡入）
    input  wire [23:0] din_rgb,      // 图像层（未淡）
    output wire [23:0] dout_rgb,     // 图像层（已淡），纯组合
    output wire        busy          // 1 = 转场进行中（顶层同步给 sd 域做背压）
);

    // ---- 电平表范围：0 = 全亮，17 = 全黑，1 级/帧 ----
    localparam [4:0] LVL_MAX = 5'd17;

    // ---- 状态机 ----
    localparam [1:0] S_LIVE = 2'd0,   // 正常显示（lvl=0，coeff=1，精确透传）
                     S_OUT  = 2'd1,   // 淡出（旧图 -> 黑）
                     S_IN   = 2'd2;   // 淡入（黑 -> 新图）

    reg [1:0] st;
    reg [4:0] lvl;

    // ---- 帧边界：vs 下降沿（每帧一个脉冲）----
    reg vs_d;
    wire vs_nedge = vs_d & ~vs;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vs_d <= 1'b0;
        else        vs_d <= vs;
    end

    // ---- 电平 -> 控制位 {mode_shift, k[2:0], e} ----
    //   mode_shift=1: out = s + e×t        (移位模式)
    //   mode_shift=0: out = x - (s + e×t)  (子模式)
    //   k=0 -> s=x：移位模式 = 全亮透传，子模式 = 全黑
    function [4:0] lvl2ctl;
        input [4:0] i;
        begin
            case (i)
                5'd0 : lvl2ctl = {1'b1, 3'd0, 1'b0};  // 1.000
                5'd1 : lvl2ctl = {1'b0, 3'd6, 1'b0};  // 0.984
                5'd2 : lvl2ctl = {1'b0, 3'd5, 1'b0};  // 0.969
                5'd3 : lvl2ctl = {1'b0, 3'd4, 1'b0};  // 0.938
                5'd4 : lvl2ctl = {1'b0, 3'd4, 1'b1};  // 0.906
                5'd5 : lvl2ctl = {1'b0, 3'd3, 1'b0};  // 0.875
                5'd6 : lvl2ctl = {1'b0, 3'd3, 1'b1};  // 0.813
                5'd7 : lvl2ctl = {1'b0, 3'd2, 1'b0};  // 0.750
                5'd8 : lvl2ctl = {1'b0, 3'd2, 1'b1};  // 0.625
                5'd9 : lvl2ctl = {1'b0, 3'd1, 1'b0};  // 0.500
                5'd10: lvl2ctl = {1'b1, 3'd2, 1'b1};  // 0.375
                5'd11: lvl2ctl = {1'b1, 3'd2, 1'b0};  // 0.250
                5'd12: lvl2ctl = {1'b1, 3'd3, 1'b1};  // 0.188
                5'd13: lvl2ctl = {1'b1, 3'd3, 1'b0};  // 0.125
                5'd14: lvl2ctl = {1'b1, 3'd4, 1'b1};  // 0.094
                5'd15: lvl2ctl = {1'b1, 3'd4, 1'b0};  // 0.063
                5'd16: lvl2ctl = {1'b1, 3'd5, 1'b0};  // 0.031
                5'd17: lvl2ctl = {1'b0, 3'd0, 1'b0};  // 0.000
                default: lvl2ctl = {1'b1, 3'd0, 1'b0};
            endcase
        end
    endfunction

    wire [4:0] ctl        = lvl2ctl(lvl);
    wire       mode_shift = ctl[4];
    wire [2:0] k          = ctl[3:1];
    wire       e          = ctl[0];

    // ---- 三通道独立移位 + 加/减（没有任何乘法器）----
    wire [7:0] r_in = din_rgb[23:16];
    wire [7:0] g_in = din_rgb[15:8];
    wire [7:0] b_in = din_rgb[7:0];

    wire [7:0] r_s = r_in >> k;      // 3 级桶形移位器，零填充
    wire [7:0] g_s = g_in >> k;
    wire [7:0] b_s = b_in >> k;

    wire [7:0] r_t = r_s >> 1;       // 纯布线
    wire [7:0] g_t = g_s >> 1;
    wire [7:0] b_t = b_s >> 1;

    wire [7:0] r_u = r_s + (e ? r_t : 8'd0);
    wire [7:0] g_u = g_s + (e ? g_t : 8'd0);
    wire [7:0] b_u = b_s + (e ? b_t : 8'd0);

    wire [7:0] r_o = mode_shift ? r_u : (r_in - r_u);
    wire [7:0] g_o = mode_shift ? g_u : (g_in - g_u);
    wire [7:0] b_o = mode_shift ? b_u : (b_in - b_u);

    // S_LIVE 时 lvl 恒为 0 -> 移位模式 k=0 -> out = x（精确透传），
    // 因此这里不需要额外的旁路 mux（省 24 个 LUT）。
    assign dout_rgb = {r_o, g_o, b_o};
    assign busy     = (st != S_LIVE);

    // ---- 转场状态机：只由 vs 下降沿推进 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_LIVE;
            lvl       <= 5'd0;
            fade_done <= 1'b0;
        end else begin
            case (st)
                S_LIVE: begin
                    if (fade_req) begin
                        // 开始淡出（旧图 -> 黑）
                        st  <= S_OUT;
                        lvl <= 5'd1;
                    end else if (img_switch) begin
                        // 兜底：无握手硬切 -> 直接从黑淡入（旧行为）
                        st  <= S_IN;
                        lvl <= LVL_MAX;
                    end
                end

                S_OUT: begin
                    if (vs_nedge) begin
                        if (lvl >= LVL_MAX) begin
                            // 已经全黑：告诉 sd 域"可以换 buffer 了"，
                            // 同一拍开始淡入（黑只停留 1 帧）
                            fade_done <= ~fade_done;
                            st        <= S_IN;
                            lvl       <= LVL_MAX - 5'd1;
                        end else begin
                            lvl <= lvl + 5'd1;
                        end
                    end
                end

                S_IN: begin
                    if (vs_nedge) begin
                        if (lvl == 5'd0)
                            st <= S_LIVE;
                        else
                            lvl <= lvl - 5'd1;
                    end
                end

                default: st <= S_LIVE;
            endcase
        end
    end

endmodule
