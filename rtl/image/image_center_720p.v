// -----------------------------------------------------------------------------
// Module purpose: Image placement within the 720P output raster.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
// Preserve the proven 800x600 image/scaler path, centering its raster within
// a 1280x720 frame. Queued pixels tolerate SD-sector and 5/4-expander bursts.
// Orientation is handled by the frame writer as before; symmetric margins
// remain centered for either top-down QOI/BMP or bottom-up BMP.
module image_center_720p (
  input wire clk, rst, disable_image, write_req,
  input wire source_valid,
  input wire [31:0] source_data,
  output wire source_high,
  input wire sink_high,
  output reg out_valid,
  output reg [31:0] out_data
);
  reg [23:0] fifo[0:511];
  reg [9:0] wp, rp;
  reg [23:0] fifo_q;
  reg [10:0] x;
  reg [ 9:0] y;
  reg running, primed;
  reg empty_q, one_q;
  reg [5:0] settle;
  wire [9:0] used = wp - rp;
  wire center = (x >= 240 && x < 1040 && y >= 60 && y < 660);
  wire fire = running && settle == 0 && !sink_high && (!center || (!empty_q && primed));
  assign source_high = used >= 128;
  // Predict exact empty/one-entry state after each accepted push/pop.
  // This removes wp-rp -> empty reduction from the high-fanout pixel enable.
  // No extra latency is introduced in the FIFO or its backpressure.
  wire pop = fire && center;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      empty_q <= 1;
      one_q   <= 0;
    end else if (disable_image || write_req) begin
      empty_q <= 1;
      one_q   <= 0;
    end else
      case ({
        source_valid, pop
      })
        2'b10: begin
          empty_q <= 0;
          one_q   <= empty_q;
        end
        2'b01: begin
          empty_q <= one_q;
          one_q   <= used == 2;
        end
        default: ;
      endcase
  end
  // Synchronous read, forward next pointer when consuming the current pixel.
  always @(posedge clk) begin
    fifo_q <= fifo[(fire && center) ? (rp[8:0] + 9'd1) : rp[8:0]];
    if (source_valid) fifo[wp[8:0]] <= source_data[31:8];
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      wp <= 0;
      rp <= 0;
      x <= 0;
      y <= 0;
      running <= 0;
      primed <= 0;
      settle <= 0;
      out_valid <= 0;
      out_data <= 0;
    end else begin
      out_valid <= 0;
      if (disable_image) begin
        wp <= 0;
        rp <= 0;
        running <= 0;
        primed <= 0;
        settle <= 0;
      end else if (write_req) begin
        wp <= 0;
        rp <= 0;
        x <= 0;
        y <= 0;
        running <= 1;
        primed <= 0;
        settle <= 32;
      end else begin
        if (source_valid) wp <= wp + 1'b1;
        if (!primed && !empty_q) primed <= 1;
        if (fire && center && one_q) primed <= 0;
        if (settle != 0) settle <= settle - 1'b1;
        if (fire) begin
          out_valid <= 1;
          out_data  <= center ? {fifo_q, 8'd0} : 32'd0;
          if (center) rp <= rp + 1'b1;
          if (x == 1279) begin
            x <= 0;
            if (y == 719) begin
              y <= 0;
              running <= 0;
            end else y <= y + 1'b1;
          end else x <= x + 1'b1;
        end
      end
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk)
    if (!rst && !disable_image && !write_req) begin
      if (empty_q !== (used == 0) || one_q !== (used == 1))
        $fatal(1, "image-center occupancy flags mismatch");
      if (source_valid && used >= 511) $fatal(1, "720p image pad input overflow");
    end
`endif
endmodule
