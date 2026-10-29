//===================================================================
// pixel_fifo_24x8 : 8-deep 24-bit pixel FIFO, first-word-fall-through.
//
// WHY THIS EXISTS
//   The scaler downscales, so one output pixel can swallow several source
//   pixels and some source pixels are discarded.  When the scaler is not
//   ready it must be able to HOLD the source pixel (ready=0 is the WAIT slot
//   of the locked algorithm).
//
//   In bmp_read the pixel pulse is derived from the raw SD byte stream:
//       bmp_data_valid = sd_sec_read_data_valid && bmp_len_cnt >= pixel_offset
//       bmp_data_wr_en = bmp_data_valid && (bmp_byte_idx == 2)
//   bmp_data_valid gates BYTES, not pixels.  Freezing it to stall the scaler
//   would drop SD byte pulses and shift every colour channel, so the byte
//   stream must never be stalled.  This FIFO decouples the two: the byte
//   side always writes, the scaler side reads only when it is ready.
//
// FIRST-WORD-FALL-THROUGH
//   dout always presents the oldest word whenever empty is low, and that word
//   stays put until rd_en retires it.  That is what the scaler's held
//   valid/ready protocol needs: it samples src_pixel on the cycle ready is
//   high, so the data has to be standing before the transfer, not one cycle
//   after it.
//
//   rd_en is expected to be driven by the scaler's `ready`, and `empty`
//   (inverted) by its `src_valid`, so the scaler sees a source that holds its
//   pixel across a stall.
//
// DEPTH
//   8 entries (192 bits).  The SD read side delivers pixels in bursts and the
//   scaler consumes 1..3 source pixels per output pixel, so 8 entries absorb
//   the burst jitter.  The producer never stalls; only the reader does, and a
//   full FIFO simply drops the write - which cannot happen on a correctly
//   sized stream, because the reader is the slower side.
//===================================================================
`timescale 1ns / 1ps

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
