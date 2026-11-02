// 顶部品牌条的字模与位图 ROM。
// 中文采用 16×16 点阵，图像和字符地址分别查表，输出与像素流水对齐。
`timescale 1ns / 1ps

module osd_brand_rom (
  input  wire        clk,
  input  wire [ 7:0] cjk_addr,   // 字号*16 + 行号，0..143
  output reg  [15:0] cjk_dout,
  input  wire [10:0] logo_addr,  // 0..1691
  output reg  [ 7:0] logo_dout
);

  reg [15:0] cjk [ 0:143];
  reg [ 7:0] logo[0:2047];

  initial begin
    $readmemh("cjk_brand_16x16.mem", cjk);
    $readmemh("anlogic_logo.mem", logo);
  end

  always @(posedge clk) cjk_dout <= cjk[cjk_addr];

  // 地址 1692～2047 重复地址 0 的内容，使整个 11 位地址空间都有定义。
  // 在 ROM 内容中实现范围补齐，避免地址路径额外串接边界选择。
  wire [10:0] logo_a = logo_addr;
  always @(posedge clk) logo_dout <= logo[logo_a];

endmodule
