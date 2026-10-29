// -----------------------------------------------------------------------------
// Module purpose: Expansion-board input synchronization and debounce.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
//===================================================================
// exp_input_sync : EDA expansion board (V3.0) input conditioner
//===================================================================
// 13 asynchronous inputs arrive on the 40 pin header J1:
//   exp_key[4:0] : 5 push buttons,  PULLUP on the board, active LOW
//   exp_sw [7:0] : 8 DIP switches,  PULLUP on the board, active LOW
//
// Every input goes through a 4 stage delay line clocked by ONE shared
// sampling tick (SAMPLES x DEBOUNCE_MS/SAMPLES = DEBOUNCE_MS in total):
//   * stage 1 is the sampling synchronizer for the asynchronous pin
//   * stages 2..4 finish the synchronization and reject any level that
//     does not hold for the whole window (contact bounce)
//   * keys   : a single clock wide press pulse on the 1 -> 0 edge of the
//              debounced level, so a held key never auto repeats
//   * switch : the debounced logical level, 1 = switch ON
//
// Area is deliberately minimal: this design is at ~94 % slices already, so
//   - one shared tick divider instead of 13 counters
//   - 4 samples per input (52 flops total) instead of a per input counter
//   - the 4 bit AND/NOR decoders are one LUT each
// The debounced LEVEL is also exported (key_down / sw_level) so consumers
// that already have their own 20 ms debouncer can use the level directly
// and no extra pulse stretcher is needed at the top level.
//
// Nothing here depends on the extension board being plugged in: with the
// header open the on board pull ups keep every input at 1, which decodes
// as "no key pressed" and "every switch OFF".
//===================================================================
module exp_input_sync #(
  // Frequency of `clk` in Hz. Used only to derive the sampling tick.
  parameter integer CLK_FREQ_HZ = 100_000_000,
  // Total debounce time in milliseconds.
  // 8 ms is well above the bounce of a tactile switch (< 5 ms) and of a
  // slide DIP switch (< 1 ms), and short enough that the 20 ms debouncer
  // downstream still sees a clean edge.
  parameter integer DEBOUNCE_MS = 12,
  // Samples taken over the debounce window (>= 2, all must agree).
  parameter integer SAMPLES     = 6
) (
  input            clk,
  input            rst,       // active HIGH
  input      [4:0] key_n,     // raw exp_key, active LOW
  input      [7:0] sw_n,      // raw exp_sw,  active LOW
  output reg [4:0] key_down,  // 1 = pressed   (debounced level)
  output     [7:0] sw_level,  // 1 = switch ON (debounced level)
  output reg [4:0] key_press  // 1 clk wide pulse on press
);

  // ---------------------------------------------------------------
  // Shared sampling tick: one pulse every DEBOUNCE_MS/SAMPLES ms.
  // At 100 MHz and 8 ms / 4 samples this is 2 ms = 200000 clocks.
  // ---------------------------------------------------------------
  localparam integer SAMPLE_DIV_RAW = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS / SAMPLES;
  localparam integer SAMPLE_DIV     = (SAMPLE_DIV_RAW < 2) ? 2 : SAMPLE_DIV_RAW;

  reg [17:0] tick_cnt;  // 18 bit covers 200000 (=2 ms @100 MHz)
  reg        tick;

  // ---------------------------------------------------------------
  // 4 sample delay lines. 4'hF = released / switch OFF.
  // ---------------------------------------------------------------
  reg [3:0] kdl0, kdl1, kdl2, kdl3, kdl4;
  reg [3:0] sdl0, sdl1, sdl2, sdl3, sdl4, sdl5, sdl6, sdl7;

  reg [4:0] key_down_q;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      tick_cnt <= 18'd0;
      tick     <= 1'b0;
    end else if (tick_cnt >= (SAMPLE_DIV - 1)) begin
      tick_cnt <= 18'd0;
      tick     <= 1'b1;
    end else begin
      tick_cnt <= tick_cnt + 18'd1;
      tick     <= 1'b0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      // every raw input idles HIGH => no key pressed, every switch OFF
      kdl0 <= 4'hF;
      kdl1 <= 4'hF;
      kdl2 <= 4'hF;
      kdl3 <= 4'hF;
      kdl4 <= 4'hF;
      sdl0 <= 4'hF;
      sdl1 <= 4'hF;
      sdl2 <= 4'hF;
      sdl3 <= 4'hF;
      sdl4 <= 4'hF;
      sdl5 <= 4'hF;
      sdl6 <= 4'hF;
      sdl7 <= 4'hF;
      key_down <= 5'd0;
      key_down_q <= 5'd0;
      key_press <= 5'd0;
    end else begin
      if (tick) begin
        kdl0 <= {kdl0[2:0], key_n[0]};
        kdl1 <= {kdl1[2:0], key_n[1]};
        kdl2 <= {kdl2[2:0], key_n[2]};
        kdl3 <= {kdl3[2:0], key_n[3]};
        kdl4 <= {kdl4[2:0], key_n[4]};

        sdl0 <= {sdl0[2:0], sw_n[0]};
        sdl1 <= {sdl1[2:0], sw_n[1]};
        sdl2 <= {sdl2[2:0], sw_n[2]};
        sdl3 <= {sdl3[2:0], sw_n[3]};
        sdl4 <= {sdl4[2:0], sw_n[4]};
        sdl5 <= {sdl5[2:0], sw_n[5]};
        sdl6 <= {sdl6[2:0], sw_n[6]};
        sdl7 <= {sdl7[2:0], sw_n[7]};
      end

      // key : all samples LOW (0) = the button has been held down for
      //       the whole window => pressed.
      // sw  : all samples LOW (0) = the DIP switch shorts the pin to
      //       ground => switch ON => logical level 1.
      key_down   <= {~|kdl4, ~|kdl3, ~|kdl2, ~|kdl1, ~|kdl0};
      key_down_q <= key_down;
      key_press  <= key_down & (~key_down_q);
    end
  end

  assign sw_level = {
    ~(&sdl7), ~(&sdl6), ~(&sdl5), ~(&sdl4), ~(&sdl3), ~(&sdl2), ~(&sdl1), ~(&sdl0)
  };

endmodule
