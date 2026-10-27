//===================================================================
// brightness_contrast : 亮度/对比度实时调节（像素运算核心）
//===================================================================
// 逐通道对 24bit RGB 做线性变换：
//     out = (in - 128) * contrast / 128 + 128 + brightness
// 其中 brightness 为有符号偏移，contrast 为 Q7 定点（128 = 1.0），
// 结果钳位到 0~255。1 拍流水线：de / vs / rgb 三者同步打拍输出，
// 保证下游（video_rgb_to_axis）三线对齐。
//
//=== [CHG 2026-10-13 bc-shift] =============================================
// 改动：改写为【免乘法】实现。原版在 function 内做 16×9 的
//   `prod = diff * ct`（通用乘法 ⇒ 会占 DSP 或大 LUT）。
// 原因：项目铁律「正常版 DSP 新增必须 = 0」（EG4S20 的 DSP 余量紧张）。
//   ⇒ 对比度不再做通用乘法：本工程只用 4 档 {96,128,160,192} =
//     ×{0.75, 1.0, 1.25, 1.5}，全部用移位加减【精确】实现：
//       96/128  ->  d - (d>>>2)
//       160/128 ->  d + (d>>>2)
//       192/128 ->  d + (d>>>1)
//       其余值（含 128）-> d（×1.0，安全兜底）
// 影响：只影响亮度/对比度像素通道本身；不动任何其它视频/音频路径。
//   新增 vs 透传（1 拍延迟），供下游 vs/de/rgb 对齐。
// 来源：移植自 fpga_build/rtl/brightness_contrast.v（搭档遗留未接入
//   模块），此处为移位改写版；原版保留在 fpga_build 树作对照。
//==========================================================================
module brightness_contrast (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              de,
    input  wire              vs,
    input  wire [23:0]       din_rgb,
    input  wire signed [8:0] brightness,   // 亮度偏移（本项目档值 -48/-16/+16/+48）
    input  wire [8:0]        contrast,     // 对比度 Q7（本项目档值 96/128/160/192）
    output reg               de_out,
    output reg               vs_out,
    output reg  [23:0]       dout_rgb
);

    // ---- 单通道调整（组合；免乘法移位版） ----
    function [7:0] adjust;
        input [7:0]         px;
        input signed [8:0]  bright;
        input [8:0]         ct;
        reg signed [9:0]    d;     // px - 128  ∈ [-128, 127]
        reg signed [11:0]   g;     // 对比度后（仍围绕 0）∈ [-192, 191]
        reg signed [12:0]   res;   // g + 128 + bright
        begin
            d = $signed({2'b0, px}) - 10'sd128;
            case (ct)
                9'd96:   g = d - (d >>> 2);   // ×0.75
                9'd160:  g = d + (d >>> 2);   // ×1.25
                9'd192:  g = d + (d >>> 1);   // ×1.5
                default: g = d;               // ×1.0（含 128）
            endcase
            res = {g[11], g} + 13'sd128 + {{4{bright[8]}}, bright};
            if (res > 13'sd255)     adjust = 8'd255;   // 饱和钳位
            else if (res < 13'sd0)  adjust = 8'd0;
            else                    adjust = res[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out   <= 1'b0;
            vs_out   <= 1'b0;
            dout_rgb <= 24'd0;
        end else begin
            de_out <= de;
            vs_out <= vs;
            if (de) begin
                dout_rgb[23:16] <= adjust(din_rgb[23:16], brightness, contrast);
                dout_rgb[15:8]  <= adjust(din_rgb[15:8],  brightness, contrast);
                dout_rgb[7:0]   <= adjust(din_rgb[7:0],   brightness, contrast);
            end else
                dout_rgb <= 24'd0;
        end
    end

endmodule
