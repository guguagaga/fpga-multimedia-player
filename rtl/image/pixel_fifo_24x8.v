`timescale 1ns / 1ps
// Eight-entry RGB888 FIFO with first-word-fall-through output.
// dout holds the oldest pixel until an accepted read, allowing scaler backpressure.
// Writes are accepted when !full; reads are accepted when !empty.
// The producer must honor full or provide enough buffering to avoid pixel loss.
module pixel_fifo_24x8 (
  input wire clk,
  input wire rst,

  input wire        wr_en,
  input wire [23:0] din,

  input  wire        rd_en,
  output wire [23:0] dout,

  output wire       empty,
  output wire       full,
  output wire [3:0] count
);

  reg [23:0] mem                                                         [0:7];
  reg [ 3:0] wr_ptr;  // 0..7 plus one wrap bit is not needed at depth 8:
  reg [ 3:0] rd_ptr;  //   the pointers are 4-bit so equality is exact
  reg [ 3:0] cnt;

  assign empty = (cnt == 4'd0);
  assign full  = (cnt == 4'd8);
  assign count = cnt;
  assign dout  = mem[rd_ptr[2:0]];

  wire do_wr = wr_en & ~full;
  wire do_rd = rd_en & ~empty;

  always @(posedge clk) begin
    if (rst) begin
      wr_ptr <= 4'd0;
      rd_ptr <= 4'd0;
      cnt    <= 4'd0;
    end else begin
      if (do_wr) begin
        mem[wr_ptr[2:0]] <= din;
        wr_ptr <= wr_ptr + 4'd1;
      end
      if (do_rd) rd_ptr <= rd_ptr + 4'd1;

      case ({
        do_wr, do_rd
      })
        2'b10:   cnt <= (cnt == 4'd8) ? cnt : (cnt + 4'd1);
        2'b01:   cnt <= cnt - 4'd1;
        default: cnt <= cnt;
      endcase
    end
  end

endmodule
