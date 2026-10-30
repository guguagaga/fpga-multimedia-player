// -----------------------------------------------------------------------------
// Module purpose: Video input byte storage.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
// One synchronous read cycle. Byte lanes preserve the untouched neighbor.
// EG4 offers separate 9K/32K resources: large byte FIFOs must use 32K RAM.
module video_byte_ram #(
  parameter AW = 13,
  parameter integer DEPTH_BYTES = (1 << AW),
  parameter integer HYBRID_TAIL_9K = 0
) (
  input wire clk, we, re,
  input wire [AW-1:0] wa, ra,
  input wire [7:0] data,
  output wire [7:0] q
);
  generate
    if (AW < 12) begin : g_small
      reg [7:0] mem [0:(1<<AW)-1];
      reg [7:0] out;
      always @(posedge clk) begin
        if (we) mem[wa] <= data;
        if (re) out <= mem[ra];
      end
      assign q = out;
    end else begin : g_large
      localparam BANKS = (DEPTH_BYTES + 4095) / 4096;
      localparam BW = (AW > 12) ? AW - 12 : 1;
      wire [15:0] bank_q[0:BANKS-1];
      reg [BW-1:0] read_bank;
      reg read_half;
      genvar b;
      for (b = 0; b < BANKS; b = b + 1) begin : banks
        if (HYBRID_TAIL_9K && b >= 7) begin : g_tail9k
          // Preserve the16KiB decoder FIFO by allocating only the 64-sector cache tail
          // to four available9K RAMs. Two byte lanes preserve neighbor writes.
          (* ram_style="bram" *) reg [7:0] low_mem[0:2047];
          (* ram_style="bram" *) reg [7:0] high_mem[0:2047];
          reg [7:0] low_q,high_q,forward_data;
          reg forward_low,forward_high;
          wire bank_we=we && ((wa >> 12)==b);
          wire same_word=wa[11:1]==ra[11:1];
          always @(posedge clk) begin
            if (bank_we && !wa[0]) low_mem[wa[11:1]] <= data;
            if (bank_we && wa[0]) high_mem[wa[11:1]] <= data;
            if (re) begin
              low_q <= low_mem[ra[11:1]];
              forward_low <= bank_we && same_word && !wa[0];
              high_q <= high_mem[ra[11:1]];
              forward_high <= bank_we && same_word && wa[0];
              forward_data <= data;
            end
          end
          assign bank_q[b]={forward_high ? forward_data : high_q, forward_low ? forward_data : low_q};
        end else begin : g_vendor32
        EG_PHY_BRAM32K #(
          .MODE("DP16K"),
          .DATA_WIDTH_A("16"),
          .DATA_WIDTH_B("16"),
          .REGMODE_A("NOREG"),
          .REGMODE_B("NOREG"),
          .WRITEMODE_A("NORMAL"),
          .WRITEMODE_B("NORMAL")
        ) ram (
          .doa    (),
          .dia    ({data, data}),
          .addra  (wa[11:1]),
          .bytea  (wa[0]),
          .bytewea(1'b1),
          .csa    (1'b1),
          .wea    (we && ((wa >> 12) == b)),
          .clka   (clk),
          .rsta   (1'b0),
          .ocea   (1'b1),
          .dob    (bank_q[b]),
          .dib    (16'd0),
          .addrb  (ra[11:1]),
          .byteb  (1'b0),
          .byteweb(1'b0),
          .csb    (re),
          .web    (1'b0),
          .clkb   (clk),
          .rstb   (1'b0),
          .oceb   (1'b1)
        );
        end
      end
      always @(posedge clk)
        if (re) begin
          read_bank <= ra >> 12;
          read_half <= ra[0];
        end
      assign q = read_half ? bank_q[read_bank][15:8] : bank_q[read_bank][7:0];
    end
  endgenerate
endmodule
