// Two real multipliers shared across the real and imaginary complex products.
// A transaction occupies three edges: first products, second products, output.
module butterfly (
  input wire clk, rst_n, din_valid,
  input wire [15:0] x0_re, x0_im, x1_re, x1_im, w_re, w_im,
  output reg dout_valid,
  output reg signed [15:0] y0_re, y0_im, y1_re, y1_im
);
  reg [1:0] phase;
  reg signed [15:0] ar, ai, br, bi, wr, wi;
  reg signed [31:0] p1, p2;
  reg signed  [17:0] tr;
  wire signed [17:0] m1a = (phase == 1) ? wr : $signed(w_re);
  wire signed [17:0] m2a = (phase == 1) ? wi : $signed(w_im);
  wire signed [17:0] m1b = (phase == 1) ? bi : $signed(x1_re);
  wire signed [17:0] m2b = (phase == 1) ? br : $signed(x1_im);
  wire signed [32:0] ep1 = {p1[31], p1}, ep2 = {p2[31], p2};
  wire signed [32:0] real_product = ep1 - ep2 + 33'sd16384;
  wire signed [32:0] imag_product = ep1 + ep2 + 33'sd16384;
  wire signed [17:0] ti = imag_product >>> 15;
  wire signed [17:0] arx = {{2{ar[15]}}, ar}, aix = {{2{ai[15]}}, ai};
  function [15:0] half_sat;
    input signed [17:0] x;
    reg signed [17:0] h;
    begin
      h = x >>> 1;
      if (h > 32767) half_sat = 16'h7fff;
      else if (h < -32768) half_sat = 16'h8000;
      else half_sat = h[15:0];
    end
  endfunction
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= 0;
      ar <= 0;
      ai <= 0;
      br <= 0;
      bi <= 0;
      wr <= 0;
      wi <= 0;
      p1 <= 0;
      p2 <= 0;
      tr <= 0;
      dout_valid <= 0;
      y0_re <= 0;
      y0_im <= 0;
      y1_re <= 0;
      y1_im <= 0;
    end else begin
      p1 <= m1a * m1b;
      p2 <= m2a * m2b;
      dout_valid <= 0;
      if (din_valid) begin
        ar <= x0_re;
        ai <= x0_im;
        br <= x1_re;
        bi <= x1_im;
        wr <= w_re;
        wi <= w_im;
        phase <= 1;
      end else if (phase == 1) begin
        tr <= real_product >>> 15;
        phase <= 2;
      end else if (phase == 2) begin
        y0_re <= half_sat(arx + tr);
        y1_re <= half_sat(arx - tr);
        y0_im <= half_sat(aix + ti);
        y1_im <= half_sat(aix - ti);
        dout_valid <= 1;
        phase <= 0;
      end
    end
  end
endmodule
