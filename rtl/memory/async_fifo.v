// 双时钟字节 FIFO，读写指针通过 Gray 码同步到对侧时钟域。
// 数据存储采用同步读以映射块 RAM；读请求与数据有效相隔一拍。
// 消费者以 REQ/GET 两阶段读取，避免将新指针误配到尚未更新的数据。
module async_fifo #(
  parameter DATA_WIDTH         = 8,
  parameter ADDR_WIDTH         = 11,    // DEPTH = 2^ADDR_WIDTH = 2048
  parameter DEPTH              = 2048,
  parameter ALMOST_FULL_THRESH = 1024   // reserve room for 2 sectors
) (
  input  wire                  wr_clk,
  input  wire                  wr_rst,
  input  wire                  wr_en,
  input  wire [DATA_WIDTH-1:0] wr_data,
  output wire                  full,
  output wire                  almost_full,
  output wire [  ADDR_WIDTH:0] wr_usedw,
  input  wire                  rd_clk,
  input  wire                  rd_rst,
  input  wire                  rd_en,
  output wire [DATA_WIDTH-1:0] rd_data,
  output wire                  empty
);

  reg [DATA_WIDTH-1:0] mem[0:DEPTH-1];

  reg [ADDR_WIDTH:0] wr_ptr;
  reg [ADDR_WIDTH:0] rd_ptr;

  // Register Gray pointers in their source domains. A combinational XOR
  // of a binary counter can glitch when several binary bits change;
  // two destination synchronizer stages cannot repair that source glitch.
  reg [ADDR_WIDTH:0] wr_ptr_g;
  reg [ADDR_WIDTH:0] rd_ptr_g;
  wire [ADDR_WIDTH:0] wr_ptr_next = wr_ptr + 1'b1;
  wire [ADDR_WIDTH:0] rd_ptr_next = rd_ptr + 1'b1;

  // ---- 2-stage synchronizers (Gray code) ----
  reg [ADDR_WIDTH:0] rd_ptr_g_s1, rd_ptr_g_s2;  // rd -> wr domain
  reg [ADDR_WIDTH:0] wr_ptr_g_s1, wr_ptr_g_s2;  // wr -> rd domain

  // Gray -> binary (for usedw calculation on the write side)
  function [ADDR_WIDTH:0] gray2bin;
    input [ADDR_WIDTH:0] g;
    integer i;
    begin
      gray2bin = g;
      for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1) gray2bin[i] = gray2bin[i+1] ^ g[i];
    end
  endfunction

  always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
      rd_ptr_g_s1 <= 0;
      rd_ptr_g_s2 <= 0;
    end else begin
      rd_ptr_g_s1 <= rd_ptr_g;
      rd_ptr_g_s2 <= rd_ptr_g_s1;
    end
  end

  always @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
      wr_ptr_g_s1 <= 0;
      wr_ptr_g_s2 <= 0;
    end else begin
      wr_ptr_g_s1 <= wr_ptr_g;
      wr_ptr_g_s2 <= wr_ptr_g_s1;
    end
  end

  // ---- write side ----
  always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
      wr_ptr   <= 0;
      wr_ptr_g <= 0;
    end else if (wr_en && !full) begin
      mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
      wr_ptr <= wr_ptr_next;
      wr_ptr_g <= wr_ptr_next ^ (wr_ptr_next >> 1);
    end
  end

  // ---- read side：寄存器读（同步读 -> TD 可推断 BRAM）----
  // rd_data 是组合输出的寄存器；rd_ptr 只在真正消费时前进。
  // 两个 always 分开写，是为了让"读数据寄存器"不带异步复位 ——
  // 这是 BRAM 输出寄存器最容易被工具识别的形态。
  reg [DATA_WIDTH-1:0] rd_data_q;

  always @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
      rd_ptr   <= 0;
      rd_ptr_g <= 0;
    end else if (rd_en && !empty) begin
      rd_ptr   <= rd_ptr_next;
      rd_ptr_g <= rd_ptr_next ^ (rd_ptr_next >> 1);
    end
  end

  // 拉高 rd_en 的那一拍读地址 = rd_ptr，下一拍 rd_data_q 即为该字节。
  always @(posedge rd_clk) begin
    if (rd_en && !empty) begin
      rd_data_q <= mem[rd_ptr[ADDR_WIDTH-1:0]];
    end
  end

  assign rd_data = rd_data_q;

  // ---- empty / full (Gray-code comparison) ----
  assign empty = (rd_ptr_g == wr_ptr_g_s2);

  assign full = (wr_ptr_g[ADDR_WIDTH] != rd_ptr_g_s2[ADDR_WIDTH]) &&
      (wr_ptr_g[ADDR_WIDTH-1] != rd_ptr_g_s2[ADDR_WIDTH-1]) &&
      (wr_ptr_g[ADDR_WIDTH-2:0] == rd_ptr_g_s2[ADDR_WIDTH-2:0]);

  // ---- used words on the write side (synchronized read ptr) ----
  wire [ADDR_WIDTH:0] rd_ptr_bin_sync = gray2bin(rd_ptr_g_s2);
  wire [ADDR_WIDTH:0] usedw_raw = wr_ptr - rd_ptr_bin_sync;
  assign wr_usedw = usedw_raw;

  assign almost_full = (usedw_raw >= ALMOST_FULL_THRESH);

endmodule
