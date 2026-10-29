// -----------------------------------------------------------------------------
// Module purpose: Pairwise RGB565 packing for the frame writer.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
// Pixel 0 occupies bits15:0; pixel1 occupies bits31:16.
// Every row and frame must contain an even number of pixels.
module rgb565_pair_pack (
  input wire clk, clear, pixel_valid,
  input wire [31:0] pixel_rgbx,
  output wire word_valid,
  output wire [31:0] word_data
);
  reg phase;
  reg [15:0] first;
  wire [15:0] value = {pixel_rgbx[31:27], pixel_rgbx[23:18], pixel_rgbx[15:11]};
  assign word_valid = pixel_valid && phase && !clear;
  assign word_data  = {value, first};
  always @(posedge clk or posedge clear) begin
    if (clear) begin
      phase <= 0;
      first <= 0;
    end else if (pixel_valid) begin
      phase <= ~phase;
      if (!phase) first <= value;
    end
  end
endmodule

// Input must be a synchronous show-ahead FIFO word. Advance the FIFO only
// after consuming both halves. Output latency matches the former normal FIFO:
// pixel_valid at edge N -> pixel_rgbx valid just after edge N.
module rgb565_pair_unpack (
  input wire clk, clear, pixel_valid,
  input wire [31:0] word_data,
  output wire word_read,
  output reg [31:0] pixel_rgbx
);
  reg phase;
  wire [15:0] value = phase ? word_data[31:16] : word_data[15:0];
  assign word_read = pixel_valid && phase && !clear;
  always @(posedge clk or posedge clear) begin
    if (clear) begin
      phase <= 0;
      pixel_rgbx <= 0;
    end else if (pixel_valid) begin
      phase <= ~phase;
      pixel_rgbx <= {
        {value[15:11], value[15:13]}, {value[10:5], value[10:9]}, {value[4:0], value[4:2]}, 8'd0
      };
    end
  end
endmodule
