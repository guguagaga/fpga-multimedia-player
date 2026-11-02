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
