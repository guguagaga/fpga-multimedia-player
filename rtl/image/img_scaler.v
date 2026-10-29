// -----------------------------------------------------------------------------
// Module purpose: Image scaling and output-raster adaptation.
// Integration/validation: docs/ARCHITECTURE.md and docs/MODULE_INDEX.md.
// -----------------------------------------------------------------------------
//===================================================================
// img_scaler : scale a W x H pixel stream to exactly DST_W x DST_H.
//              Nearest neighbour, no line buffer.
//===================================================================
// THE LOCKED ALGORITHM  (verified pixel-exact for 640x480 .. 4096x2160)
//   The source is ONE FLAT STREAM of W*H pixels in BMP order.
//   Output pixel (j,k) needs the stream pixel
//       want = row_base + (k * W) / DST_W
//       row_base = floor(j*H/DST_H) * W
//   `want` is monotone, so the scaler walks the stream:
//       while (ptr <= want) begin
//           consume one source pixel (ready=1, held=pixel, ptr++)
//           if (ptr <= want) ready = 0     // WAIT slot, emits nothing
//       end
//       emit held
//
//   BOTH AXES STEP IRREGULARLY, BY MORE THAN ONE
//       horizontal : floor((k+1)W/640) - floor(kW/640)  reaches W/640
//       vertical   : floor((j+1)H/480) - floor(jH/480)  reaches H/480
//   Measured vertical steps: H=600 -> [1,1,1,2,...], H=1080 -> [2,2,2,3,...]
//
//-------------------------------------------------------------------
// WHY THIS VERSION EXISTS  (timing)
//-------------------------------------------------------------------
//   The locked version advanced the row boundary with a 9-deep cascade of
//   conditional subtractions.  Mapped to logic that is 33 levels deep
//   (22 adders) and measured at 39.95 ns against a 10 ns budget:
//
//       row_acc_reg[1] -> 9-deep cascade -> vsum * w_eff -> row_base_reg
//       Slack -30.067 ns, Logic Level 33 (ADDER=22 MULT18=1)
//
//   No arrangement of pipeline registers fixes that, because the
//   recurrence is closed inside one clock:
//       row_acc  <- f(row_acc)                    and
//       row_base <- row_base + g(row_acc)
//   Registers only relocate a loop; they cannot shorten a 33-level chain
//   that must both start and end on a register.
//
//   So the arithmetic was replaced rather than re-timed.  Writing
//       h_eff = hq * DST_H + hr              (hq, hr constant per frame)
//   the vertical recurrence
//       acc' = (acc + h_eff) mod DST_H ,  step = (acc + h_eff) div DST_H
//   becomes
//       acc' = (acc + hr) mod DST_H ,     step = hq + carry
//       carry = ((acc + hr) >= DST_H)
//   which is ONE adder and ONE conditional subtractor, not nine.  For
//   H=1080/DST_H=480 that is hq=2, hr=120 giving 2,2,2,3,2,2,2,3 - exactly
//   what the cascade produced - and for H=600/480 it is hq=1, hr=120
//   giving 1,1,1,2.
//
//   The remainder then advances ONCE PER ROW, gated by the row boundary, and
//   the whole chain is four registers latched on that boundary:
//
//       boundary k :  vrem_q  == rem_k      (rem_0 = 0)
//                     sum_n   == rem_k + hr         (combinational)
//                     carry_n == sum_n >= DST_H     (combinational)
//                     rem_{k+1} = carry_n ? sum_n - DST_H : sum_n
//                     step_k    = hq + carry_n
//                     row_inc_lat = step_k * w_eff
//                     row_base += row_inc_lat
//
//   carry_n is the carry of rem_{k+1} + hr, i.e. c_{k+1}, and step_k is
//   hq + c_{k+1} - the step row_base advances by at boundary k+1.  Both
//   destinations are registers, so the extra logic level is free.
//
//   THE FOUR MISTAKES THAT COST SEVERAL ATTEMPTS, all of them indexing:
//     1. Deriving the step and the remainder in the SAME cycle as the
//        boundary that consumes them.  A register written on the boundary
//        cycle still shows its OLD value to that cycle's reader, so the
//        increment was always one row late and every padding step (the 2 in
//        H=600's 1,1,1,2) landed a row late: row_base read 3200 where it had
//        to read 4000.
//     2. Letting the step free-run once per clock.  It then changes 640
//        times per row and cannot be sampled at a boundary at all.
//     3. Accumulating the step products instead of deriving the step, which
//        never sums to exactly one row of steps.
//     4. Reading the step through a REGISTERED carry.  That delays it by a
//        whole row; taking it from the successor carry is what finally
//        aligned it.
//
//   The only closed loops are now short:
//       vrem_q -> (+hr) -> sum_q -> (-DST_H) -> vrem_q     (one adder)
//       row_base -> (+row_inc_lat) -> row_base             (one adder)
//
//   The released 9-deep cascade measured 33 logic levels, 22 adders and
//   39.951 ns against a 10 ns budget.  This structure removes the cascade
//   entirely rather than trying to retime it.
//
// BYPASS
//   If W < DST_W or H < DST_H the source passes through unchanged, one
//   output per input, and nothing is emitted after the input stops.
//===================================================================
`timescale 1ns / 1ps

module img_scaler #(
  parameter BOUNDED_WIDTH = 0,  //production headers accept width<=4096
  parameter [15:0] DST_W = 16'd640,
  parameter [15:0] DST_H = 16'd480
) (
  input wire clk,
  input wire rst,

  input wire [15:0] src_w,
  input wire [15:0] src_h,

  input  wire        src_valid,
  input  wire [23:0] src_pixel,
  input  wire        src_frame_start,
  output wire        ready,

  output reg         dst_valid,
  output reg  [23:0] dst_pixel,
  output reg         dst_sof,
  output reg         dst_eof,
  output reg         dst_row_start,
  output wire        dst_bypass
);

  wire [15:0] w_eff = (src_w == 16'd0) ? 16'd1 : src_w;
  // [Design note 时序]把 h_eff 的"取 0 保护"寄存一拍再送进除法。
  //   原来 src_h -> (==0?1:) -> /DST_H -> hq_r 是一条链，实测是 sd_card_clk
  //   域的第 1 名违规路径（-0.019ns，起于 bmp_read/height_reg）。
  //   src_h 每帧只变一次、很稳，寄存一拍只是让商晚一个周期算出，无害。
  reg  [15:0] h_eff_r;
  always @(posedge clk or posedge rst) begin
    if (rst) h_eff_r <= 16'd1;
    else h_eff_r <= (src_h == 16'd0) ? 16'd1 : src_h;
  end
  wire [15:0] h_eff = (src_h == 16'd0) ? 16'd1 : src_h;

  // Production metadata settles during the header before pixels.
  // Its existing quotient/product pipeline already requires that settle
  // interval. Register the two independent mode predicates as well so
  // BMP fast-row classification does not reach all pixel counter enables.
  wire downscale_ok;
  generate
    if (BOUNDED_WIDTH) begin : g_registered_mode
      reg width_ok_q, height_ok_q;
      always @(posedge clk) begin
        width_ok_q  <= w_eff >= DST_W;
        height_ok_q <= h_eff >= DST_H;
      end
      assign downscale_ok = width_ok_q && height_ok_q;
    end else begin : g_legacy_mode
      assign downscale_ok = (w_eff >= DST_W) && (h_eff >= DST_H);
    end
  endgenerate
  wire bypass = ~downscale_ok;
  assign dst_bypass = bypass;

  // ------------------------------------------------------------------
  // h_eff = hq * DST_H + hr, REGISTERED.
  //   DST_H is a parameter, so both operators fold to constant arithmetic,
  //   but the result still lands on the multiplier's input.  Left
  //   combinational it becomes the critical path by itself: the report
  //   showed 17 logic levels, 2 MULT18s and -15.624 ns on
  //       bmp_read/height_reg -> hq -> step_n * w_eff
  //   because src_h comes straight from a bmp_read header register.  src_h
  //   is frame-stable, so one register stage removes that whole path from
  //   the per-pixel timing without changing a single result.
  //
  //   This also replaces a hand-rolled search loop that returned the WRONG
  //   quotient: it scanned multiples from 16*DST_H downwards, but 16*DST_H
  //   = 7680 overflows the 16-bit comparison width, and the loop kept going
  //   after finding the answer, so the last comparison won.  For h_eff=1080
  //   it returned hq=1, hr=600 instead of hq=2, hr=120, which is why H=1080
  //   advanced by a constant 2 rows per row and came out 1920 short.
  //   Plain `/` and `%` by a parameter cannot make that mistake.
  // ------------------------------------------------------------------
  reg [ 4:0] hq_r;
  reg [16:0] hr_r;

  // hq and hr are frame-stable, so they are registered; the divide then
  // never runs combinationally from bmp_read's header registers.  hr is
  // derived from the REGISTERED hq (same always block, so hq_r is the value
  // from the previous clock - which is exactly the settled quotient),
  // because hq*DST_H is a constant multiply and needs no second divide.
  // Writing hr_r <= h_eff - ((h_eff / DST_H) * DST_H) instead leaves the
  // divide in the path: 13 levels, 17.775 ns, -7.891 ns.
  // hr needs the product hq_r*DST_H, and leaving that multiply in hr's own
  // path was still too long after routing.  Worse, feeding the multiply
  // straight from the divide (hr_r -> mult) reopened it again.
  //
  // So the horizontal/vertical pairs are both built as a strict register
  // chain, one arithmetic operation per stage:
  //     hq_r     <= h_eff / DST_H          (divide,   stage 1)
  //     hq_dst_q <= hq_r * DST_H           (multiply, stage 1)
  //     hr_r     <= h_eff - hq_dst_q       (subtract, stage 2)
  // Every multiply and every divide in this design ends in a register whose
  // output is only SUBTRACTED, COMPARED or ADDED.  hq/hr/wq/wr are
  // frame-stable, so the extra pipeline depth costs nothing: three clocks
  // instead of one still settles thousands of cycles before the first row
  // boundary, and src_w/src_h are already held stable per frame by bmp_read.
  // For 480 = 32*15, x=h>>5 and x=256*a+16*b+c.
  // x/15 = 17*a+b+(a+b+c)/15. The digit sum is at most 37,
  // so two small comparisons replace the long constant divider.
  // hq remains five bits, exactly preserving the original truncation.
  generate
    if (DST_H == 480) begin : g_div480
      reg [5:0] digit_sum;
      reg [4:0] quotient_base;
      always @(posedge clk) begin
        digit_sum <= {3'd0, h_eff_r[15:13]} + {2'd0, h_eff_r[12:9]} + {2'd0, h_eff_r[8:5]};
        quotient_base <= {h_eff_r[13], 4'd0} + {2'd0, h_eff_r[15:13]} + {1'b0, h_eff_r[12:9]};
        hq_r <= quotient_base + ((digit_sum >= 30) ? 5'd2 : (digit_sum >= 15) ? 5'd1 : 5'd0);
      end
    end else begin : g_div_other
      always @(posedge clk) hq_r <= h_eff_r / DST_H;
    end
  endgenerate
  reg [31:0] hq_dst_q;
  always @(posedge clk) begin

    hq_dst_q <= hq_r * DST_H;
    hr_r     <= {1'b0, h_eff_r} - hq_dst_q[16:0];
  end

  wire [ 4:0] hq = hq_r;
  wire [16:0] hr = hr_r;

  // ------------------------------------------------------------------
  // state
  // ------------------------------------------------------------------
  reg  [ 9:0] out_col;
  reg  [15:0] out_row;
  // Accepted production dimensions are <=4096 per axis. One-past-end
  // is2^24, so25bits retain it and the final row lookahead without wrap.
  // The unbounded reusable scaler keeps its original32bit arithmetic.
  localparam ADDR_W = BOUNDED_WIDTH ? 25 : 32;
  reg  [ADDR_W-1:0] ptr;
  reg  [      23:0] held;
  reg               held_valid;

  reg  [ADDR_W-1:0] row_base;  // floor(j*H/DST_H) * W, maintained incrementally
  reg  [      16:0] row_acc;  // vertical remainder for the row being emitted

  // ---- vertical pipeline -------------------------------------------------
  //   h_eff = hq*DST_H + hr, so with rem < DST_H:
  //       rem'  = (rem + hr) mod DST_H
  //       carry = (rem + hr >= DST_H)      (0 or 1)
  //       step  = hq + carry               (1 adder, not a 9-deep cascade)
  //
  //   Indexing (this is the part that took several attempts):
  //       step_j = floor((j+1)H/DST_H) - floor(jH/DST_H)
  //       rem_{j+1} = (rem_j + h_eff) mod DST_H,  rem_0 = 0
  //       stepping rem_j -> rem_{j+1} needs carry_j
  //   so step_j is derived from the carry of the PREVIOUS remainder.  That
  //   means one register stage between the sum and the step:
  //
  //       sum_q  <= vrem_q + hr        (registered adder output)
  //       vrem_q  <= reduced sum_q     (next remainder)
  //       carry_q<= (sum_q >= DST_H)
  //       vstep_q<= hq + carry_q      (registered step)
  //       row_inc<= vstep_q * w_eff   (registered product)
  //
  //   At boundary k the row advance row_inc must be step_{k+1} * w_eff.
  //   Deriving the step combinationally in the same cycle as the boundary
  //   that consumes it leaves it one clock late: every padding step (the 2
  //   in H=600's 1,1,1,2) then lands a row late and row_base reads 3200
  //   where it has to read 4000.
  reg  [      16:0] vrem_q;  // remainder  (name kept: the probe traces it)
  reg  [      16:0] sum_q;  // vrem_q + hr, staged one clock
  reg               carry_q;  // sum_q >= DST_H, staged one clock
  reg  [       3:0] vstep_q;  // step, exposed for the probe
  reg  [      31:0] row_inc_lat;  // step * w_eff, LATCHED at the boundary so the
                                  // next boundary's row_base add reads it from a
                                  // register that was written a whole row earlier

  // sum_q is the STAGED remainder sum.  The chain advances only on a row
  // boundary, so for the whole of row k+1:
  //     vrem_q  == rem_{k+1}
  //     sum_q   == rem_{k+1} + hr
  //     carry_q == (rem_{k+1} + hr >= DST_H) == c_{k+1}
  // which is exactly the carry step_{k+1} needs.  Reading the carry
  // combinationally out of sum_q in the boundary cycle instead yields c_k
  // (sum_q still describes the row that is ending) and row_base then lands
  // on 0/3200 where it has to be 800/4000.
  //
  //   The chain MUST be gated.  Free-running it advances 640 times per row,
  //   so a single register of carry cannot hold the right phase - that is
  //   why the value is only ever correct when the row length happens to
  //   match the step-sequence period.
  // sum_q must be vrem_q + hr FOR THE SAME ROW.  Loading it with the
  // successor sum (rem_n + hr) instead puts it one row ahead of vrem_q, the
  // carry is then taken from the wrong row, and vrem_q fails to wrap: it
  // grows 120,240,360,480,600,... past the modulus, row_base advances by a
  // constant step for ever, and H=1080 comes out 1920 short at row 4.
  //
  // ------------------------------------------------------------------
  // 2026-10-20 TIMING: 17-bit adder + 17-bit compare -> 10 bits + one LUT5.
  //
  //   vrem_q < DST_H and hr < DST_H, so sum_n < 2*DST_H = 960 and ten bits
  //   are enough.  The 17-bit adder followed by a 17-bit subtractor-compare
  //   cost six adder levels and were the HEAD of the worst path in the whole
  //   design (-1.110 ns, ADDER=6 MULT18=1):
  //       vrem_q -> sum_n -> carry_n -> step_n -> mult0.a  (10.66 ns)
  //
  //   DST_H = 480 = 10'b01_1110_0000, and for sum < 1024
  //       sum >= 480  <=>  sum[9] | (sum[8] & sum[7] & sum[6] & sum[5])
  //   because [480, 511] is exactly the set of ten-bit values with [8:5]
  //   all set.  So the compare is ONE LUT5 off the adder, not a five-level
  //   carry chain.  Bit-exact, not an approximation.
  // ------------------------------------------------------------------
  wire [       9:0] sum_n = {1'b0, vrem_q[8:0]} + {1'b0, hr[8:0]};  // <= 958
  wire              carry_n = sum_n[9] | (sum_n[8] & sum_n[7] & sum_n[6] & sum_n[5]);
  wire [       9:0] rem_n = carry_n ? (sum_n - DST_H[9:0]) : sum_n;

  //   The step comes from the successor carry, which is available
  //   combinationally from vrem_q.  Routing it through a registered carry
  //   delays the step by a whole row: at the row-3 boundary step_n then
  //   still reads 1 where it must read 2, and row_base lands on 3200
  //   instead of 4000.  Both destinations are registers, so the extra logic
  //   level is free.
  wire [       4:0] step_nw = hq + {4'd0, carry_n};
  wire [       3:0] step_n = (step_nw > 5'd15) ? 4'd15 : step_nw[3:0];

  // ------------------------------------------------------------------
  // 2026-10-20 TIMING: the boundary multiply is now a two-way select.
  //
  //   step_n = hq + carry_n, and hq/w_eff are frame-stable, so
  //       step_n * w_eff  is  hq*w_eff  or  (hq+1)*w_eff
  //   - only TWO values for a whole frame.  Both are built here, off the
  //   per-pixel path, and the boundary cycle just picks one.  That takes
  //   the MULT18 (3.56 ns) and the step adder out of the path that ran
  //   vrem_q -> sum_n -> carry_n -> step_n -> mult -> row_inc_lat.
  //
  //   index 0 = carry_n 0 -> clamp(hq)     * w_eff
  //   index 1 = carry_n 1 -> clamp(hq + 1) * w_eff
  //   The clamp at 15 is the same clamp step_n applies, so index 1 is
  //   row_inc0 + w_eff only while hq < 15; at hq == 15 both are 15*w_eff.
  //   hq <= 8 for any image up to 4096 lines, so this never bites; it is
  //   spelled out anyway so the two forms stay bit-identical.
  // ------------------------------------------------------------------
  wire [       3:0] hq_c = (hq_r > 5'd15) ? 4'd15 : hq_r[3:0];
  wire              hq_more = (hq_r < 5'd15);
  reg [31:0] row_inc0_q, row_inc1_q;
  always @(posedge clk) begin
    row_inc0_q <= {28'd0, hq_c} * w_eff;
    // +1 row is a single add of the (stable) row width; using the
    // registered product from the previous clock keeps the multiply out
    // of this path as well.
    row_inc1_q <= row_inc0_q + (hq_more ? {16'd0, w_eff} : 32'd0);
  end

  // ------------------------------------------------------------------
  // Column path: col_off(k) = floor(k * w_eff / DST_W), INCREMENTAL.
  //
  //   This is the SAME problem as the vertical axis.  col_off is a floor of
  //   a linear function, so its difference sequence has a bounded step and
  //   can be advanced instead of recomputed.  With
  //       w_eff = wq * DST_W + wr          (wq, wr constant per frame)
  //   the recurrence is
  //       cstep_k = wq + (crem_k + wr >= DST_W)
  //       crem_{k+1} = (crem_k + wr) mod DST_W        crem_0 = 0
  //       col_off_{k+1} = col_off_k + cstep_k         col_off_0 = 0
  //   verified EXACT for every width 640..4096 (max step 7, max intermediate
  //   1278 -> 11 bits).
  //
  //   So the per-column path is an adder, a comparator and a small mux - no
  //   multiplier and no divide.  That removes the 17.075 ns path entirely:
  //   the multiplier+divider were the whole of it.
  //
  //   col_off and crem only change when out_col advances, and the row wrap
  //   resets col_off to col_off(0) = 0.  The +1-adder form used in the two
  //   failed attempts is gone: registering it put col_off one column out of
  //   phase and sheared the whole frame by a column.
  // ------------------------------------------------------------------
  reg [15:0] w_eff_q;
  always @(posedge clk) w_eff_q <= w_eff;

  reg [3:0] wq_r;  // w_eff / DST_W,  registered
  localparam WR_W = (BOUNDED_WIDTH && DST_W == 640) ? 10 : 16;
  reg [WR_W-1:0] wr_r;  // w_eff % DST_W,  registered

  // wr must be derived from the REGISTERED wq, not from a second `/ DST_W`.
  //   Writing `wr_r <= w_eff_q - ((w_eff_q / DST_W) * DST_W)` puts the divide
  //   in wr's own path, and after routing that became the worst path in the
  //   whole design: w_eff_q -> divide -> subtract -> wr_r, 10.845 ns, 7 levels.
  //   hq/hr already did this the right way; this is the same trick applied to
  //   the horizontal pair.  wq*DST_W is a constant multiply.
  always @(posedge clk) begin
    wq_r <= w_eff_q / DST_W;
    wr_r <= w_eff_q - (wq_r * DST_W);
  end

  reg [21:0] col_off;
  reg [WR_W-1:0] crem_q;

  wire crem_cy;
  wire [3:0] cstep;
  wire [WR_W-1:0] crem_nxt;
  generate
    if (BOUNDED_WIDTH && DST_W == 640) begin : g_bounded_column
      // wr is frame-stable and lies in0..639 for every accepted header.
      // Compare against640-wr directly: no recurrence adder precedes the
      // carry decision. Prepare both possible quotient steps in advance.
      reg [9:0] threshold_q;
      reg [3:0] quotient_plus_one_q;
      always @(posedge clk) begin
        threshold_q <= 10'd640 - wr_r;
        quotient_plus_one_q <= wq_r + 1'b1;
      end
      assign crem_cy = crem_q >= threshold_q;
      assign cstep = crem_cy ? quotient_plus_one_q : wq_r;
      assign crem_nxt = crem_cy ? (crem_q - threshold_q) : (crem_q + wr_r);
    end else begin : g_legacy_column
      wire [16:0] crem_sum = {1'b0, crem_q} + {1'b0, wr_r};
      assign crem_cy = crem_sum >= DST_W;
      assign cstep = wq_r + {3'd0, crem_cy};
      assign crem_nxt = crem_cy ? (crem_sum[15:0] - DST_W) : crem_sum[15:0];
    end
  endgenerate

  wire last_col = (out_col == 10'd639);
  wire [ADDR_W-1:0] want;
  // In the accepted <=4096-wide image domain, col_off never wraps
  // during a frame. Carry the same address recurrence in a register:
  // column advance adds cstep; row wrap selects the next row base.
  // This separates the address addition from ptr>=want comparison.
  generate
    if (BOUNDED_WIDTH) begin : g_registered_want
      reg [ADDR_W-1:0] want_q;
      always @(posedge clk) begin
        if (rst || src_frame_start) want_q <= 0;
        else if (!bypass && out_row < DST_H && held_valid) begin
          if (last_col) want_q <= row_base + row_inc_lat;
          else want_q <= want_q + {28'd0, cstep};
        end
      end
      assign want = want_q;
    end else begin : g_legacy_want
      assign want = row_base + {10'd0, col_off};
    end
  endgenerate
  // For unsigned 32-bit values, ptr+1>want iff ptr>=want,
  // except wrap at UINT32_MAX. Preserve that corner explicitly.
  wire final_one = (ptr >= want) && (ptr != 32'hffffffff);

  wire last_row = (out_row + 16'd1 >= DST_H);
  wire frame_end = last_col && last_row;
  // a row boundary is the single cycle that emits column 639
  wire boundary = held_valid & last_col;

  // Advance the mapping exactly when out_col advances, which is whenever an
  // emit happens.  The ROW WRAP resets it to column 0 instead of advancing:
  // without that, col_off carries 798 straight into the next row's column 0
  // and every row after the first is shifted by a whole column.
  wire col_adv = held_valid & ~last_col;

  always @(posedge clk) begin
    if (rst || src_frame_start || boundary) begin
      col_off <= 22'd0;  // col_off(0)
      crem_q  <= 16'd0;  // crem_0
    end else if (col_adv) begin
      col_off <= col_off + {18'd0, cstep};
      crem_q  <= crem_nxt;
    end
  end

  // The cycle BEFORE a boundary.  row_base is written on the boundary cycle
  // and reads row_inc_lat there, so row_inc_lat has to be loaded one cycle
  // EARLIER - a register written in the same cycle still shows its old value
  // to that read, which is why row_base sat at 0.
  wire boundary_d = (out_col == 10'd638) & held_valid;

  assign ready = bypass | (~held_valid);

  // ------------------------------------------------------------------
  // bypass path
  // ------------------------------------------------------------------
  reg        bp_valid;
  reg [23:0] bp_pixel;
  always @(posedge clk) begin
    bp_valid <= bypass & src_valid;
    bp_pixel <= src_pixel;
  end
  wire last_col_bypass = (out_col + 10'd1 >= w_eff[9:0]);

  // ------------------------------------------------------------------
  // main
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      out_col       <= 10'd0;
      out_row       <= 16'd0;
      ptr           <= 32'd0;
      held          <= 24'd0;
      held_valid    <= 1'b0;
      row_base      <= 32'd0;
      row_acc       <= 17'd0;
      vrem_q        <= 17'd0;
      sum_q         <= 17'd0;
      carry_q       <= 1'b0;
      vstep_q       <= 4'd0;
      row_inc_lat   <= 32'd0;
      dst_valid     <= 1'b0;
      dst_pixel     <= 24'd0;
      dst_sof       <= 1'b0;
      dst_eof       <= 1'b0;
      dst_row_start <= 1'b0;
    end else begin
      dst_valid     <= 1'b0;
      dst_sof       <= 1'b0;
      dst_eof       <= 1'b0;
      dst_row_start <= 1'b0;

      // ------------------------------------------------------------------
      // Vertical pipeline, all four registers latched on the boundary.
      //
      //   The remainder only advances once per row, so the recurrence is
      //   evaluated once per row and the arithmetic has DST_W clocks of
      //   slack.  carry_q is latched from sum_n - the SUCCESSOR - which
      //   is what puts it one row ahead of vrem_q and makes it c_{k+1}
      //   at boundary k, the carry step_{k+1} needs.  Latching it from
      //   the pre-edge sum_q instead yields c_k and every padding step
      //   (the 2 in H=600's 1,1,1,2) lands a row late: row_base reads
      //   3200 where it has to read 4000.
      // ------------------------------------------------------------------
      if (src_frame_start) begin
        vrem_q      <= 17'd0;
        sum_q       <= {1'b0, hr};
        carry_q     <= 1'b0;
        vstep_q     <= 4'd0;
        row_inc_lat <= 32'd0;
      end else if (boundary) begin
        vrem_q  <= {7'd0, rem_n};
        sum_q   <= {7'd0, sum_n};  // = vrem_q + hr, same row
        carry_q <= carry_n;  // the SUCCESSOR carry
        vstep_q <= step_n;
      end
      // the increment is latched one cycle EARLIER than the boundary
      // that consumes it: row_base reads row_inc_lat on the boundary
      // cycle, and a register written in that same cycle still shows its
      // old value to that read.
      // (2026-10-20) select between the two precomputed products instead
      // of multiplying step_n by w_eff here.
      if (boundary_d) row_inc_lat <= carry_n ? row_inc1_q : row_inc0_q;

      if (src_frame_start) begin
        out_col    <= 10'd0;
        out_row    <= 16'd0;
        ptr        <= 32'd0;
        held_valid <= 1'b0;
        row_base   <= 32'd0;
        row_acc    <= 17'd0;
      end else if (bypass) begin
        dst_valid     <= bp_valid;
        dst_pixel     <= bp_pixel;
        dst_row_start <= bp_valid && (out_col == 10'd0);
        dst_sof       <= bp_valid && (out_col == 10'd0) && (out_row == 16'd0);
        if (bp_valid) begin
          if (last_col_bypass) begin
            out_col <= 10'd0;
            out_row <= out_row + 16'd1;
          end else begin
            out_col <= out_col + 10'd1;
          end
        end
      end else if (!held_valid) begin
        // ---- walk the stream to the wanted pixel -------------
        if (src_valid) begin
          held <= src_pixel;
          ptr  <= ptr + 32'd1;
          if (final_one) held_valid <= 1'b1;
        end
      end else if (out_row < DST_H) begin
        // ---- emit -------------------------------------------
        dst_valid     <= 1'b1;
        dst_pixel     <= held;
        dst_row_start <= (out_col == 10'd0);
        dst_sof       <= (out_col == 10'd0) && (out_row == 16'd0);
        held_valid    <= 1'b0;
        out_col       <= last_col ? 10'd0 : (out_col + 10'd1);

        if (last_col) begin
          // boundary: the step and the increment were both latched
          // at the PREVIOUS boundary, so this is one 32-bit add
          out_row  <= out_row + 16'd1;
          row_acc  <= {7'd0, rem_n};  // rem for the row starting now
          row_base <= row_base + row_inc_lat;
          if (frame_end) dst_eof <= 1'b1;
        end
      end
    end
  end

endmodule

// Preserve the proven 640x480 image path; expand its output to 800x600.
// Nearest neighbour: output(x,y) = input(floor(4*x/5), floor(4*y/5)).
// The input cannot stop a sector in flight. Reserve 192 FIFO entries when
// high is asserted: more than 171 RGB pixels/sector plus pipeline latency.
module image_expand_5_4 (
  input wire clk,
  input wire rst,
  input wire frame_start,
  input wire in_valid,
  input wire [23:0] in_pixel,
  output reg high,
  output reg overflow,
  input wire out_blocked,
  output reg out_valid,
  output reg [23:0] out_pixel
);
  reg [23:0] fifo[0:255];
  reg [7:0] wp, rp;
  reg [8:0] count;
  reg [23:0] q;
  reg qvalid;
  reg [2:0] state;
  localparam LIVE = 0, DUP = 1, FETCH = 2, REPLAY = 3, REPDUP = 4, DONE = 5;
  reg [9:0] x, y, rx;
  reg [23:0] held;
  reg [23:0] linebuf[0:639];
  reg [23:0] lineq;
  wire take = (state == LIVE) && qvalid && !out_blocked;
  wire fetch_fifo = (!qvalid || take) && (count != 0);
  wire push = in_valid && (count != 256);
  // A sector already in flight can add at most 171 RGB pixels. Register
  // the 64-entry threshold to break count -> QOI ready -> push -> count.
  // One extra accepted pixel leaves >=191 free slots, still above 171.
  always @(posedge clk) begin
    if (rst || frame_start) high <= 0;
    else high <= (count >= 64);
  end

  // Synchronous memory reads infer block RAM. No RAM content reset needed.
  always @(posedge clk) begin
    if (push) fifo[wp] <= in_pixel;
    if (fetch_fifo) q <= fifo[rp];
    if (take) linebuf[x] <= q;
    if (state == FETCH) lineq <= linebuf[rx];
  end
  always @(posedge clk) begin
    if (rst || frame_start) begin
      wp <= 0;
      rp <= 0;
      count <= 0;
      qvalid <= 0;
      overflow <= 0;
    end else begin
      if (in_valid && !push) overflow <= 1;
      if (push) wp <= wp + 1'b1;
      if (fetch_fifo) rp <= rp + 1'b1;
      case ({
        push, fetch_fifo
      })
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: ;
      endcase
      if (fetch_fifo) qvalid <= 1;
      else if (take) qvalid <= 0;
    end
  end
  always @(posedge clk) begin
    if (rst || frame_start) begin
      state <= LIVE;
      x <= 0;
      y <= 0;
      rx <= 0;
      held <= 0;
      out_valid <= 0;
      out_pixel <= 0;
    end else begin
      out_valid <= 0;
      case (state)
        LIVE:
        if (take) begin
          out_valid <= 1;
          out_pixel <= q;
          held <= q;
          if (x == 639) begin
            x <= 0;
            if (y[1:0] == 0) begin
              rx <= 0;
              state <= FETCH;
            end else if (y == 479) state <= DONE;
            else y <= y + 1'b1;
          end else begin
            x <= x + 1'b1;
            if (x[1:0] == 0) state <= DUP;
          end
        end
        DUP:
        if (!out_blocked) begin
          out_valid <= 1;
          out_pixel <= held;
          state <= LIVE;
        end
        FETCH: state <= REPLAY;
        REPLAY:
        if (!out_blocked) begin
          out_valid <= 1;
          out_pixel <= lineq;
          if (rx[1:0] == 0) state <= REPDUP;
          else if (rx == 639) begin
            y <= y + 1'b1;
            state <= LIVE;
          end else begin
            rx <= rx + 1'b1;
            state <= FETCH;
          end
        end
        REPDUP:
        if (!out_blocked) begin
          out_valid <= 1;
          out_pixel <= lineq;
          rx <= rx + 1'b1;
          state <= FETCH;
        end
        DONE: ;
        default: state <= DONE;
      endcase
    end
  end
endmodule

// Aspect-preserving image adapter. One scaled scanline, no frame buffer.
// Source dimensions are stable before the first pixel. The stream height may
// differ from aspect_h when the BMP reader skips rows using its fast path.
// Nearest-neighbour sampling preserves source detail without inventing texture.
// Input high-water leaves 256 words for an indivisible SD sector and pipelines.
module image_fit_720p #(
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
