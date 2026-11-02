`timescale 1ns / 1ps
// Debounced active-low board buttons. The top assigns business functions:
// A/KEY2: tap = pause, double = auto-next toggle, hold = repeated seek.
// B/KEY4: tap = image slideshow toggle, hold = one next-track event.
// Taps are decided on release; long events never produce a release tap.
// Default @100MHz: 20ms debounce, 400ms hold, 100ms seek repeat, 300ms double.
module button_ctrl #(
  parameter [20:0] DEBOUNCE      = 21'd2_000_000,   // 20ms @100MHz
  parameter [25:0] LONG_PRESS    = 26'd40_000_000,  // 400ms: normal taps must not seek
  // B 键使用独立长按门限，区分短按轮播与长按切歌。
  parameter [25:0] LONG_PRESS_B  = 26'd40_000_000,  // 400ms
  parameter [23:0] REPEAT_PERIOD = 24'd10_000_000,  // 100ms 快进一步
  parameter [25:0] DBL_WINDOW    = 26'd30_000_000   // 300ms between releases
) (
  input  wire clk,
  input  wire rst_n,
  input  wire key_a,       // 低有效
  input  wire key_b,       // 低有效
  output reg  level_a,
  output reg  level_b,
  output reg  tap_a,       // 短按 A（1 拍）
  output reg  tap_b,       // 短按 B（1 拍）
  output reg  dbl_a,       // A 双击（1 拍）—— 用来切换"自动续播"，
                           //   避免和 key2 已有的"图片轮播开关"抢功能
  output reg  long_a,      // A 长按中（电平）
  output reg  long_b,      // B 长按中（电平）
  output reg  ff_tick,     // 快进一步（1 拍）
  // B 键首次到达长按门限时仅输出一拍事件，避免按住期间连续推进曲目。
  output reg  long_b_tick
);

  // ---------------- A 键消抖 ----------------
  reg [20:0] a_cnt;
  reg        a_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_cnt   <= 21'd0;
      level_a <= 1'b1;  // 松开 = 高
      a_d     <= 1'b1;
    end else begin
      a_d <= level_a;
      if (key_a == level_a) begin
        a_cnt <= 21'd0;
      end else begin
        a_cnt <= a_cnt + 21'd1;
        if (a_cnt >= DEBOUNCE) level_a <= key_a;
      end
    end
  end

  wire        a_press = ~level_a & a_d;  // 消抖后的按下沿（1 拍）
  wire        a_release = level_a & ~a_d;  // 消抖后的松手沿（1 拍）

  // ---------------- B 键消抖 ----------------
  reg  [20:0] b_cnt;
  reg         b_d;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_cnt   <= 21'd0;
      level_b <= 1'b1;
      b_d     <= 1'b1;
    end else begin
      b_d <= level_b;
      if (key_b == level_b) begin
        b_cnt <= 21'd0;
      end else begin
        b_cnt <= b_cnt + 21'd1;
        if (b_cnt >= DEBOUNCE) level_b <= key_b;
      end
    end
  end

  wire        b_press = ~level_b & b_d;
  wire        b_release = level_b & ~b_d;

  // ---------------- 长按 / 连发 ----------------
  reg  [25:0] a_hold;
  reg         a_long;  // A 长按已触发（松手清零）
  reg  [23:0] a_rep;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_hold <= 26'd0;
      a_long <= 1'b0;
      a_rep  <= 24'd0;
    end else if (level_a) begin
      // 松手：清长按与连发
      a_hold <= 26'd0;
      a_long <= 1'b0;
      a_rep  <= 24'd0;
    end else if (!a_long) begin
      if (a_hold >= LONG_PRESS) a_long <= 1'b1;
      else a_hold <= a_hold + 26'd1;
    end else begin
      if (a_rep >= REPEAT_PERIOD) a_rep <= 24'd0;
      else a_rep <= a_rep + 24'd1;
    end
  end

  reg [25:0] b_hold;  //  26 位计数覆盖 LONG_PRESS_B 长按门限
  reg b_long;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_hold <= 26'd0;
      b_long <= 1'b0;
    end else if (level_b) begin
      b_hold <= 26'd0;
      b_long <= 1'b0;
    end else if (!b_long) begin
      if (b_hold >= LONG_PRESS_B) b_long <= 1'b1;  //  B 键 400ms
      else b_hold <= b_hold + 26'd1;
    end
  end

  // ---------------- 双击检测（A 键） ----------------
  // 双击窗口内又来一次短按 -> dbl_a。
  // Both taps are emitted; a double toggles pause twice (net unchanged).
  // DBL_WINDOW is a parameter for both board use and short simulations.
  // （24 位最大 16,777,215，
  //   写 20_000_000 会被截断）
  reg [25:0] dbl_cnt;
  // dbl_cnt starts at0 and increments only while below DBL_WINDOW.
  // Predict the next count's terminal flag using equality, no add/cmp
  // cascade. Reset and all tap overrides update flag with the counter.
  reg        dbl_expired;
  reg        dbl_wait;  // 1 = 已收到第一次短按，正在等第二次
  reg        long_latch;  // 1 = 上一次操作是长按（直到下一次短按才清）

  // ---------------- 事件输出 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tap_a <= 1'b0;
      tap_b <= 1'b0;
      dbl_a <= 1'b0;
      long_a <= 1'b0;
      long_b <= 1'b0;
      ff_tick <= 1'b0;
      long_b_tick <= 1'b0;
      dbl_cnt <= 24'd0;
      dbl_expired <= (DBL_WINDOW == 0);
      dbl_wait <= 1'b0;
      long_latch <= 1'b0;
    end else begin
      tap_a <= 1'b0;
      tap_b <= 1'b0;
      dbl_a <= 1'b0;
      ff_tick <= 1'b0;
      long_b_tick <= 1'b0;

      // 双击窗口计时
      if (dbl_wait) begin
        if (dbl_expired) begin
          dbl_wait <= 1'b0;
          dbl_cnt <= 24'd0;
          dbl_expired <= (DBL_WINDOW == 0);
        end else begin
          dbl_cnt <= dbl_cnt + 24'd1;
          dbl_expired <= (dbl_cnt == DBL_WINDOW - 26'd1);
        end
      end

      // 短按 = 松手 + 期间没触发过长按
      if (a_release && !a_long) begin
        // 关键：tap 永远发出，绝不被双击逻辑吞掉 ——
        // "播放/暂停"是最高频操作，任何情况下都必须可靠。
        tap_a      <= 1'b1;
        long_latch <= 1'b0;  // 这次是短按，清掉长按痕迹
        if (dbl_wait && !long_latch) begin
          // 前一次也是短按且落在窗口内 -> 双击
          dbl_a    <= 1'b1;
          dbl_wait <= 1'b0;
          dbl_cnt  <= 24'd0;
          dbl_expired <= (DBL_WINDOW==0);
        end else if (!long_latch) begin
          // 第一次短按：开始等第二次
          dbl_wait <= 1'b1;
          dbl_cnt <= 24'd0;
          dbl_expired <= (DBL_WINDOW == 0);
        end else begin
          // 紧接在长按之后的那次短按：不参与双击判定
          dbl_wait <= 1'b0;
          dbl_cnt <= 24'd0;
          dbl_expired <= (DBL_WINDOW == 0);
        end
      end

      // 长按一旦触发，记下"上一次是长按"
      if (a_long) long_latch <= 1'b1;

      if (b_release && !b_long) tap_b <= 1'b1;

      // 长按状态指示
      long_a <= a_long;
      long_b <= b_long;

      // 快进：长按触发的那一拍 + 之后每个 REPEAT_PERIOD
      if (!level_a && !a_long && (a_hold == LONG_PRESS - 26'd1)) ff_tick <= 1'b1;
      if (!level_a && a_long && (a_rep >= REPEAT_PERIOD)) ff_tick <= 1'b1;

      // 在门限精确相等时输出一次长按事件，避免连续两拍触发。
      if (!level_b && !b_long && (b_hold == LONG_PRESS_B - 26'd1)) long_b_tick <= 1'b1;
    end
  end

endmodule
