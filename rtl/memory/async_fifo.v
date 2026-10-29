// -----------------------------------------------------------------------------
// Module purpose: Dual-clock byte FIFO and occupancy signaling.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
//===================================================================
// async_fifo : Gray-code async FIFO with almost_full (cross clock domain)
//===================================================================
// Moves a byte stream from one clock domain to another.
//   wr_clk : producer clock (SD card reader, 100 MHz)
//   rd_clk : consumer clock (audio, 12.288 MHz)
//
// Standard dual-clock RAM + Gray-coded read/write pointers with 2-stage
// synchronizers.
//
// 【读口 = 寄存器读（BRAM 形态），这是省 LUT 的关键】
//   原实现是组合读：assign rd_data = mem[rd_ptr]。
//   2048 深的组合读 TD 推断不出 BRAM，只能拼成 2048:1 的多路选择器 ——
//   实测 u_async_fifo 占 1742 LUT、u_wav_sample_builder 占 758 LUT
//   （时序报告里那些 mux/ramread 单元横跨两个模块），合计约 2500 LUT，
//   是 mslice 超限（5044 / 上限 4900）的最大单一来源。
//   改成寄存器读后 mem（2048 x 8 = 16384 bit）落进 BRAM
//   （2 个 9K bram），这部分 LUT 基本清零。
//
//   【新的读握手语义：rd_en 拉高后的下一拍才有数】
//       cycle N   : rd_en=1 且 !empty  ->  BRAM 读出 mem[rd_ptr]，rd_ptr++
//       cycle N+1 : rd_data = mem[旧 rd_ptr]   <- 消费者在这一拍取数
//   配套改动：wav_sample_builder 把每个字节拆成 REQ/GET 两拍
//   （REQ 拍拉 rd_en，GET 拍取数）；i2s_transmitter 改成"提前一拍请求、
//   下一拍锁存"，让"请求 -> 锁存"成为显式的前后拍关系。
//
// 【历史留档：一个曾经被误判的"根本矛盾"】
//   早前"只改 builder"试过 3 种写法，全部失败，当时归因为
//   "寄存器读晚一拍 vs i2s_transmitter 请求当拍锁存"的冲突。
//   复盘结论：那个归因是错的。i2s_transmitter 在帧边界那一拍锁存，而
//   下一帧边界在 256 拍之后 —— builder 有 256 拍余量，"必须当拍给出"
//   从来不是约束。那 3 次失败都是 builder 状态机的字节相位/指针错位
//   （实测分别读到第 1/2/3 个字节），不是时序问题。
//
// ALMOST_FULL_THRESH reserves space for one SD sector (512 bytes) so the
// producer (wav_reader) can be back-pressured *between* sectors without
// overflowing mid-sector.
//===================================================================
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
