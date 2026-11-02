// 围绕通道中点 128 调节对比度，再叠加亮度并饱和到 0～255。
// 对比度档位 96/128/160/192 采用移位加减，算术右移保留定点取整语义。
// RGB、DE 和 VS 同步延迟一拍，保持像素与时序对齐。
module brightness_contrast (
  input  wire               clk,
  input  wire               rst_n,
  input  wire               de,
  input  wire               vs,
  input  wire        [23:0] din_rgb,
  input  wire signed [ 8:0] brightness,  // 亮度偏移（本项目档值 -48/-16/+16/+48）
  input  wire        [ 8:0] contrast,    // 对比度 Q7（本项目档值 96/128/160/192）
  output reg                de_out,
  output reg                vs_out,
  output reg         [23:0] dout_rgb
);

  // ---- 单通道调整（组合；免乘法移位版） ----
  function [7:0] adjust;
    input [7:0] px;
    input signed [8:0] bright;
    input [8:0] ct;
    reg signed [ 9:0] d;  // px - 128  ∈ [-128, 127]
    reg signed [11:0] g;  // 对比度后（仍围绕 0）∈ [-192, 191]
    reg signed [12:0] res;  // g + 128 + bright
    begin
      d = $signed({2'b0, px}) - 10'sd128;
      case (ct)
        9'd96:   g = d - (d >>> 2);  // ×0.75
        9'd160:  g = d + (d >>> 2);  // ×1.25
        9'd192:  g = d + (d >>> 1);  // ×1.5
        default: g = d;  // ×1.0（含 128）
      endcase
      res = {g[11], g} + 13'sd128 + {{4{bright[8]}}, bright};
      if (res > 13'sd255) adjust = 8'd255;  // 饱和钳位
      else if (res < 13'sd0) adjust = 8'd0;
      else adjust = res[7:0];
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
        dout_rgb[15:8]  <= adjust(din_rgb[15:8], brightness, contrast);
        dout_rgb[7:0]   <= adjust(din_rgb[7:0], brightness, contrast);
      end else dout_rgb <= 24'd0;
    end
  end

endmodule
