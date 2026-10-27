//===================================================================
// video_coord : rebuild pixel coordinate (active_x, active_y)
//===================================================================
// The official video pipeline (video_timing_data -> video_delay) only
// outputs hs/vs/de and RGB, but the OSD / spectrum overlays need the
// (x,y) pixel coordinate. This module rebuilds it from de and vs.
//
// Rebuild rules (verified against spectrum_display):
//   - active_x increments while de=1 (0..639), resets at line end
//   - active_y increments on the de falling edge (new line)
//   - active_y resets on the vs falling edge (new frame)
//
// active_x/active_y are aligned with de (same cycle), so an overlay
// reading them + de + RGB in the same clock sees consistent pixels.
//===================================================================
module video_coord (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        de,          // video valid (aligned)
    input  wire        vs,          // vertical sync (aligned)
    output reg  [10:0] active_x,    // pixel x 0..639
    output reg  [9:0]  active_y     // pixel y 0..479
);

    reg de_d, vs_d;
    wire vs_nedge = vs_d & ~vs;     // vs 1->0 = new frame

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
                active_y <= 10'd0;     // new frame
                active_x <= 11'd0;
            end else if (de) begin
                active_x <= active_x + 11'd1;   // valid pixel
            end else if (de_d) begin
                active_y <= active_y + 10'd1;   // line end
                active_x <= 11'd0;
            end
        end
    end

endmodule
