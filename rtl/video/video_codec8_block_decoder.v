`timescale 1ns / 1ps
// Codec8 block decoder.  It consumes one byte when byte_ready is high and
// emits at most one RGB565 pixel per clock in BLOCK order, not raster order.
// A raster writer needs a separate reorder stage for frames wider than 8.
// SOLID/PAL2/QUAD4/RAW; optional Codec10 0x85,count-1,color SOLID run.
// pause stalls parsing and emission;
// enable=0 aborts/resets the session, so keep it high across normal stalls.
module video_codec8_block_decoder #(
  parameter integer FRAME_PIXELS = 480000,
  parameter integer ALLOW_SOLID_RUN = 0
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        enable,
  input  wire        pause,
  input  wire        byte_valid,
  input  wire [ 7:0] byte_data,
  output wire        byte_ready,
  output reg         pix_valid,
  output reg  [15:0] pix_rgb565,
  output reg         frame_done,
  output reg         fault
);
  localparam [3:0] S_OP = 0, S_SOL_LO = 1, S_SOL_HI = 2, S_PAL_LO = 3, S_PAL_HI = 4, S_RAW_LO = 5,
      S_RAW_HI = 6, S_SOL_OUT = 7, S_PAL_OUT = 8, S_RAW_OUT = 9, S_RUN_COUNT = 10, S_SOL_GAP = 11;
  reg [3:0] state;
  localparam integer EMIT_W = (FRAME_PIXELS < 2) ? 1 : $clog2(FRAME_PIXELS + 1);
  reg [15:0] pal0, pal1, raw_pix;
  reg quad_mode;
  reg [63:0] idx_shift;
  reg [3:0] payload_idx;
  reg [6:0] pix_idx;
  reg [EMIT_W-1:0] emitted;
  reg [7:0] lo;
  reg [7:0] repeat_blocks;  // additional 8x8 SOLID blocks, Codec10 only

  assign byte_ready = enable && !pause &&
      ((state == S_OP) || (state == S_SOL_LO) || (state == S_SOL_HI) || (state == S_PAL_LO) ||
       (state == S_PAL_HI) || (state == S_RAW_LO) || (state == S_RAW_HI) || (state == S_RUN_COUNT));

  // Protocol indices are consumed LSB first. A fixed tap avoids the
  // two-dimensional variable-index mux from the original idx_mem.
  // Register index operations locally. This cuts the long playback/FIFO
  // control path before the 64-bit shift register's clock enable.
  reg idx_load_pending, idx_step_pending;
  reg [15:0] idx_load_data;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      idx_load_pending <= 0;
      idx_step_pending <= 0;
    end else begin
      idx_load_pending <= enable && !pause && byte_valid && state == S_PAL_HI && payload_idx >= 4;
      idx_step_pending <= enable && !pause && state == S_PAL_OUT && !quad_mode;
      if (enable && !pause && byte_valid && state == S_PAL_HI) idx_load_data <= {byte_data, lo};
    end
  end
  always @(posedge clk) begin
    if (idx_load_pending) idx_shift <= {idx_load_data, idx_shift[63:16]};
    else if (idx_step_pending) idx_shift <= {1'b0, idx_shift[63:1]};
  end
  // Forward the pending operation so observable pixel timing is unchanged.
  wire pal_bit = quad_mode ? pix_idx[2] :
      idx_load_pending ? idx_shift[16] : idx_step_pending ? idx_shift[1] : idx_shift[0];
  wire [15:0] pal_pix = pal_bit ? pal1 : pal0;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= S_OP;
      pal0 <= 0;
      pal1 <= 0;
      quad_mode <= 0;
      raw_pix <= 0;
      payload_idx <= 0;
      pix_idx <= 0;
      emitted <= 0;
      lo <= 0;
      repeat_blocks <= 0;
      pix_valid <= 0;
      pix_rgb565 <= 0;
      frame_done <= 0;
      fault <= 0;
    end else begin
      pix_valid  <= 0;
      frame_done <= 0;
      if (!enable) begin
        state <= S_OP;
        pix_idx <= 0;
        emitted <= 0;
        fault <= 0;
        repeat_blocks <= 0;
      end else if (!pause) begin
        case (state)
          S_OP: begin
            if (byte_valid && byte_ready) begin
              case (byte_data)
                8'h80: begin
                  repeat_blocks <= 0;
                  state <= S_SOL_LO;
                end
                8'h85: begin
                  if (ALLOW_SOLID_RUN) state <= S_RUN_COUNT;
                  else begin
                    fault <= 1'b1;
                    state <= S_OP;
                  end
                end
                8'h81: begin
                  quad_mode <= 0;
                  payload_idx <= 0;
                  state <= S_PAL_LO;
                end
                8'h84: begin
                  quad_mode <= 1;
                  payload_idx <= 0;
                  state <= S_PAL_LO;
                end
                8'h83: begin
                  pix_idx <= 0;
                  state   <= S_RAW_LO;
                end
                8'hFF: begin
                  frame_done <= 1'b1;
                  state <= S_OP;
                  pix_idx <= 0;
                  emitted <= 0;
                end
                default: begin
                  fault <= 1'b1;
                  state <= S_OP;
                end
              endcase
            end
          end
          S_RUN_COUNT:
          if (byte_valid && byte_ready) begin
            repeat_blocks <= byte_data;
            state <= S_SOL_LO;
          end
          S_SOL_LO:
          if (byte_valid && byte_ready) begin
            lo <= byte_data;
            state <= S_SOL_HI;
          end
          S_SOL_HI:
          if (byte_valid && byte_ready) begin
            pal0 <= {byte_data, lo};
            pix_idx <= 0;
            state <= S_SOL_OUT;
          end
          S_PAL_LO:
          if (byte_valid && byte_ready) begin
            lo <= byte_data;
            state <= S_PAL_HI;
          end
          S_PAL_HI:
          if (byte_valid && byte_ready) begin
            if (payload_idx == 0) pal0 <= {byte_data, lo};
            else if (payload_idx == 2) pal1 <= {byte_data, lo};
            else if (payload_idx >= 4) begin
              // Four accepted pairs completely overwrite this
              // register before output; no reset/data mux needed.
              // Index load is issued by the local pipeline above.
            end
            if (payload_idx == (quad_mode ? 6 : 10)) begin
              pix_idx <= 0;
              state   <= S_PAL_OUT;
            end else begin
              payload_idx <= payload_idx + 2;
              state <= S_PAL_LO;
            end
          end
          S_RAW_LO:
          if (byte_valid && byte_ready) begin
            lo <= byte_data;
            state <= S_RAW_HI;
          end
          S_RAW_HI:
          if (byte_valid && byte_ready) begin
            raw_pix <= {byte_data, lo};
            state   <= S_RAW_OUT;
          end
          S_SOL_OUT: begin
            if (emitted < FRAME_PIXELS) begin
              pix_valid <= 1'b1;
              pix_rgb565 <= pal0;
              emitted <= emitted + 1'b1;
            end
            if (pix_idx == 7'd63) begin
              pix_idx <= 0;
              if (repeat_blocks != 0) begin
                repeat_blocks <= repeat_blocks - 1'b1;
                state <= S_SOL_GAP;
              end else state <= S_OP;
            end else pix_idx <= pix_idx + 1'b1;
          end
          // The raster's registered busy arrives one cycle after the
          // final pixel. Preserve the block boundary bubble before a run
          // emits its next block; otherwise the next first pixel is lost.
          S_SOL_GAP: state <= S_SOL_OUT;
          S_PAL_OUT: begin
            // QUAD4 stores bottom colors in otherwise unused PAL2
            // index storage. Switch palette after the top four rows.
            if (quad_mode && pix_idx == 31) begin
              pal0 <= idx_shift[47:32];
              pal1 <= idx_shift[63:48];
            end
            // Index step is issued by the local pipeline above.
            if (emitted < FRAME_PIXELS) begin
              pix_valid <= 1'b1;
              pix_rgb565 <= pal_pix;
              emitted <= emitted + 1'b1;
            end
            if (pix_idx == 7'd63) begin
              pix_idx <= 0;
              state   <= S_OP;
            end else pix_idx <= pix_idx + 1'b1;
          end
          S_RAW_OUT: begin
            if (emitted < FRAME_PIXELS) begin
              pix_valid <= 1'b1;
              pix_rgb565 <= raw_pix;
              emitted <= emitted + 1'b1;
            end
            if (pix_idx == 7'd63) begin
              pix_idx <= 0;
              state   <= S_OP;
            end else begin
              pix_idx <= pix_idx + 1'b1;
              state   <= S_RAW_LO;
            end
          end
          default:   state <= S_OP;
        endcase
      end
    end
  end
endmodule
