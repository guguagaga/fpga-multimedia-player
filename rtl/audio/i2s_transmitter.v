// PCM 转 I²S 发送器，左右声道在帧边界锁存并按位发送。
// 数据在 BCLK 下降沿更新；sample_req 保持到 sample_valid 确认，防止请求脉冲丢失。
module i2s_transmitter #(
  parameter integer MAX_BUDGET_HOLD = 0
) (
  input wire clk,  // 12.288 MHz audio master clock
  input wire rst,  // active-high reset
  // 请求保持到 sample_valid 确认，接收端每个高电平请求窗口只处理一次。
  input wire mute,  // Keep I2S clocks running while outputting silence.
  input wire hold_budget_gap,  // Audio-domain AV budget wait; never ordinary SD starvation.
  input wire flush,  // Drop the old stream staging pair without resetting clocks.
  input wire sample_valid,  // 1 = 消费方(wav_sample_builder)已产出一个样本
  input wire [23:0] sample_left,  // left channel sample (24-bit signed)
  input wire [23:0] sample_right,  // right channel sample
  output reg sample_req,  // pulse: request next sample pair
  output reg i2s_bclk,
  output reg i2s_lrck,
  output reg i2s_dout,
  // 只读状态输出：请求保持状态和确认事件粘滞标志，不参与播放控制。
  output wire dbg_req_held,
  output reg dbg_ack_seen,
  output reg dbg_req_stall,  // 粘滞：请求曾举着 >2000 拍还没 ack（真停摆 ）
  // 比较相邻帧锁存样本，统计重复长度；静音本身也可能产生重复样本。
  output reg [1:0] dbg_rep_grade,  // 粘滞最大档：0=从不重复 1=2~3帧 2=4~15 3=≥16
  output reg dbg_rep_long,  // 曾连续 ≥16 帧锁到相同样本对 
  output reg [3:0] dbg_same_frames,  // 当前连续相同帧数（截 4 位 ）
  // 每 1024 帧统计样本变化次数，反映最近窗口中的输出活动。
  output reg  [1:0]  dbg_chg_grade,      // 活档：3=≈全变 2=多数变 1=少数变 0=几乎不变(冻住 )
  output reg [11:0] dbg_chg_cnt,  // 上一窗口"发生变化"的帧数（供人工核对 ）
  output reg dbg_chg_last,  // 最近一帧是否变化（非粘滞  静止时也能读)
  // 在相同窗口统计请求、确认数量和最长等待时间，便于区分供数与取用状态。
  output reg [1:0] dbg_vld_grade,  // 3=≈每帧 1 个 2=偏少 1=很少 0=供数停了
  output reg [1:0] dbg_req_grade,  // 同上，针对 sample_req
  output reg  [1:0]  dbg_held_grade,     // req_held 最长连续为高：0=<8拍 1=8~63 2=64~511 3=≥512
  output reg [11:0] dbg_vld_cnt,  // 上一窗口 sample_valid 计数（供人工核对 ）
  output reg [11:0] dbg_req_cnt,  // 上一窗口 sample_req 计数
  // 统计输入样本变化与帧边界锁存次数，分别观察输入活动和锁存节拍。
  output reg [1:0] dbg_in_chg_grade,  // 3=输入活跃 2/1=偏少 0=输入端冻住
  output reg [1:0] dbg_lat_grade,  // 3=锁存脉冲≈1024（每帧都锁 ） 0=几乎没锁 
  output reg [11:0] dbg_in_chg_cnt,  // 上一窗口输入变化次数（供人工核对 ）
  output reg [11:0] dbg_lat_cnt  // 上一窗口锁存脉冲次数 
);

  reg [5:0] bit_cnt;  // 0..63
  reg       req_held;  // 1 = 本帧请求还举着（等 sample_valid 才放 ）
  // 观测（只读 ）
  assign dbg_req_held = req_held;
  // 请求连续超过 2000 拍未确认时置等待告警。
  reg [11:0] hold_cnt;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      dbg_req_stall <= 1'b0;
      hold_cnt <= 12'd0;
    end else if (!req_held) hold_cnt <= 12'd0;
    else begin
      if (hold_cnt >= 12'd2000) dbg_req_stall <= 1'b1;
      else hold_cnt <= hold_cnt + 12'd1;
    end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) dbg_ack_seen <= 1'b0;
    else if (sample_valid) dbg_ack_seen <= 1'b1;
  end
  reg [63:0] shift_reg;
  reg [23:0] sample_left_reg;  // latched left sample
  reg [23:0] sample_right_reg;  // latched right sample

  reg [23:0] pending_left, pending_right;
  reg pair_ready;
  localparam integer HOLD_W = (MAX_BUDGET_HOLD < 2) ? 1 : $clog2(MAX_BUDGET_HOLD+1);
  reg [HOLD_W-1:0] budget_hold_count;
  reg complete_pair_seen;
  // PLL ratios differ slightly from the nominal48k/60Hz ratio. A bounded
  // zero-order hold avoids inserting a zero for a single sample while the
  // next displayed frame replenishes the AV budget. No PCM is consumed,
  // skipped or acknowledged by this path. Real underruns still become silence.
  wire can_hold_budget = (MAX_BUDGET_HOLD != 0) && hold_budget_gap &&
                         complete_pair_seen && (budget_hold_count < MAX_BUDGET_HOLD);
  wire [23:0] next_left = sample_valid ? sample_left : pending_left;
  wire [23:0] next_right = sample_valid ? sample_right : pending_right;
  wire next_pair_ready = sample_valid || pair_ready;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      i2s_bclk <= 0;
      i2s_lrck <= 0;
      i2s_dout <= 0;
      bit_cnt <= 0;
      shift_reg <= 0;
      sample_left_reg <= 0;
      sample_right_reg <= 0;
      req_held <= 0;
      sample_req <= 0;
      pending_left <= 0;
      pending_right <= 0;
      pair_ready <= 0;
      budget_hold_count <= 0;
      complete_pair_seen <= 0;
    end else begin
      i2s_bclk   <= ~i2s_bclk;
      sample_req <= req_held;
      if (!i2s_bclk && bit_cnt == 63 && i2s_lrck) req_held <= 1;
      // ACK must win over a simultaneous frame request. The low
      // request interval rearms the builder's exactly-once latch.
      if (sample_valid) begin
        req_held <= 0;
        pending_left <= sample_left;
        pending_right <= sample_right;
        pair_ready <= 1;
      end
      if (i2s_bclk) begin
        i2s_dout  <= shift_reg[63];
        shift_reg <= {shift_reg[62:0], 1'b0};
        if (bit_cnt == 63) begin
          bit_cnt <= 0;
          if (!i2s_lrck) begin
            i2s_lrck  <= 1;
            shift_reg <= {sample_right_reg, 40'd0};
          end else begin
            i2s_lrck <= 0;
            // The builder updates L and R on different clocks.
            // Only publish a pair after its sample_valid ACK.
            if (mute) begin
              budget_hold_count <= 0;
              complete_pair_seen <= 0;
              sample_left_reg <= 0;
              sample_right_reg <= 0;
              shift_reg <= 0;
            end else if (next_pair_ready) begin
              budget_hold_count <= 0;
              complete_pair_seen <= 1;
              sample_left_reg <= next_left;
              sample_right_reg <= next_right;
              shift_reg <= {next_left, 40'd0};
              pair_ready <= 0;
            end else if (can_hold_budget) begin
              budget_hold_count <= budget_hold_count + 1'b1;
              shift_reg <= {sample_left_reg, 40'd0};
            end else begin
              complete_pair_seen <= 0;
              budget_hold_count <= 0;
              // An underrun is silence, never a stale partial sample.
              sample_left_reg <= 0;
              sample_right_reg <= 0;
              shift_reg <= 0;
            end
          end
        end else bit_cnt <= bit_cnt + 1'b1;
      end
      if (flush) begin
        complete_pair_seen <= 0;
        budget_hold_count <= 0;
        pending_left <= 0;
        pending_right <= 0;
        pair_ready <= 0;
        req_held <= 0;
        sample_req <= 0;
      end
    end
  end

  // 只读统计：相邻输出样本相同的持续长度。
  reg [23:0] prev_lat_l, prev_lat_r;
  reg  [19:0] same_frames_c;
  wire        latch_now = (i2s_bclk == 1'b1) && (bit_cnt == 6'd63) && (i2s_lrck == 1'b1);
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      prev_lat_l <= 24'd0;
      prev_lat_r <= 24'd0;
      same_frames_c <= 20'd0;
      dbg_rep_grade <= 2'd0;
      dbg_rep_long <= 1'b0;
      dbg_same_frames <= 4'd0;
    end else begin
      if (latch_now) begin
        if ((sample_left == prev_lat_l) && (sample_right == prev_lat_r)) begin
          same_frames_c <= same_frames_c + 20'd1;
          if (same_frames_c >= 20'd15) begin
            dbg_rep_grade <= 2'd3;
            dbg_rep_long  <= 1'b1;  // 反复播同一帧 
          end else if (same_frames_c >= 20'd3) begin
            if (dbg_rep_grade < 2'd2) dbg_rep_grade <= 2'd2;
          end else begin
            if (dbg_rep_grade < 2'd1) dbg_rep_grade <= 2'd1;
          end
        end else same_frames_c <= 20'd0;
        prev_lat_l <= sample_left;
        prev_lat_r <= sample_right;
      end
      dbg_same_frames <= same_frames_c[3:0];
    end
  end

  // 以 1024 帧为窗口更新输出变化计数。
  localparam integer CHG_WIN = 1024;  // 窗口帧数（1024 帧 ≈ 21ms @48k  够快看清 ）
  reg [10:0] chg_win_f;  // 窗口内已计帧数
  reg [11:0] chg_win_c;  // 窗口内"发生变化"的帧数
  // 供数率与输出变化共用同一窗口边界。
  reg [11:0] sup_vld_c, sup_req_c;
  reg [15:0] held_run, held_max;
  // 输入变化及锁存脉冲计数。
  reg [11:0] in_chg_c, lat_c;
  reg [23:0] prev_in_l, prev_in_r;
  reg in_seen;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      chg_win_f <= 11'd0;
      chg_win_c <= 12'd0;
      sup_vld_c <= 12'd0;
      sup_req_c <= 12'd0;
      held_run <= 16'd0;
      held_max <= 16'd0;
      dbg_vld_grade <= 2'd0;
      dbg_req_grade <= 2'd0;
      dbg_held_grade <= 2'd0;
      dbg_vld_cnt <= 12'd0;
      dbg_req_cnt <= 12'd0;
      in_chg_c <= 12'd0;
      lat_c <= 12'd0;
      prev_in_l <= 24'd0;
      prev_in_r <= 24'd0;
      in_seen <= 1'b0;
      dbg_in_chg_grade <= 2'd0;
      dbg_lat_grade <= 2'd0;
      dbg_in_chg_cnt <= 12'd0;
      dbg_lat_cnt <= 12'd0;
      dbg_chg_grade <= 2'd0;
      dbg_chg_cnt <= 12'd0;
      dbg_chg_last <= 1'b0;
    end else begin
      // 请求和确认与本模块时钟同域，逐拍累计。
      if (sample_valid) sup_vld_c <= sup_vld_c + 12'd1;
      if (sample_req) sup_req_c <= sup_req_c + 12'd1;
      if (req_held) begin
        if (held_run < 16'hFFFF) held_run <= held_run + 16'd1;
        if ((held_run + 16'd1) > held_max) held_max <= held_run + 16'd1;
      end else held_run <= 16'd0;
      // 首个输入样本建立基准，随后逐拍比较变化。
      if (in_seen && ((sample_left !== prev_in_l) || (sample_right !== prev_in_r)))
        in_chg_c <= in_chg_c + 12'd1;
      in_seen   <= 1'b1;
      prev_in_l <= sample_left;
      prev_in_r <= sample_right;
      // 只在帧边界锁存事件中更新帧窗口。
      if (latch_now) begin
        if (lat_c < 12'hFFF)
          lat_c <= lat_c + 12'd1;  //  锁存脉冲计数（放在窗口块内 ）
        // 与上一帧比较（prev_lat_* 由 #fix24 的块维护  同拍更新前的值 ）
        if ((sample_left != prev_lat_l) || (sample_right != prev_lat_r)) dbg_chg_last <= 1'b1;
        else dbg_chg_last <= 1'b0;
        if ((sample_left != prev_lat_l) || (sample_right != prev_lat_r))
          chg_win_c <= chg_win_c + 12'd1;
        if (chg_win_f >= (CHG_WIN - 1)) begin
          // 窗口结束 ⇒ 出档并清零 （活计数：每个窗口都会更新  不粘滞 ）
          chg_win_f   <= 11'd0;
          dbg_chg_cnt <= chg_win_c;
          if (chg_win_c >= (CHG_WIN * 3 / 4)) dbg_chg_grade <= 2'd3;  // ≥768 ⇒ 正常 
          else if (chg_win_c >= (CHG_WIN / 2)) dbg_chg_grade <= 2'd2;
          else if (chg_win_c >= 12'd16) dbg_chg_grade <= 2'd1;
          else dbg_chg_grade <= 2'd0;  // 几乎不变 ⇒ 冻住 
          chg_win_c   <= 12'd0;
          // 窗口结束时发布统计并清空下一窗口的累计值。
          dbg_vld_cnt <= sup_vld_c;
          dbg_req_cnt <= sup_req_c;
          if (sup_vld_c >= (CHG_WIN * 3 / 4)) dbg_vld_grade <= 2'd3;
          else if (sup_vld_c >= (CHG_WIN / 2)) dbg_vld_grade <= 2'd2;
          else if (sup_vld_c >= 12'd16) dbg_vld_grade <= 2'd1;
          else dbg_vld_grade <= 2'd0;
          if (sup_req_c >= (CHG_WIN * 3 / 4)) dbg_req_grade <= 2'd3;
          else if (sup_req_c >= (CHG_WIN / 2)) dbg_req_grade <= 2'd2;
          else if (sup_req_c >= 12'd16) dbg_req_grade <= 2'd1;
          else dbg_req_grade <= 2'd0;
          if (held_max >= 16'd512) dbg_held_grade <= 2'd3;
          else if (held_max >= 16'd64) dbg_held_grade <= 2'd2;
          else if (held_max >= 16'd8) dbg_held_grade <= 2'd1;
          else dbg_held_grade <= 2'd0;
          // 发布输入变化和锁存事件统计。
          dbg_in_chg_cnt <= in_chg_c;
          dbg_lat_cnt <= lat_c;
          if (in_chg_c >= (CHG_WIN * 3 / 4)) dbg_in_chg_grade <= 2'd3;
          else if (in_chg_c >= (CHG_WIN / 2)) dbg_in_chg_grade <= 2'd2;
          else if (in_chg_c >= 12'd16) dbg_in_chg_grade <= 2'd1;
          else dbg_in_chg_grade <= 2'd0;  // 输入端冻住 
          if (lat_c >= (CHG_WIN * 3 / 4)) dbg_lat_grade <= 2'd3;  // 每帧都锁 
          else if (lat_c >= (CHG_WIN / 2)) dbg_lat_grade <= 2'd2;
          else if (lat_c >= 12'd16) dbg_lat_grade <= 2'd1;
          else dbg_lat_grade <= 2'd0;
          in_chg_c <= 12'd0;
          lat_c <= 12'd0;
          sup_vld_c <= 12'd0;
          sup_req_c <= 12'd0;
          held_max <= 16'd0;
        end else chg_win_f <= chg_win_f + 11'd1;
      end
    end  //  关闭 else 
  end

endmodule
