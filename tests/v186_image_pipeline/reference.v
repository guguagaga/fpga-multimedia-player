module image_fit_reference #(
  parameter integer OUT_W = 1280,
  parameter integer OUT_H = 720
) (
  input wire clk, rst, frame_start,
  input wire [15:0] src_w, src_h, aspect_h,
  input wire in_valid,
  input wire [23:0] in_pixel,
  output reg high, overflow,
  input wire out_blocked,
  output reg out_valid,
  output reg [23:0] out_pixel
);
  localparam WAIT=0, CONFIG=1, FIT=2, MARGINS=3, NEXT_ROW=4,
      READ_ROW=5, STORE=6, H_STEP=7, ROW_TAIL=8,
      FETCH=9, EMIT=10, V_STEP=11, DRAIN=12, DONE=13;
  reg [3:0] state;
  reg [23:0] fifo[0:511];
  reg [8:0] wp, rp;
  reg [9:0] count;
  reg [23:0] q;
  reg qvalid;
  reg [12:0] sw, sh, sx, sy, want_x, want_y, line_y, held_x;
  reg [10:0] fit_w, fit_h, left, top, right, bottom, dx, ox, oy;
  reg [13:0] h_rem, v_rem;
  reg [23:0] held, line_q;
  // Explicit 11-bit addressing and power-of-two storage are required for
  // TD to infer block RAM rather than thousands of distributed-memory LUTs.
  (* ram_style="bram" *) reg [23:0] linebuf[0:2047];
  wire [10:0] line_addr = ox-left;
  reg line_valid, wide;
  reg [23:0] scaled_w, scaled_h, numerator;
  reg [12:0] denominator;
  reg [10:0] quotient;
  wire take = qvalid && ((state == READ_ROW && sx <= want_x) ||
      (state == NEXT_ROW && sy < want_y) ||
      (state == ROW_TAIL && sy == want_y) || (state == DRAIN && sy < sh));
  wire fetch_fifo = (!qvalid || take) && count != 0;
  wire push = in_valid && count != 512;
  wire in_body = oy >= top && oy < bottom;
  wire in_picture = in_body && ox >= left && ox < right;
  always @(posedge clk) begin
    if (push) fifo[wp] <= in_pixel;
    if (fetch_fifo) q <= fifo[rp];
    if (state == STORE) linebuf[dx] <= held;
    if (state == FETCH) line_q <= linebuf[line_addr];
  end
  always @(posedge clk) begin
    if (rst || frame_start) begin
      wp <= 0; rp <= 0; count <= 0; qvalid <= 0;
      high <= 0; overflow <= 0;
    end else begin
      high <= count >= 256;
      if (in_valid && !push) overflow <= 1;
      if (push) wp <= wp + 1'b1;
      if (fetch_fifo) rp <= rp + 1'b1;
      case ({push,fetch_fifo})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: ;
      endcase
      if (fetch_fifo) qvalid <= 1;
      else if (take) qvalid <= 0;
    end
  end
  always @(posedge clk) begin
    if (rst || frame_start) begin
      state <= WAIT;
      sw <= 1; sh <= 1; sx <= 0; sy <= 0; want_x <= 0; want_y <= 0;
      line_y <= 0; line_valid <= 0; held_x <= 0;
      fit_w <= 1; fit_h <= 1; left <= 0; top <= 0; right <= 1; bottom <= 1;
      dx <= 0; ox <= 0; oy <= 0; h_rem <= 0; v_rem <= 0;
      held <= 0; wide <= 0; scaled_w <= 0; scaled_h <= 0;
      numerator <= 0; denominator <= 1; quotient <= 0;
      out_valid <= 0; out_pixel <= 0;
    end else begin
      out_valid <= 0;
      if (take) begin
        if (sx == sw-1'b1) begin sx <= 0; sy <= sy + 1'b1; end
        else sx <= sx + 1'b1;
      end
      case (state)
        WAIT: if (qvalid) begin
          sw <= src_w[12:0]; sh <= src_h[12:0];
          scaled_w <= src_w * OUT_H;
          scaled_h <= aspect_h * OUT_W;
          state <= CONFIG;
        end
        CONFIG: begin
          wide <= scaled_w >= scaled_h;
          numerator <= scaled_w >= scaled_h ? scaled_h : scaled_w;
          denominator <= scaled_w >= scaled_h ? sw : aspect_h[12:0];
          quotient <= 0;
          state <= FIT;
        end
        // A once-per-image iterative division keeps variable division out of
        // the pixel path. At most max(OUT_W, OUT_H) inexpensive clock cycles.
        FIT: if (numerator >= denominator && denominator != 0) begin
          numerator <= numerator - denominator;
          quotient <= quotient + 1'b1;
        end else begin
          fit_w <= wide ? OUT_W : ((quotient == 0) ? 1 : quotient);
          fit_h <= wide ? ((quotient == 0) ? 1 : quotient) : OUT_H;
          state <= MARGINS;
        end
        MARGINS: begin
          left <= (OUT_W-fit_w)/2; right <= (OUT_W-fit_w)/2+fit_w;
          top <= (OUT_H-fit_h)/2; bottom <= (OUT_H-fit_h)/2+fit_h;
          state <= NEXT_ROW;
        end
        NEXT_ROW: begin
          if (!in_body || (line_valid && line_y == want_y)) state <= FETCH;
          else if (sy == want_y) begin
            dx <= 0; want_x <= 0; h_rem <= 0; state <= READ_ROW;
          end
        end
        READ_ROW: if (take && sx == want_x) begin
          held <= q; held_x <= sx; state <= STORE;
        end
        STORE: begin
          if (dx == fit_w-1'b1) state <= ROW_TAIL;
          else begin dx <= dx + 1'b1; h_rem <= h_rem + sw; state <= H_STEP; end
        end
        H_STEP: if (h_rem >= fit_w) begin
          h_rem <= h_rem - fit_w; want_x <= want_x + 1'b1;
        end else state <= want_x == held_x ? STORE : READ_ROW;
        ROW_TAIL: if (sy != want_y) begin
          line_y <= want_y; line_valid <= 1; state <= FETCH;
        end
        FETCH: state <= EMIT;
        EMIT: if (!out_blocked) begin
          out_valid <= 1;
          out_pixel <= in_picture ? line_q : 24'd0;
          if (ox == OUT_W-1) begin
            ox <= 0;
            if (oy == OUT_H-1) state <= DRAIN;
            else begin
              oy <= oy + 1'b1;
              if (in_body) begin v_rem <= v_rem + sh; state <= V_STEP; end
              else state <= NEXT_ROW;
            end
          end else begin ox <= ox + 1'b1; state <= FETCH; end
        end
        V_STEP: if (v_rem >= fit_h) begin
          v_rem <= v_rem - fit_h; want_y <= want_y + 1'b1;
        end else state <= NEXT_ROW;
        DRAIN: if (sy >= sh) state <= DONE;
        DONE: ;
        default: state <= WAIT;
      endcase
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk) if (!rst && !frame_start) begin
    if (overflow) $fatal(1,"image-fit input overflow");
    if (state == STORE && dx >= OUT_W) $fatal(1,"image-fit line address");
  end
`endif
endmodule
