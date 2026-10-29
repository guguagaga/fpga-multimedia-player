//===================================================================
// cordic_atan : CORDIC vector-mode arctangent -> spectrum angle bin
//===================================================================
// Computes the angle of a screen-space vector (dx, dy) and maps it to
// a 0..47 bin (48 bins evenly spaced around a full circle).
//
// Screen convention: y grows DOWNWARD (screen top = y0).
//   angle_math = atan2(dy, dx), 0 = right, + = downward (screen).
// We remap so bin 0 sits at the TOP (12 o'clock) and increases
// CLOCKWISE (top -> right -> bottom -> left), the classic audio-
// spectrum layout.
//
// Angle format: Q16 unsigned, full circle = 65536.
//   bin = clock_angle * 48 / 65536  (48 bins)
//
// Pipeline latency: 1 pre-process + STAGES CORDIC stages cycles.
//   dout_valid is din_valid delayed by that same latency.
//===================================================================
module cordic_atan #(
  parameter STAGES = 8
) (
  input  wire               clk,
  input  wire               rst_n,
  input  wire               din_valid,
  input  wire signed [ 9:0] dx,          // x - center_x, range [-320, 319]
  input  wire signed [ 9:0] dy,          // y - center_y, range [-240, 239]
  output wire               dout_valid,
  output wire        [ 5:0] bin,
  output wire        [11:0] bin_frac
);

  // ---- CORDIC angle table : atan(2^-i) in Q16 (65536 = 360 deg) ----
  function signed [15:0] atan_lut;
    input integer i;
    begin
      case (i)
        0: atan_lut = 16'sd8192;  // atan(2^-0) = 45.000 deg
        1: atan_lut = 16'sd4836;  // atan(2^-1) = 26.565 deg
        2: atan_lut = 16'sd2556;  // atan(2^-2) = 14.036 deg
        3: atan_lut = 16'sd1297;  // atan(2^-3) =  7.125 deg
        4: atan_lut = 16'sd651;  // atan(2^-4) =  3.576 deg
        5: atan_lut = 16'sd326;  // atan(2^-5) =  1.790 deg
        6: atan_lut = 16'sd163;  // atan(2^-6) =  0.895 deg
        7: atan_lut = 16'sd82;  // atan(2^-7) =  0.448 deg
        default: atan_lut = 16'sd0;
      endcase
    end
  endfunction

  // ---- pipeline arrays ----
  reg signed  [    15:0] x_s                                           [0:STAGES];
  reg signed  [    15:0] y_s                                           [0:STAGES];
  reg signed  [    15:0] th_s                                          [0:STAGES];
  reg         [    15:0] base_s                                        [0:STAGES];
  reg                    neg_s                                         [0:STAGES];
  reg         [STAGES:0] v_s;

  // ---- Stage 0 : quadrant preprocessing (combinational inputs) ----
  wire signed [     9:0] dx_abs = dx[9] ? (~dx + 10'sd1) : dx;  // |dx|
  wire signed [     9:0] dy_abs = dy[9] ? (~dy + 10'sd1) : dy;  // |dy|
  wire        [     1:0] quadrant = {dx[9], dy[9]};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x_s[0] <= 16'sd0;
      y_s[0] <= 16'sd0;
      th_s[0] <= 16'sd0;
      base_s[0] <= 16'd0;
      neg_s[0] <= 1'b0;
      v_s[0] <= 1'b0;
    end else begin
      x_s[0]  <= {{6{1'b0}}, dx_abs};  // zero-extend to 16 bits (positive)
      y_s[0]  <= {{6{1'b0}}, dy_abs};
      th_s[0] <= 16'sd0;
      v_s[0]  <= din_valid;

      // base / neg encode the quadrant mapping:
      //   Q1 (dx>=0, dy>=0): angle = 0      + th
      //   Q2 (dx<0 , dy>=0): angle = 32768  - th
      //   Q3 (dx<0 , dy<0 ): angle = 32768  + th
      //   Q4 (dx>=0, dy<0 ): angle = 0      - th  (== 65536 - th)
      case (quadrant)
        2'b00: begin
          base_s[0] <= 16'd0;
          neg_s[0]  <= 1'b0;
        end
        2'b10: begin
          base_s[0] <= 16'd32768;
          neg_s[0]  <= 1'b1;
        end
        2'b11: begin
          base_s[0] <= 16'd32768;
          neg_s[0]  <= 1'b0;
        end
        2'b01: begin
          base_s[0] <= 16'd0;
          neg_s[0]  <= 1'b1;
        end
        default: begin
          base_s[0] <= 16'd0;
          neg_s[0]  <= 1'b0;
        end
      endcase
    end
  end

  // ---- Stages 1..STAGES : CORDIC vector-mode iterations ----
  genvar gi;
  generate
    for (gi = 0; gi < STAGES; gi = gi + 1) begin : gen_cordic
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          x_s[gi+1] <= 16'sd0;
          y_s[gi+1] <= 16'sd0;
          th_s[gi+1] <= 16'sd0;
          base_s[gi+1] <= 16'd0;
          neg_s[gi+1] <= 1'b0;
          v_s[gi+1] <= 1'b0;
        end else begin
          if (y_s[gi] >= 16'sd0) begin
            x_s[gi+1]  <= x_s[gi] + (y_s[gi] >>> gi);
            y_s[gi+1]  <= y_s[gi] - (x_s[gi] >>> gi);
            th_s[gi+1] <= th_s[gi] + atan_lut(gi);
          end else begin
            x_s[gi+1]  <= x_s[gi] - (y_s[gi] >>> gi);
            y_s[gi+1]  <= y_s[gi] + (x_s[gi] >>> gi);
            th_s[gi+1] <= th_s[gi] - atan_lut(gi);
          end
          base_s[gi+1] <= base_s[gi];
          neg_s[gi+1]  <= neg_s[gi];
          v_s[gi+1]    <= v_s[gi];
        end
      end
    end
  endgenerate

  // ---- final : math angle -> clock angle (top=0, clockwise) ----
  wire signed [15:0] th_final = th_s[STAGES];
  wire [15:0]
      angle_math = neg_s[STAGES] ? (base_s[STAGES] - th_final) : (base_s[STAGES] + th_final);
  // +90 deg (Q16 16384) puts bin 0 at the top; unsigned wrap = modulo 360.
  wire [15:0] clock_angle = angle_math + 16'd16384;

  assign dout_valid = v_s[STAGES];
  // 48 bars around the circle: bin = clock_angle * 48 / 65536
  //   = clock_angle * 3 / 4096, bin 0 at the top, clockwise.
  // bin_q keeps the fractional part (Q12) so the display can
  // interpolate between adjacent bars (smooth continuous envelope).
  wire [17:0] bin_q = clock_angle * 16'd3;  // 18-bit, 0..196605
  assign bin      = bin_q[17:12];  // integer bar 0..47
  assign bin_frac = bin_q[11:0];  // fractional Q12 0..4095

endmodule
