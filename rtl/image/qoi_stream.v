// -----------------------------------------------------------------------------
// Module purpose: Streaming QOI image decoder.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
// Independently implemented from the public QOI specification, 2026-10-26.
// RGB/RGBA opcodes, modulo-256 deltas, 64-entry RGBA index, RUN and end marker.
// ready/valid at both ends; outputs RGB (alpha is tracked for correct hashing).
module qoi_stream #(
  parameter EXTERNAL_PIXELS = 1'b0,
  parameter BRAM32_INDEX = 0
) (
  input wire clk, rst, start,
  input wire [7:0] din,
  input wire din_valid,
  output wire din_ready,
  output wire [23:0] pixel,
  output wire pixel_valid,
  input wire pixel_ready,
  output reg done, error,
  output reg [31:0] width, height,
  input wire [24:0] expected_pixels
);
  localparam CLEAR = 0, HEADER = 1, OP = 2, RGB_R = 3, RGB_G = 4, RGB_B = 5, RGBA_A = 6, LUMA = 7,
      INDEX_WAIT = 8, EMIT = 9, ENDING = 10, STOP = 11;
  reg [3:0] state;
  reg [5:0] clear_addr, run_left;
  reg [3:0] head_pos, end_pos;
  reg [31:0] magic, prev, candidate;
  wire [31:0] index_q;
  reg rgba_op;
  reg [7:0] green_delta;
  reg [24:0] remaining, pixel_total;
  reg remaining_large, remaining_last;
  wire [24:0] initial_remaining = EXTERNAL_PIXELS ? expected_pixels : pixel_total;
  reg [7:0] channels;
  wire [7:0] r = prev[31:24], g = prev[23:16], b = prev[15:8], a = prev[7:0];
  wire [7:0] dr = din[5:4] - 8'd2, dg = din[3:2] - 8'd2, db = din[1:0] - 8'd2;
  wire [7:0] lr = r + green_delta + {4'd0, din[7:4]} - 8'd8;
  wire [7:0] lg = g + green_delta;
  wire [7:0] lb = b + green_delta + {4'd0, din[3:0]} - 8'd8;
  wire [7:0] rr = r + dr, gg = g + dg, bb = b + db;
  // Only low six hash bits are observable. Explicit six-bit shift/adds
  // avoid synthesizing four general constant multipliers.
  wire [5:0] cr = candidate[29:24], cg = candidate[21:16], cb = candidate[13:8],
      ca = candidate[5:0];
  wire [5:0] hr = {cr[4:0], 1'b0} + cr, hg = {cg[3:0], 2'b0} + cg;
  wire [5:0] hb = {cb[2:0], 3'b0} - cb, ha = {ca[2:0], 3'b0} + {ca[4:0], 1'b0} + ca;
  wire [5:0] hash_sum = hr + hg + hb + ha;
  assign din_ready = (state == HEADER || state == OP || state == RGB_R || state == RGB_G ||
                      state == RGB_B || state == RGBA_A || state == LUMA || state == ENDING);
  assign pixel_valid = (state == EMIT);
  assign pixel = candidate[31:8];
  // Both halves are accessed together. PortA holds low16 at addresses0..63,
  // portB high16 at64..127. During writes neither read result is consumed;
  // the following OP edge supplies the same synchronous INDEX lookup as
  // the inferred32-bit reference. CLEAR initializes every entry each start.
  generate
    if (BRAM32_INDEX) begin : g_bram32_index
      wire wr = (state == CLEAR) || (state == EMIT && pixel_ready);
      wire [5:0] wa = (state == CLEAR) ? clear_addr : hash_sum;
      wire [5:0] a = wr ? wa : din[5:0];
      wire [31:0] wd = (state == CLEAR) ? 32'd0 : candidate;
      EG_PHY_BRAM32K #(
        .MODE("DP16K"),
        .DATA_WIDTH_A("16"),
        .DATA_WIDTH_B("16"),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL")
      ) mem (
        .doa    (index_q[15:0]),
        .dia    (wd[15:0]),
        .addra  ({5'd0, a}),
        .bytea  (1'b0),
        .bytewea(1'b0),
        .csa    (1'b1),
        .wea    (wr),
        .clka   (clk),
        .rsta   (1'b0),
        .ocea   (1'b1),
        .dob    (index_q[31:16]),
        .dib    (wd[31:16]),
        .addrb  ({4'd0, 1'b1, a}),
        .byteb  (1'b0),
        .byteweb(1'b0),
        .csb    (1'b1),
        .web    (wr),
        .clkb   (clk),
        .rstb   (1'b0),
        .oceb   (1'b1)
      );
    end else begin : g_inferred_index
      reg [31:0] index_mem[0:63];
      reg [31:0] q;
      assign index_q = q;
      always @(posedge clk) begin
        q <= index_mem[din[5:0]];
        if (state == CLEAR) index_mem[clear_addr] <= 0;
        else if (state == EMIT && pixel_ready) index_mem[hash_sum] <= candidate;
      end
    end
  endgenerate
  always @(posedge clk) begin
    pixel_total <= width[15:0] * height[15:0];
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state <= STOP;
      done <= 0;
      error <= 0;
      width <= 0;
      height <= 0;
      clear_addr <= 0;
      head_pos <= 0;
      end_pos <= 0;
      magic <= 0;
      prev <= 32'h000000ff;
      candidate <= 0;
      remaining <= 0;
      remaining_large <= 0;
      remaining_last <= 0;
      run_left <= 0;
      rgba_op <= 0;
      green_delta <= 0;
      channels <= 0;
    end else if (start) begin
      state <= CLEAR;
      done <= 0;
      error <= 0;
      width <= 0;
      height <= 0;
      clear_addr <= 0;
      head_pos <= 0;
      end_pos <= 0;
      magic <= 0;
      prev <= 32'h000000ff;
      candidate <= 0;
      remaining <= 0;
      remaining_large <= 0;
      remaining_last <= 0;
      run_left <= 0;
    end else begin
      case (state)
        CLEAR:
        if (clear_addr == 63) state <= HEADER;
        else clear_addr <= clear_addr + 1'b1;
        HEADER:
        if (din_valid) begin
          head_pos <= head_pos + 1'b1;
          case (head_pos)
            0, 1, 2, 3: magic <= {magic[23:0], din};
            4, 5, 6, 7: width <= {width[23:0], din};
            8, 9, 10, 11: height <= {height[23:0], din};
            12: channels <= din;
            13: begin
              if (!EXTERNAL_PIXELS &&
                  (magic != 32'h716f6966 || width == 0 || width > 4096 || height == 0 ||
                   height > 4096 || (channels != 3 && channels != 4) || din > 1)) begin
                error <= 1;
                state <= STOP;
              end else begin
                remaining <= initial_remaining;
                remaining_large <= |initial_remaining[24:6];
                remaining_last <= initial_remaining == 1;
                state <= OP;
              end
            end
          endcase
        end
        OP:
        if (din_valid) begin
          run_left  <= 0;
          candidate <= prev;
          if (din == 8'hfe || din == 8'hff) begin
            rgba_op <= din[0];
            state   <= RGB_R;
          end else
            case (din[7:6])
              0: state <= INDEX_WAIT;
              1: begin
                candidate <= {rr, gg, bb, a};
                state <= EMIT;
              end
              2: begin
                green_delta <= {2'd0, din[5:0]} - 8'd32;
                state <= LUMA;
              end
              3: begin
                if (!remaining_large && din[5:0] >= remaining[5:0]) begin
                  error <= 1;
                  state <= STOP;
                end else begin
                  run_left <= din[5:0];
                  state <= EMIT;
                end
              end
            endcase
        end
        INDEX_WAIT: begin
          candidate <= index_q;
          state <= EMIT;
        end
        RGB_R:
        if (din_valid) begin
          candidate[31:24] <= din;
          state <= RGB_G;
        end
        RGB_G:
        if (din_valid) begin
          candidate[23:16] <= din;
          state <= RGB_B;
        end
        RGB_B:
        if (din_valid) begin
          candidate[15:8] <= din;
          state <= rgba_op ? RGBA_A : EMIT;
        end
        RGBA_A:
        if (din_valid) begin
          candidate[7:0] <= din;
          state <= EMIT;
        end
        LUMA:
        if (din_valid) begin
          candidate <= {lr, lg, lb, a};
          state <= EMIT;
        end
        EMIT:
        if (pixel_ready) begin
          prev <= candidate;
          remaining <= remaining - 1'b1;
          // Upper bits only change when the low six-bit digit borrows. Keep
          // predecoded flags aligned with the same decrement, not a cycle late.
          if (remaining[5:0] == 0) remaining_large <= remaining[24:6] != 1;
          remaining_last <= !remaining_large && remaining[5:0] == 2;
          if (remaining_last) begin
            state   <= ENDING;
            end_pos <= 0;
          end else if (run_left != 0) run_left <= run_left - 1'b1;
          else state <= OP;
        end
        ENDING:
        if (din_valid) begin
          if (din != ((end_pos == 7) ? 8'd1 : 8'd0)) begin
            error <= 1;
            state <= STOP;
          end else if (end_pos == 7) begin
            done  <= 1;
            state <= STOP;
          end else end_pos <= end_pos + 1'b1;
        end
      endcase
    end
  end
endmodule
