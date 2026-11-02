// Reconstruct active pixel coordinates from DE and VS.
// X advances during DE; Y advances at line end and resets at frame sync.
// Coordinates align with the active pixel stream for OSD and spectrum overlays.
module video_coord (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        de,        // video valid (aligned)
  input  wire        vs,        // vertical sync (aligned)
  output reg  [10:0] active_x,  // pixel x 0..639
  output reg  [ 9:0] active_y   // pixel y 0..479
);

  reg de_d, vs_d;
  wire vs_nedge = vs_d & ~vs;  // vs 1->0 = new frame

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_x <= 11'd0;
      active_y <= 10'd0;
      de_d     <= 1'b0;
      vs_d     <= 1'b0;
    end else begin
      de_d <= de;
      vs_d <= vs;
      if (vs_nedge) begin
        active_y <= 10'd0;  // new frame
        active_x <= 11'd0;
      end else if (de) begin
        active_x <= active_x + 11'd1;  // valid pixel
      end else if (de_d) begin
        active_y <= active_y + 10'd1;  // line end
        active_x <= 11'd0;
      end
    end
  end

endmodule
