//===================================================================
// seg595_display : EDA expansion board 8 digit display driver
//===================================================================
// The EDA V3.0 board carries two cascaded SN74HC595 that drive
//   - 8 segment lines : HEX_A, HEX_B, HEX_C, HEX_D, HEX_E, HEX_F,
//                       HEX_G, HEX_DP
//   - 8 digit selects : HEX_SEL0 .. HEX_SEL7
// The FPGA only sees three pins on P1:
//   P1-13 SEG7_DIO   -> SER   of the first 595 in the chain
//   P1-15 SEG7_SCLK  -> SRCLK of both 595 (shared)
//   P1-12 SEG7_RCLK  -> RCLK  of both 595 (shared)
//
// FRAME FORMAT (the single place that defines the wire order)
// -----------------------------------------------------------
// One 16 bit frame is shifted out MSB first. A rising edge on SEG7_RCLK
// copies the shift registers to the outputs, so the panel changes as a
// whole and never shows a half updated frame.
//
//   seg_byte[0] = HEX_A     seg_byte[6] = HEX_G     seg_byte[7] = HEX_DP
//   dig_byte[0] = HEX_SEL0  dig_byte[7] = HEX_SEL7
//   frame[15:0] = SEG_BYTE_FIRST ? {seg_byte, dig_byte}
//                                 : {dig_byte, seg_byte}
//
// A 595 chain inverts the order of the bytes: the FIRST 8 bits shifted in
// end up in the SECOND device of the chain (the one fed by the first
// device's QH'), the LAST 8 bits stay in the FIRST device. The board
// schematic in this package is a flat net list and does not record which
// device drives the segments, so the byte order is a parameter:
//   SEG_BYTE_FIRST = 0 (default): the segment byte is shifted LAST, i.e.
//         the segments are driven by the FIRST 595 of the chain.
//   SEG_BYTE_FIRST = 1          : the segment byte is shifted FIRST, i.e.
//         the segments are driven by the SECOND 595 of the chain.
//
// PANEL CONTENT (physical position 0 = leftmost .. 7 = rightmost)
// --------------------------------------------------------------
//   pos 0 : 'A' while the carousel is running, '-' while it is off
//   pos 1 : 'P'  (panel marker)
//   pos 2 : preset code in hex, 0 .. F
//   pos 3 : '-'
//   pos 4 : period, hundreds
//   pos 5 : period, tens
//   pos 6 : period, units
//   pos 7 : 'S'  (unit marker)
//
// BRING UP TABLE (all of these are display only, none of them can
// stop the carousel or the audio path):
//   every segment dark            -> flip SEG_ACT_LOW
//   every digit lit at once       -> flip DIG_ACT_LOW
//   digits mirrored left/right    -> flip DIG_SEL0_LEFT
//   one digit lit, garbage shape  -> flip SEG_BYTE_FIRST
//===================================================================
module seg595_display #(
  parameter integer CLK_FREQ_HZ    = 100_000_000,
  parameter integer SEG_BYTE_FIRST = 0,   // see FRAME FORMAT above
  parameter integer DIG_SEL0_LEFT  = 1,   // 1 = HEX_SEL0 is the leftmost digit
  parameter integer SEG_ACT_LOW    = 1,   // 1 = common anode, 0 lights the segment
  parameter integer DIG_ACT_LOW    = 0    // 1 = digit select active LOW
) (
  input            clk,
  input            rst,          // active HIGH
  input            carousel_on,
  input      [3:0] preset_code,  // preset in effect
  output reg       seg_rclk,     // P1-12 SEG7_RCLK
  output reg       seg_dio,      // P1-13 SEG7_DIO
  output reg       seg_sclk      // P1-15 SEG7_SCLK
);

  // ---------------------------------------------------------------
  // Timing constants
  // ---------------------------------------------------------------
  // Shift clock = 1 MHz (0.5 us half period). 74HC/HCT at 3.3 V is
  // good for tens of MHz, so this is deliberately slow: the wires to
  // the expansion board are dupont leads, not a PCB.
  localparam integer HALF_RAW  = CLK_FREQ_HZ / 2_000_000;
  localparam integer HALF_CLKS = (HALF_RAW < 1) ? 1 : HALF_RAW;

  // One digit slot = 1 ms => 8 ms per full frame => 125 Hz refresh,
  // comfortably above the 50 Hz flicker limit.
  localparam integer SLOT_RAW  = CLK_FREQ_HZ / 1000;
  localparam integer SLOT_CLKS = (SLOT_RAW < 8) ? 8 : SLOT_RAW;

  // ---------------------------------------------------------------
  // Segment decoder: active HIGH, bit0 = a ... bit6 = g
  //   0..15 = hex digit, 16 = 'P', 17 = '-', 18 = 'S', 19 = blank
  // ---------------------------------------------------------------
  function [6:0] glyph7;
    input [4:0] code;
    begin
      case (code)
        5'd0: glyph7 = 7'h3F;
        5'd1: glyph7 = 7'h06;
        5'd2: glyph7 = 7'h5B;
        5'd3: glyph7 = 7'h4F;
        5'd4: glyph7 = 7'h66;
        5'd5: glyph7 = 7'h6D;
        5'd6: glyph7 = 7'h7D;
        5'd7: glyph7 = 7'h07;
        5'd8: glyph7 = 7'h7F;
        5'd9: glyph7 = 7'h6F;
        5'd10: glyph7 = 7'h77;  // A
        5'd11: glyph7 = 7'h7C;  // b
        5'd12: glyph7 = 7'h39;  // C
        5'd13: glyph7 = 7'h5E;  // d
        5'd14: glyph7 = 7'h79;  // E
        5'd15: glyph7 = 7'h71;  // F
        5'd16: glyph7 = 7'h73;  // P
        5'd17: glyph7 = 7'h40;  // -
        5'd18: glyph7 = 7'h6D;  // S (same shape as 5)
        default: glyph7 = 7'h00;  // blank
      endcase
    end
  endfunction

  // ---------------------------------------------------------------
  // Preset code -> decimal digits of the period in seconds.
  // A lookup instead of a /100 and /10 divider: the period only ever
  // takes these 16 values, and constant division would burn LUTs (or
  // a DSP, of which only 2 are free) for nothing.
  // ---------------------------------------------------------------
  function [11:0] bcd_lut;  // {hundreds[3:0], tens[3:0], units[3:0]}
    input [3:0] code;
    begin
      case (code)
        4'd0: bcd_lut = {4'd0, 4'd0, 4'd2};  //   2 s
        4'd1: bcd_lut = {4'd0, 4'd0, 4'd3};  //   3 s
        4'd2: bcd_lut = {4'd0, 4'd0, 4'd5};  //   5 s
        4'd3: bcd_lut = {4'd0, 4'd0, 4'd8};  //   8 s
        4'd4: bcd_lut = {4'd0, 4'd1, 4'd0};  //  10 s
        4'd5: bcd_lut = {4'd0, 4'd1, 4'd5};  //  15 s
        4'd6: bcd_lut = {4'd0, 4'd2, 4'd0};  //  20 s
        4'd7: bcd_lut = {4'd0, 4'd3, 4'd0};  //  30 s
        4'd8: bcd_lut = {4'd0, 4'd4, 4'd5};  //  45 s
        4'd9: bcd_lut = {4'd0, 4'd6, 4'd0};  //  60 s
        4'd10: bcd_lut = {4'd0, 4'd9, 4'd0};  //  90 s
        4'd11: bcd_lut = {4'd1, 4'd2, 4'd0};  // 120 s
        4'd12: bcd_lut = {4'd1, 4'd8, 4'd0};  // 180 s
        4'd13: bcd_lut = {4'd2, 4'd4, 4'd0};  // 240 s
        4'd14: bcd_lut = {4'd3, 4'd0, 4'd0};  // 300 s
        default: bcd_lut = {4'd6, 4'd0, 4'd0};  // 600 s
      endcase
    end
  endfunction

  localparam [4:0] GL_P     = 5'd16;
  localparam [4:0] GL_DASH  = 5'd17;
  localparam [4:0] GL_S     = 5'd18;
  localparam [4:0] GL_BLANK = 5'd19;

  // (a part select of a function call is not legal Verilog-2001, so the
  //  packed result goes through a wire first)
  wire [11:0] bcd_now = bcd_lut(preset_code);
  wire [ 3:0] bcd_h = bcd_now[11:8];
  wire [ 3:0] bcd_t = bcd_now[7:4];
  wire [ 3:0] bcd_u = bcd_now[3:0];

  // ---------------------------------------------------------------
  // Panel content for physical position `digidx`
  // ---------------------------------------------------------------
  reg  [ 2:0] digidx;  // physical position, 0 = leftmost
  reg  [ 4:0] cur_glyph;

  always @(*) begin
    case (digidx)
      3'd0:    cur_glyph = carousel_on ? 5'd10 : GL_DASH;  // 'A' or '-'
      3'd1:    cur_glyph = GL_P;
      3'd2:    cur_glyph = { 1'b0, preset_code };
      3'd3:    cur_glyph = GL_DASH;
      3'd4:    cur_glyph = { 1'b0, bcd_h };
      3'd5:    cur_glyph = { 1'b0, bcd_t };
      3'd6:    cur_glyph = { 1'b0, bcd_u };
      default: cur_glyph = GL_S;
    endcase
  end

  wire [ 6:0] pat_on = glyph7(cur_glyph);

  // segment byte: bit7 = DP, bit6..0 = g..a. DP is always off.
  wire [ 7:0] seg_byte = SEG_ACT_LOW ? ~{1'b0, pat_on} : {1'b0, pat_on};

  // which HEX_SELk drives physical position `digidx`
  wire [ 2:0] sel_pos = DIG_SEL0_LEFT ? (3'd7 - digidx) : digidx;

  // exactly one digit on
  wire [ 7:0] dig_byte = DIG_ACT_LOW ? ~(8'd1 << sel_pos) : (8'd1 << sel_pos);

  wire [15:0] frame = SEG_BYTE_FIRST ? {seg_byte, dig_byte} : {dig_byte, seg_byte};

  // ---------------------------------------------------------------
  // Shift / latch / dwell state machine
  // ---------------------------------------------------------------
  localparam [1:0] ST_LOAD = 2'd0, ST_SHIFT = 2'd1, ST_LATCH = 2'd2, ST_DWELL = 2'd3;

  reg [ 1:0] st;
  reg [15:0] sr;
  reg [ 3:0] bitc;
  reg [ 6:0] halfc;  // >= HALF_CLKS (50 at 100 MHz)
  reg [16:0] dwell;  // >= SLOT_CLKS (100000 at 100 MHz)

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      st       <= ST_LOAD;
      sr       <= 16'd0;
      bitc     <= 4'd15;
      halfc    <= 7'd0;
      dwell    <= 17'd0;
      digidx   <= 3'd0;
      seg_rclk <= 1'b0;
      seg_dio  <= 1'b0;
      seg_sclk <= 1'b0;
    end else begin
      case (st)
        // load the complete frame for this digit, present bit 15
        ST_LOAD: begin
          sr       <= frame;
          bitc     <= 4'd15;
          halfc    <= 7'd0;
          dwell    <= 17'd0;
          seg_dio  <= frame[15];
          seg_sclk <= 1'b0;
          seg_rclk <= 1'b0;
          st       <= ST_SHIFT;
        end

        // 16 bits, MSB first. Data changes while SCLK is LOW, the
        // 595 samples on the SCLK rising edge.
        ST_SHIFT: begin
          if (halfc >= (HALF_CLKS - 1)) begin
            halfc <= 7'd0;
            if (!seg_sclk) begin
              seg_sclk <= 1'b1;  // rising edge: sample dio
            end else begin
              seg_sclk <= 1'b0;
              if (bitc != 4'd0) begin
                sr    <= { sr[14:0], 1'b0 };
                seg_dio <= sr[14];
                bitc  <= bitc - 4'd1;
              end else begin
                st <= ST_LATCH;
              end
            end
          end else begin
            halfc <= halfc + 7'd1;
          end
        end

        // RCLK pulse: 8 clk = 80 ns, far above the 13 ns minimum
        ST_LATCH: begin
          if (!seg_rclk) begin
            seg_rclk <= 1'b1;
            halfc    <= 7'd0;
          end else if (halfc >= 7'd7) begin
            seg_rclk <= 1'b0;
            halfc    <= 7'd0;
            dwell    <= 17'd0;
            st       <= ST_DWELL;
          end else begin
            halfc <= halfc + 7'd1;
          end
        end

        // keep the digit visible for one slot
        ST_DWELL: begin
          if (dwell >= (SLOT_CLKS - 1)) begin
            dwell  <= 17'd0;
            digidx <= digidx + 3'd1;
            st     <= ST_LOAD;
          end else begin
            dwell <= dwell + 17'd1;
          end
        end

        default: st <= ST_LOAD;
      endcase
    end
  end

endmodule
