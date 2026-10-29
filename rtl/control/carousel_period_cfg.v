//===================================================================
// carousel_period_cfg : auto carousel period preset (16 steps)
//===================================================================
// A 4 bit DIP switch (exp_sw[3:0], active LOW) selects the auto carousel
// period. The switch is decoded to a logical code 0..15 first
// (0 = every switch OFF) and then mapped to a bounded period in seconds:
//
//   code :  0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
//   sec  :  2   3   5   8  10  15  20  30  45  60  90 120 180 240 300 600
//
// The table is strictly increasing, has no 0 entry and fits in 10 bits
// (600 < 1024), so the saturating second counter downstream can never
// wrap and never sees a zero or negative period.
//
// A new preset is NOT taken the moment the switch changes. It is taken
// at `boundary`, which the top level drives with
//     (!auto_on) || image load finished
// so a period change can never disturb an in flight image load or a
// pending prefetch, and the carousel keeps its current deadline until
// the picture on screen has finished loading.
//===================================================================
module carousel_period_cfg (
  input            clk,
  input            rst,          // active HIGH
  input      [3:0] preset_sel,   // synchronized + debounced switch code
  input            boundary,     // 1 = a new preset may be taken now
  output reg [3:0] preset_code,  // preset that is in effect
  output reg [9:0] period_sec,   // period that is in effect (2 .. 600 s)
  output     [9:0] preset_sec    // decode of preset_sel (not latched)
);

  // ---------------------------------------------------------------
  // Preset table. Written as a function so the same decode is used
  // for the latched value and for the read only probe.
  // ---------------------------------------------------------------
  function [9:0] period_lut;
    input [3:0] code;
    begin
      case (code)
        4'd0: period_lut = 10'd2;
        4'd1: period_lut = 10'd3;
        4'd2: period_lut = 10'd5;
        4'd3: period_lut = 10'd8;
        4'd4: period_lut = 10'd10;
        4'd5: period_lut = 10'd15;
        4'd6: period_lut = 10'd20;
        4'd7: period_lut = 10'd30;
        4'd8: period_lut = 10'd45;
        4'd9: period_lut = 10'd60;
        4'd10: period_lut = 10'd90;
        4'd11: period_lut = 10'd120;
        4'd12: period_lut = 10'd180;
        4'd13: period_lut = 10'd240;
        4'd14: period_lut = 10'd300;
        default: period_lut = 10'd600;  // 4'd15, and any X/Z code
      endcase
    end
  endfunction

  assign preset_sec = period_lut(preset_sel);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      // power up default = code 0 = 2 s. The carousel itself powers
      // up OFF, so this value is not visible until the user turns
      // the carousel on.
      preset_code <= 4'd0;
      period_sec  <= 10'd2;
    end else if (boundary) begin
      preset_code <= preset_sel;
      period_sec  <= period_lut(preset_sel);
    end
  end

endmodule
