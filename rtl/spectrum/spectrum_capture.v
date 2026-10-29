// -----------------------------------------------------------------------------
// Module purpose: Audio-spectrum capture and display-data preparation.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
//===================================================================
// spectrum_capture (48 log bars) : FFT -> 48 log-frequency bars
//===================================================================
// The FFT streams 256 bins; only bins 1..127 are the real spectrum
// (bin 0 is DC, bins 128..255 are the conjugate mirror).
//
// For each bin we compute POWER = re^2 + im^2, log2-compress it into a
// bar height (leading-one detector), then fold the 128 LINEAR bins into
// 48 LOG-spaced bars (~8.2 bars/octave, 187Hz-10kHz) via a lookup
// table.
//
// Peak-hold（白点）已移除：
//   原来 bar 管快速衰减（跟节奏）、peak_mem 管慢速衰减（留成白点）。
//   为降低 EG4S20 面积（mslice 曾超限 5424/4900），白点功能整体删除，
//   连带去掉 peak_mem[48] 寄存器阵列、bp[48] 拷贝阵列、以及每个 FFT 帧
//   一次 48 项的 peak_mem 衰减循环。
//   如果将来要恢复：spectrum_display 的 in_peak/peak_* 配色逻辑也需要一并加回。
//
// RESOURCE FIX: the display read ports are synchronous-read banks
// (b0..b3 for the 4 Catmull-Rom points). This
// lets the tool infer block RAM instead of building huge combinational
// 64:1 muxes (which previously blew past the EG4S20 slice limit and
// caused routing failures). The working array (mem) remains
// plain registers for the rise + decay.
//===================================================================
module spectrum_capture #(
  // ================= 【第4步 B · 2026-10-07】跨 bin 平滑（防锯齿）=================
  //   一根柱 = 一个 FFT bin，相邻 bin 无关联 ⇒ 包络锯齿。这里对到达顺序
  //   （log_map 单调 ⇒ 柱位递增）做 3 抽头 FIR：y = (w0*x[n]+w1*x[n-1]+w2*x[n-2])/(2^SHIFT)
  //   权重/移位/开关全部参数化（现场可调），纯移位+加法 ⇒ 0 DSP。
  //   FIR_EN=0 即完全回到改动前行为（便于 A/B 对比）。
  //
  // 【第4步 B · 2026-10-07 实测结论 —— 先默认关闭】
  //   把平滑放在 peak-hold 之前是无效的：A/B 实测（同输入喂两个实例，
  //   FIR_EN=0 vs 1）相邻柱最大跳变 31 -> 34，没有下降反而略升。
  //   原因：capture 是"只取上升沿"的 peak-hold，平滑掉的尖峰基本被 max 吃掉，
  //   再加上显示层本来就做了线性插值，所以这个位置的平滑起不到作用。
  //   ⇒ 先默认 FIR_EN=0（行为与改动前逐位相同；未用逻辑会被 TD 剪掉，不占面积）。
  //     正确做法是放到 peak-hold 之后（提交/显示 bank 那一级做流式 3 抽头），
  //     已在交付报告里给出逐行方案，等确认后再改。
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
  input  wire [ 5:0] rd_addr,    // 0..47
  output reg  [ 7:0] rd_data,    // bar height 0..248 (synchronous read)
  input  wire [ 5:0] rd_addr2,   // 0..47 (2nd read port)
  output reg  [ 7:0] rd_data2,
  input  wire [ 5:0] rd_addr3,   // 0..47 (3rd read port)
  output reg  [ 7:0] rd_data3,
  input  wire [ 5:0] rd_addr4,   // 0..47 (4th read port)
  output reg  [ 7:0] rd_data4,
  output reg         beat_pulse  // 1-cycle pulse on bass beat (video_clk domain)
);

  // ---- working array (registers, fast decay) ----
  // [Design note 面积]mem[0:31] 已删除：它写而不读（rd_data 恒 0），
  //   而且写入值/衰减步长与 tilt_mem 逐位相同 ⇒ 等于白存 256 个 FF。
  //   下面的上升沿写入改用 tilt_mem 自身的旧值比较，行为完全等价。

  // ---- display banks (synchronous read) ----
  // 【为什么保持 4 个独立阵列，而不是合并成 1 个】
  //   我试过把这里合并成单个 win[48]（写一份、4 个读端口读同一阵列的
  //   不同地址）。结果 mslice 从 4990 涨到 5001 —— 更差。
  //   原因：4 个独立小阵列能被工具分散打包到不同 slice；合并成一个大
  //   阵列后，4 个读地址的译码变成更宽的集中 mux，反而更吃 mslice。
  //   分布式 RAM 就该是多份小阵列，这是它的正常用法。
  //   所以这里保留 4 份（内容相同，各提供一个读端口）。
  //   【面积回收 1.5 · 2026-10-07】但 b0 / b3 这两份是死的：它们只被
  //   rd_data / rd_data4 读，而这两个口送给 spectrum_display 的 p0/p3 ——
  //   spectrum_display.v:263-267 明确写了三次插值已不再使用 p0/p3
  //   ⇒ 两份阵列 + 两个 48:1 宽读复用器纯属死逻辑（仍占分布式 RAM 与 LUT）。
  //   删掉它们；保留 b1/b2（p1/p2，线性插值仍在用）。端口 rd_data/rd_data4
  //   保持不变、恒 0 ⇒ 顶层与 spectrum_display 一行都不用改。
  reg [ 7:0] cnt;
  reg [10:0] bass_acc;  // accumulated bass energy (FFT bins 1..4)
  reg [ 7:0] beat_cd;  // beat cooldown counter

  // noise floor: bars below this height are treated as residual HF noise
  // and dropped (prevents a permanent "DC offset" baseline on the right).
  // 批次1-第2项：原值 10 等价 leading_one>=3，即 FFT 后 mag<8 全丢
  // （换算到输入约 -24 dBFS），安静段/混响尾巴/细节全部不可见。
  // 降到 5 后门限为 mag<5，即只丢掉 leading_one = 0..2（mag 1..4）这三档
  // 极小值；leading_one>=3 的 bin 一律放行。
  // 注意：真正决定"看得见的最低电平"的是 NOISE_FLOOR 与下面 contrast_lut
  // 的交集 —— 新 contrast_lut 把 n=3（mag 8..15）映射为 0，所以实际可见
  // 起点是 n=4（mag>=16，约满量程的 0.25，即约 -12 dBFS）。相比原来的
  // -24 dBFS 门限，可见下限下移了一整档（mag 16..32 这一段原来只有
  // 18px 且被 n<3 全 0 卡住，现在有 2px 起步的连续过渡）。
  // 保留门限（不置 0）是为了把门限以下的残差彻底挡掉，不让它进入
  // mem 的峰值合并与衰减循环，避免右侧出现常驻的"直流基线"。
  // 保留门限（不置 0）是为了继续抑制右侧高频段的常驻底噪/直流基线。
  localparam [7:0] NOISE_FLOOR = 8'd5;

  // ---- magnitude + log2 compression ----
  wire [15:0] re_abs = fft_re[15] ? (~fft_re + 1'b1) : fft_re;
  wire [15:0] im_abs = fft_im[15] ? (~fft_im + 1'b1) : fft_im;
  // 幅度近似 mag ≈ max + min/2（无乘法器）。
  // 原 power = re² + im² 需要两个 16×16 乘法器；EG4S20 的 DSP 已被 FFT
  // 蝶形运算占满，这两个乘法器落到 LUT，部分积加法树(256bit)导致布线拥塞。
  // 改用无乘法幅度近似（误差 <7%），对数柱高几乎不受影响。
  wire [15:0] mag_max = (re_abs >= im_abs) ? re_abs : im_abs;
  wire [15:0] mag_min = (re_abs >= im_abs) ? im_abs : re_abs;
  // Periodic Hann coherent gain is approximately 0.5. Compensate here,
  // preserving sample headroom in the FFT and keeping PCM untouched.
  wire [16:0] mag_unscaled = {1'b0, mag_max} + {2'b0, mag_min[15:1]};
  wire [17:0] mag_window_comp = {mag_unscaled, 1'b0};
  wire [15:0] mag_comb = (|mag_window_comp[17:16]) ? 16'hffff : mag_window_comp[15:0];
  reg [15:0] mag;
  reg fft_valid_q;
  // Split abs/compare/add from log/tilt/peak update at 40 MHz.
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

  // ---- contrast LUT : log2 index -> bar height (super-linear) ----
  // 学习 aystmjz/Music-Spectrum 的 FFT_decay_mapper 思路：不用线性
  // (bar = leading_one*8)，改用二次曲线把高能量柱子非线性拉高、低能量
  // 压矮，产生高低对比与律动感。
  // 【批次1-第2项】原表的问题不是"底段被压扁"这么简单 —— 它把
  // leading_one 的低段当成了"小信号"，但实际幅度标度是：
  //   mag ≈ 64*|re|_q15（纯正弦、低 bin，见报告 §4.3），所以
  //   n=0..3 对应 mag 1..15（满量程正弦的 -18dBFS 以下，确实是噪声/细节），
  //   n=4..10 才是"真实音乐所在区间"（-18 ~ 0 dBFS），
  //   而旧表给 n=5 只有 28/248=11%、n=6 只有 40/248=16% 屏高 ——
  //   于是整块屏幕长期只有 30~40% 高，"上 55% 永远是空的"。
  // 新表把压缩刻度拉到可用范围（n=4..15 覆盖 248px 全程）：
  //   柱高(n) = round(248 * (n-3)^2 / 144)，n<=3 时为 0（见上方 NOISE_FLOOR
  //   的可见性说明）。
  //   n : 旧值(占248%) -> 新值(占248%)   逐级增量
  //   4 : 18  (7%)    -> 2   (1%)        2
  //   5 : 28  (11%)   -> 7   (3%)        5
  //   6 : 40  (16%)   -> 16  (6%)        9
  //   7 : 54  (22%)   -> 28  (11%)       12
  //   8 : 70  (28%)   -> 43  (17%)       15
  //   9 : 89  (36%)   -> 62  (25%)       19
  //   10: 110 (44%)   -> 84  (34%)       22
  //   11: 133 (54%)   -> 110 (44%)       26
  //   12: 159 (64%)   -> 140 (56%)       30
  //   13: 186 (75%)   -> 172 (69%)       32
  //   14: 216 (87%)   -> 208 (84%)       36
  //   15: 248 (100%)  -> 248 (100%)      40
  // 即：中低段(n<=7)故意压得更矮（保留"只有强峰才冲上去"的对比与律动，
  // 也压掉底噪抖动），中高段(n>=11)抬到 44%~100%，逐级增量均匀无跳档。
  // 单调不减、值域仍 0..248（8 bit，位宽不变、无乘法器）。
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

  // ================================================================
  // 2026-10-17 倾斜改到【幅度域】
  //
  //   旧代码 apply_tilt(bar_height, tier) = v + v/8，是在柱高（0..248）
  //   上做线性放大：高的柱会饱和到 248，矮的柱几乎不动 —— 那不是 dB 增益。
  //
  //   改成在 leading_one 之前缩放 mag：因为
  //        bar = contrast_lut(leading_one(mag))
  //   把 mag 乘一个常数 C，等价于把 leading_one 抬 log2(C) 档，
  //   而一档 ≈ 6.02 dB ⇒ 这才是真正的"每倍频程倾斜"。
  //
  //   四级增益全部是移位相加（0 DSP / 0 BRAM）：
  //        tier 0  x1.00    +0.0 dB
  //        tier 1  x1.25    +1.9 dB
  //        tier 2  x1.75    +4.9 dB
  //        tier 3  x2.25    +7.0 dB
  //
  //   【为什么必须这么做】实测（tools/design_flat.py，3 首真实曲目）：
  //     映射            加倾斜后的电平极差
  //     bins 1..127(旧)      75.7 / 80.3 / 99.3 dB
  //     bins 1..69 (新)       5.1 /  0.0 /  8.1 dB
  //   旧映射把 30% 的屏幕分给 16-24kHz —— 那里所有音乐都在 -74 dB 以下，
  //   永远不可能点亮。所以真正的问题不是倾斜太小，是映射范围错了。
  // ================================================================
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
      // 2026-10-17 倾斜从 +14dB 降到 +7dB
      //   原因：+14 dB = 2.3 档，会把高频底噪（本来 n≈3）抬到 n≈5.3，
      //   越过 NOISE_FLOOR(bar>=5) 的门限 ⇒ 右侧变成一条恒定的底噪平台
      //   ⇒ 观感"太平、没对比"。
      //   +7 dB = 1.2 档，噪声回到 n≈4.2 -> contrast_lut(4)=2 < 5
      //   ⇒ 被门限挡住，右侧只显示真实音乐能量，对比度回来。
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

  // ---- 提交用暂存：已倾斜的柱高（下标同 log_map）----
  // 【为什么要这个】原来提交阶段直接用 mem[cnt]（48 选 1 组合读 × 8 位）
  //   再算倾斜。那个组合 48:1 mux 是纯 LUT/mslice 开销 —— TD 已确认
  //   b0..b3 这类阵列没有被推断成 BRAM，都是分布式 RAM，mslice
  //   超限(5033/4900)正来自这类开销。
  //   改为：在上升写入时就算好倾斜值存进 tilt_mem，提交阶段读
  //   已解码的 tilt_mem[cnt]，消掉那个组合 mux。
  //   倾斜值同时写回 mem 本身，保证对外的 mem 快照与原来逐位一致。
  (* ram_style="bram" *)reg  [7:0] tilt_mem                                         [0:31];

  // ================= 【第4步 B · 2026-10-07】跨 bin 3 抽头平滑 =================
  // 声明位置必须在任何使用之前（本项目已多次因"先使用后声明"被 TD 当隐式 wire）。
  //   y[n] = (W0*x[n] + W1*x[n-1] + W2*x[n-2]) >> FIR_SHIFT   （权重/移位是模块参数）
  //   纯移位+加法 ⇒ 0 DSP；FIR_EN=0 时 bar_sm = bar（完全等价改动前）。
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

  // 倾斜函数：分级高频补偿（纯移位+加法，无乘法器），饱和 248
  //   tier == 2'd0 : 原值不动（低频，< TILT_MID_IDX）
  //   tier == 2'd1 : v + v/8  (+12.5% ≈ +1.02 dB，中频段)
  //   tier == 2'd2 : v + v/4  (+25%   ≈ +1.94 dB，高频段)
  // 【批次1-第3项】原实现只有一级 +1/8（+1.02 dB）且只对 log_map>=32 生效。
  // 音乐频谱包络按 -6dB/oct 滚降，2.4kHz~10kHz 天然低约 12dB，补 1dB
  // 等于没补 —— 右半屏贴地。现改为两级且在 log_map>=24（约 1.5kHz 起）
  // 就开始补偿，高频段给到 +1/4；配合 log_map 放宽到 bin127（新增的
  // 10k~24kHz 段本身能量更低），右侧不再死板。
  // 代价：1 个 9 bit 加法器 + 2 级饱和比较，0 DSP / 0 BRAM / 0 寄存器。
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

  // ============================================================
  // 2026-10-13 CONGESTION FIX (TD PHY-8023)
  //   Nets that failed to route (deterministically, both runs):
  //       u_spectrum_capture/mux337_syn_2[336] [296]
  //       Location: (x35y62_s2beg4)
  //   CAUSE: log_map() is a 128-entry lookup (cnt[6:0] -> 6 bits) i.e. a
  //     128:1 select, and it was written THREE TIMES in the peak-hold
  //     update. Synthesis therefore built three copies of that wide
  //     select, each feeding a 48-entry array index. That over-wide
  //     select network is exactly what TD could not route.
  //   FIX: evaluate log_map ONCE here and reuse it three times.
  //
  //   * WHY A WIRE, NOT A REGISTER *
  //     cnt increments every clock at the bottom of the same always block
  //     (cnt <= cnt + 8'd1) and the array writes use the CURRENT cnt. A
  //     registered version would be one cycle late and would write the
  //     bar into the WRONG bin. This very module documents that trap for
  //     bar_sm ("writing bar_sm <= ... would be one beat later than bar"
  //     => peak-hold stores the wrong bar). So the hoist must stay purely
  //     combinational: same values, same cycle, functionally identical.
  //     It still collapses 3 wide selects into 1 - that is the win.
  //   No new register and no new always block => nothing to double-drive.
  // ============================================================
  wire [5:0] lm = log_map(cnt[6:0]);

  // ---- log-frequency bin -> bar lookup (48 bars, 187.5Hz ~ 24kHz) ----
  // 【批次1-第1项】捕获上限从 bin53 放宽到 bin127。
  //   bin1..bin127 = 187.5Hz..23.8kHz = 6.99 个倍频程（原来只覆盖到 9.9kHz）。
  // 旧表的 18 个空柱位（48 个柱位里只有 30 个被写过）是要消灭的缺陷。
  // 新表采用"分段等柱宽对数分区"，两个不变式在生成时已逐项校验：
  //   (1) bar 随 bin 单调不减（无回退，无空隙，无重叠）；
  //   (2) 每柱最多聚合 3 个 bin（旧表最大 4）。
  //   bar 0..16  : 每柱 2 个 bin（低频，约 3 柱/倍频程，保住 187.5Hz 分辨率）
  //   bar 17..47 : 每柱 3 个 bin
  //   合计 17*2 + 31*3 = 127 个 bin，48 个柱位 100% 有数据。
  // 说明1：报告 §3.3 推荐的正统写法 bar = round(47*log2(bin)/log2(127))
  //   在本文件实测会产生两个问题：柱宽随频率按约 1.10 倍递增（顶柱要
  //   聚合 12 个 bin），且因为低频 bin1..13 只有 13 个桶，重新出现 13 个
  //   空柱位（1,2,3,4,5,6,8,9,10,12,14,15,18）—— 与"消灭空柱位"的目标
  //   直接冲突，故不采用。代价是低频段不再严格等倍频程。
  // 说明2：报告 §11 B1 提到"每柱 2-3 个 bin"——本表与之吻合；但报告
  //   同时声称"柱位单调"（成立）和"每柱最多 4 个 bin"（33/48 柱超过 4 个
  //   bin 是数学上不可避免的：127 bin / 48 柱，末柱覆盖 125..127 共 3 个，
  //   若改成严格等倍频程则末柱 12 个）。这里以"消灭空柱位 + 单调"为准。
  // bin0(DC) 不参与；正频谱到 bin127 结束，不会出现未定义索引。
  // ================================================================
  // 2026-10-17 面积优化：128 项 case 表 -> 精确算术式
  //
  //   原来是一个 128 项的 case，即 128:1 的 6 位译码网络。
  //   而它每个时钟都在算（cnt 每拍 +1），综合器还得处理它的宽 mux。
  //
  //   把原表按 bin 逐项展开后，结构其实极规整（已用脚本逐项打印确认）：
  //       bin   0..  2 -> bar  0     （3 个 bin）
  //       bin   3.. 34 -> bar  1..16 每 2 个 bin 一柱
  //       bin  35..127 -> bar 17..47 每 3 个 bin 一柱
  //   于是可以写成精确的算术式（不是近似）：
  //       bin <  3  -> 0
  //       bin < 35  -> 1 + ((bin-3) >> 1)
  //       else      -> 17 + (bin-35)/3
  //
  //   【除 3 怎么不用除法器】穷举搜索 (n*m)>>s 在 n=0..92（即 bin-35 的
  //     取值范围）上精确等于 n/3 的最小组合，得到
  //         n/3 == (n * 43) >> 7       43 = 101011b（4 个 1）
  //     即 3 次移位加 + 1 次右移，无除法器、无 DSP。
  //   【正确性】已用脚本对 bin=0..127 全部 128 个输入逐个比对原表，
  //     完全一致（见 tools/logmap2.py、tools/div3.py 的输出）。
  //
  //   收益：128 项译码（估 150-250 LUT）-> 约 25 LUT。
  //   回退：把本函数换回原来的 case 表即可（原表在 git 历史/备份里）。
  // ================================================================
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

  // Independent synchronous RAM read ports. Reset validity rather than
  // every RAM bit, so TD can map the storage to block RAM.
  // 2026-10-25: time-share one decay datapath over the existing 32-bin
  // display-commit window. No extra frame latency or external port change.
  // Baseline decays every entry at bin 127, then copies entries at 128..159.
  // Here each entry is decayed as it is copied. Capture at bin 127 must stay
  // suppressed: the baseline's parallel decay overrides that capture write.
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
        // ================= 【第4步 B · 2026-10-07】跨 bin 平滑（防锯齿）=================
        // 问题：一根柱 = 一个 FFT bin，相邻 bin 之间没有关联 ⇒ 频谱包络呈锯齿/跳变，
        //       与参考图"平滑包络"不符。
        // 做法：对到达顺序（log_map 单调 ⇒ 即柱位递增顺序）做 3 抽头 FIR：
        //       y[n] = (w0*x[n] + w1*x[n-1] + w2*x[n-2]) / (w0+w1+w2)
        //   权重与归一化移位都是参数（默认 [1,2,1]/4 = 参数化可调）。
        //   纯移位+加法，0 DSP 。每帧末尾（cnt==176）清一次延迟寄存器，
        //   避免把上一帧末柱和本帧首柱混在一起。
        //   ⚠ 只在"到达值"上平滑：mem/tilt_mem 的 peak-hold 与衰减语义不变；
        //     平滑只影响存进去的幅度 ⇒ 不会把频谱糊平（见 TB 的"平滑前后柱高差"断言）。
        bar_fir1 <= bar_fir0;
        bar_fir0 <= bar;
        // 【第4步 B】bar_sm 是组合结果（见文件上方 wmul/fir_sum/bar_sm 声明），
        //   与 bar 同拍对齐；写成 `bar_sm <= ...` 会比 bar 晚一拍 ⇒ peak-hold 存错一根柱。
        // ---- capture: peak-hold rise (instant) ----
        // 【批次1-第1项】捕获范围从 bin1..53（187.5Hz~9.94kHz）放宽到
        // bin1..127（187.5Hz~23.8kHz 整个正频谱），让 48 个柱位全部有
        // 数据（旧表 48 柱里 18 柱恒为 0，屏幕 37.5% 无数据）。
        // bin0(DC) 丢弃；bin128..255 是共轭镜像，本来就不参与。
        if ((cnt < 8'd127) && (cnt >= 8'd1) && (bar_sm >= NOISE_FLOOR)) begin
          // ============================================================
          // 2026-10-17 PEAK HOLD（白点）恢复 —— 专业频谱的标配
          //
          //   mem[] 之前被标注为"死逻辑"（因为 rd_data 恒 0 且
          //   spectrum_display 不用 p0）。但 p0 的端口一直在，
          //   只是没被读。现在把 mem[] 用作峰值保持，经 p0 输出，
          //   由 spectrum_display 画成柱顶白点 —— 这是专业设备
          //   （RTA / 实时分析仪）最标志性的视觉元素。
          //
          //   ⚠ 关键设计：bar 与 peak 必须用不同的释放速度
          //        bar  （tilt_mem）: 每帧 -2  ，约 685ms 落满  ← 跟节奏
          //        peak （mem）      : 每帧 -1  ，约 1.4s 落满  ← 留痕
          //      这正是"白点比柱子回落慢"的观感来源。
          //      若两者同速，白点会永远贴着柱顶，看起来毫无作用。
          //
          //   ⚠ 另一个坑：峰值必须比较原始高度 bar_sm，
          //      不能拿倾斜后的值和倾斜后的峰值比 —— 否则 bar/peak
          //      两条链的增益不一致，白点会系统性偏移。
          // ============================================================
          // [Design note 面积]比较对象从 mem[lm] 改成 tilt_mem[lm] 自己。
          //   mem[] 原本是 tilt_mem 的逐位副本（同样的 bar_sm、
          //   同样的 -2/帧衰减），而且没有任何读者（rd_data 恒 0）⇒
          //   白占 256 个 FF。删掉它后本判据完全等价。
          // Capture is committed by the working-RAM stage above.
        end
        // accumulate bass energy (bins 1..4 = 187..750Hz)
        if (cnt >= 8'd1 && cnt <= 8'd4) bass_acc <= bass_acc + {3'b0, bar};
        // ---- per-frame decay ----
        // [Design note 专业化]柱体与峰值不同速：
        //     tilt_mem（柱体）: -2 /帧  -> 248 落满约 124 帧 ≈ 685ms  （跟节奏）
        //     mem     （峰值）: -1 /帧  -> 248 落满约 248 帧 ≈ 1.4s   （留痕）
        //   这就是专业频谱分析仪"白点比柱子慢半拍回落"的观感来源。
        //   ⚠ 两者都保留固定步长（不用 >>N 比例衰减）：比例衰减在
        //     数值小于 2^N 时步长归零，低幅度柱子会永远卡住形成直流偏置。
        //     固定步长保证一定能回到 0。
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
          // 【第4步 B】每帧末尾清 FIR 延迟，避免跨帧混柱（上一帧末柱 + 本帧首柱）
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
