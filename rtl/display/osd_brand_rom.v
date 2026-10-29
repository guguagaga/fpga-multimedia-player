//===================================================================
// osd_brand_rom : 品牌条用到的两片字模/位图 ROM
//===================================================================
// [Design note brand]OSD 顶部品牌条（安路 logo + "anlogic 多媒体播放系统"）的数据源。
//
//   cjk  : 9 个汉字 16x16 点阵，每字 16 行、每行 16 位（bit15 = 最左列）
//          顺序 = 安 路 多 媒 体 播 放 系 统
//          addr = 字号*16 + 行号   （0..143）
//          144 x 16 bit = 288 B
//   logo : 安路标识位图 94x18，一个字节一个像素
//          0 = 透明（露出底板）  1 = 红（A 的斜条纹）  2 = 白（LOGIC 字样）
//          addr = (y-43)*94 + (x-18)
//          1692 B
//
// 两个读口都是「无条件同步读」（always @(posedge clk) dout <= mem[addr]，
// 外面不套 if）——这是数组被推断成 ERAM 的硬条件（见学习指南第 04 章）。
// 数据由 gen_brand_assets.py 从 simhei.ttf 与安路 logo 图片生成，
// .mem 文件与本文件同目录（与 font_8x16.mem 的用法一致）。
//===================================================================
`timescale 1ns / 1ps

module osd_brand_rom (
  input  wire        clk,
  input  wire [ 7:0] cjk_addr,   // 字号*16 + 行号，0..143
  output reg  [15:0] cjk_dout,
  input  wire [10:0] logo_addr,  // 0..1691
  output reg  [ 7:0] logo_dout
);

  reg [15:0] cjk [ 0:143];
  reg [ 7:0] logo[0:1691];

  initial begin
    $readmemh("cjk_brand_16x16.mem", cjk);
    $readmemh("anlogic_logo.mem", logo);
  end

  always @(posedge clk) cjk_dout <= cjk[cjk_addr];

  // 地址上限保护：logo_rel 在区域外会算出越界值（x/y 比 LOGO_X/Y 小的时候
  // 是 10 位无符号相减的回绕），这里夹到 0，避免读到数组外（仿真报错/TD 变黑盒）
  wire [10:0] logo_a = (logo_addr <= 11'd1691) ? logo_addr : 11'd0;
  always @(posedge clk) logo_dout <= logo[logo_a];

endmodule
