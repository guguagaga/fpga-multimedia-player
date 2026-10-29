`timescale 1ns / 1ps
//===========================================================================
// key_long : one board button -> a qualified "tap" level + a "hold" pulse
//---------------------------------------------------------------------------
// WHY THIS MODULE EXISTS AT ALL
//   The board has four buttons and three are already overloaded:
//     KEY1 (B2) short = play/pause, long = fast-forward, double = auto-playback
//     KEY4 (C1) short = slideshow on/off, long = next track
//     KEY3 (B1) short = next image            <- no long-press function yet
//   KEY3 is therefore where video play/stop lives.
//
// WHY IT MUST NOT BE A NAIVE PULSE
//   The first version fed KEY3 straight into sd_card_bmp.key_next and used a
//   separate 1.2 s hold detector.  That deadlocked the feature on the board:
//   the first ~20 ms of the hold is indistinguishable from a normal tap, so
//   sd_card_bmp started loading the next image, and an image load keeps
//   img_loading high for load+fade = 0.3..5.3 s (I4 alone is 4.7 s to read).
//   The 1.2 s hold pulse then landed INSIDE that window and the "may I start
//   video?" condition was false, so the request was silently dropped --
//   i.e. holding KEY3 did nothing, and it did it every time.
//
// THE FIX: OWN THE GESTURE
//   This module decides tap-vs-hold FIRST and then tells the image path
//   "this was only a tap" by synthesising a short active-low pulse on tap_n.
//     * key down < HOLD_MS  -> on release, tap_n goes low for TAP_MS
//                              (sd_card_bmp's 20 ms debounce accepts it)
//     * key down >= HOLD_MS -> hold_pulse fires once, tap_n NEVER pulses
//   So a long press no longer starts an image load, img_loading stays 0, and
//   the video can take over immediately.
//
//   TAP_MS must be > sd_card_bmp's 20 ms debounce; 40 ms is comfortable and
//   still feels instant.
//===========================================================================
module key_long #(
  parameter integer CLK_FREQ_HZ = 100_000_000,
  parameter integer HOLD_MS     = 1200,
  parameter integer TAP_MS      = 40,
  // 按下短于这个宽度就当抖动，什么都不发。
  // 为什么必须要有：两级同步器只是把按钮同步过来，不会滤掉短脉冲；
  // 仿真里 2 个 100MHz 拍（20ns）按下就产生了一个 tap。真按钮抖动是 ms 级，
  // 15 ms 既盖住抖动、又远小于人手的"短按"（通常 50~300 ms）。
  parameter integer MIN_MS      = 15
) (
  input  wire clk,
  input  wire rst,
  input  wire key_n,       // board button: released = 1, pressed = 0
  output reg  hold_pulse,  // 1-cycle pulse when the hold threshold is met
  output reg  tap_n        // active-low TAP_MS pulse after a SHORT press
);
  localparam integer HOLD_CYC = (CLK_FREQ_HZ / 1000) * HOLD_MS;
  localparam integer TAP_CYC  = (CLK_FREQ_HZ / 1000) * TAP_MS;
  localparam integer MIN_CYC  = (CLK_FREQ_HZ / 1000) * MIN_MS;

  reg [ 1:0] ksync;  // two-flop synchroniser (button is async)
  reg [31:0] cnt;
  reg        fired;  // hold already fired for this press
  reg        down;  // key is currently down (seen after sync)
  localparam [31:0] HOLD_LIMIT = HOLD_CYC - 1, MIN_LIMIT = MIN_CYC;
  reg hold_due, min_due, tap_active;
  reg [31:0] tap_cnt;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      ksync      <= 2'b11;
      cnt        <= 32'd0;
      hold_due   <= (HOLD_LIMIT == 0);
      min_due    <= (MIN_LIMIT == 0);
      fired      <= 1'b0;
      down       <= 1'b0;
      tap_cnt    <= 32'd0;
      tap_active <= 0;
      hold_pulse <= 1'b0;
      tap_n      <= 1'b1;
    end else begin
      ksync      <= {ksync[0], key_n};
      hold_pulse <= 1'b0;

      // ---- synthetic tap pulse (active low) ----
      if (tap_active) begin
        tap_cnt <= tap_cnt - 32'd1;
        tap_active <= (tap_cnt != 1);
        tap_n <= 1'b0;
      end else begin
        tap_n <= 1'b1;
      end

      // ---- gesture classification ----
      if (ksync[1]) begin
        // released
        if (down && !fired && min_due) begin
          tap_cnt <= TAP_CYC;
          tap_active <= (TAP_CYC != 0);
        end  // short but real press -> emit tap
        cnt <= 32'd0;
        hold_due <= (HOLD_LIMIT == 0);
        min_due <= (MIN_LIMIT == 0);
        fired <= 1'b0;
        down <= 1'b0;
      end else begin
        // pressed
        down <= 1'b1;
        if (!fired) begin
          if (hold_due) begin
            cnt        <= 32'd0;
            hold_due   <= (HOLD_LIMIT == 0);
            min_due    <= (MIN_LIMIT == 0);
            fired      <= 1'b1;
            hold_pulse <= 1'b1;
          end else begin
            cnt <= cnt + 32'd1;
            hold_due <= cnt == (HOLD_LIMIT - 1'b1);
            min_due <= min_due || cnt == (MIN_LIMIT - 1'b1);
          end
        end
      end
    end
  end
endmodule
