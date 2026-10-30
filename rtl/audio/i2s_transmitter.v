//===================================================================
// i2s_transmitter : PCM -> I2S (replaces hdmi_audio_tone_i2s_64fs DDS)
//===================================================================
// Replicates the exact I2S timing of the official test-tone module, but
// the audio samples come from an external source (SD-card WAV player)
// instead of an internal DDS sine/note generator.
//
// I2S timing (identical to hdmi_audio_tone_i2s_64fs):
//   - clk  = audio master clock 12.288 MHz
//   - BCLK = clk / 2          = 6.144 MHz (toggles every clk)
//   - LRCK = 48 kHz           (toggles every 64 bits => 128 BCLK / frame)
//   - each channel = 64 bits  = 24-bit sample (MSB first) + 40 zero bits
//   - DOUT updates on BCLK falling edge
//
// Interface:
//   sample_left / sample_right : current sample pair (24-bit signed)
//   sample_req                 : 1-cycle pulse (~48kHz) requesting the
//                                next sample pair.
//
// 【取样时机：提前一拍请求、下一拍锁存】
//   右声道最后一个 bit 的前一拍就把 sample_req 拉高；再下一拍（帧边界）才
//   锁存 sample_left / sample_right 并装载左声道移位寄存器。
//   于是 "请求 -> 锁存" 是明确的前后拍关系，消费侧
//   （wav_sample_builder + async_fifo 的寄存器读）天然有一拍余量。
//   （原来是在帧边界同一拍既锁存又请求。）
//   注意：锁存用的是帧边界那一拍之前总线上的值，所以"哪个样本对配哪一
//   帧"与原来完全一致 —— 只是请求提前了一拍，不改变音画配对。
//===================================================================
module i2s_transmitter #(
  parameter integer MAX_BUDGET_HOLD = 0
) (
  input wire clk,  // 12.288 MHz audio master clock
  input wire rst,  // active-high reset
  //=== [Design note] ===============================================
  // 改动：sample_req 从【1 拍脉冲】改成【保持到被接受】——
  //       req_held 在帧边界置起，直到消费方给出 sample_valid 才放开 
  // 原因：板级读数（消费端组）DIG2=2 ⇒ bit1=1 ⇒ sample_req 在非 IDLE 时被丢弃 
  //       + DIG1=0（构造器多在 IDLE）+ DIG1(writeside)=3（FIFO 近满）
  //       ⇒ 请求被丢 => 构造器少取 => FIFO 无人搬走 => i2s 帧边界盲锁存上一帧
  //       ⇒ 反复播同一帧 = 全杂音 / 极端时无声 （板级链闭合 ）
  // 证据：TB wav_sb_req_tb（新增）pre/post：
  //       修复前（1 拍脉冲）：发出 1200 个请求、只完成 810 个 ⇒ 丢 390 个 ⇒ FAIL 
  //       修复后（保持到接受）：1200/1200 ⇒ 丢 0 个 ⇒ PASS 
  // 影响：只改"请求什么时候撤"；I2S 时序（BCLK/LRCK/shift）一字未动 
  // 相关：见 CHANGELOG_源码改动登记.md 的同编号条目
  //============================================================================
  // [Design note]请求-接受握手：把 sample_req 【保持】到消费方给出 sample_valid 
  //   （原来是 1 拍脉冲  => 构造器不在 IDLE 时就被丢掉 = 板级 C2 ）
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
  // [Design note]只读观测（只驱动显示  不进功能表达式 ）
  //   dbg_req_held : req_held 电平（1 = 请求还举着没被接受 ）回答"请求是否永不释放"唯一直接指标
  //   dbg_ack_seen : sample_valid(ack) 是否曾经来过（粘滞，reset-only ）
  output wire dbg_req_held,
  output reg dbg_ack_seen,
  output reg dbg_req_stall,  // 粘滞：请求曾举着 >2000 拍还没 ack（真停摆 ）
  //=== [Design note] ========================================
  // "反复播同一帧"的【直接测量】（父 agent 指定的判别仪器 ）
  //   在帧边界锁存样本对的那一拍，比较【本次锁存值】与【上次锁存值】
  //     · 正常：每帧都有新样本 ⇒ 几乎不重复 ⇒ 档 0、rep_long=0 
  //     · 故障：构造器供不上 ⇒ sample_left/right 长期不变 ⇒ 每帧锁到同一个值
  //       ⇒ same_frames 递增 ⇒ 档 3 / rep_long=1 
  //   ⚠️ 注意：音乐里的【静音段/极安静段】本身样本就相同 ⇒ 也会显示重复 
  //      ⇒ 请在有声音的段落读，并用"好/坏对照"判读（本会话已确立的方法 ）
  //   影响：只读  不进功能表达式 
  //========================================================================
  output reg [1:0] dbg_rep_grade,  // 粘滞最大档：0=从不重复 1=2~3帧 2=4~15 3=≥16
  output reg dbg_rep_long,  // 曾连续 ≥16 帧锁到相同样本对 
  output reg [3:0] dbg_same_frames,  // 当前连续相同帧数（截 4 位 ）
  //=== [Design note] ===================================
  // "反复播同一帧"的【活计数版】（父 agent 指定 ，与今天教训一致 ）
  //   今天的教训：粘滞位测不了"事件停止"（组7/8/9 三个粘滞/档位仪器都分辨不出好坏 ）
  //   ⇒ 改为【每 1024 帧一个窗口】统计"最近 N 帧里有多少帧【发生了变化】"
  //      好态：几乎每帧都变 ⇒ 计数 ≈ 1024 ⇒ 档 3 
  //      坏态（输出冻住/反复播同一帧 ）：几乎没有帧变化 ⇒ 计数 ≈ 0 ⇒ 档 0 
  //   为何用"变化帧数"而不是"不同样本个数"：前者只需 1 次比较/帧  逻辑最省且同样决定 
  //   影响：只读  不进功能表达式 
  //========================================================================
  output reg  [1:0]  dbg_chg_grade,      // 活档：3=≈全变 2=多数变 1=少数变 0=几乎不变(冻住 )
  output reg [11:0] dbg_chg_cnt,  // 上一窗口"发生变化"的帧数（供人工核对 ）
  output reg dbg_chg_last,  // 最近一帧是否变化（非粘滞  静止时也能读)
  //=== [Design note] =====================================
  // 组12：供数率活计数（组11 的镜像 ）
  //   组11 已证实：坏态【输出冻住】（每 1024 帧变化数 = 0 ）
  //   ⇒ 本组回答"是【供不上】还是【没取走】"：
  //      ① 每 1024 帧窗口里收到多少个 sample_valid  好态 ≈1024；坏态若 ≈0 ⇒ 供数停了
  //      ② 同窗口里多少个 sample_req 
  //      ③ req_held 的"最长连续为高拍数"档（活计数型  不用粘滞位 ）
  //         —— fix13 是"保持到被确认"；若某次确认丢了 ⇒ 它一直举着 ⇒ 后续请求全停 
  //   影响：只读  不进功能表达式 
  //   窗口与组11 完全对齐（同一个 1024 帧窗口 ）⇒ 三个计数可直接互相印证 
  //========================================================================
  output reg [1:0] dbg_vld_grade,  // 3=≈每帧 1 个 2=偏少 1=很少 0=供数停了
  output reg [1:0] dbg_req_grade,  // 同上，针对 sample_req
  output reg  [1:0]  dbg_held_grade,     // req_held 最长连续为高：0=<8拍 1=8~63 2=64~511 3=≥512
  output reg [11:0] dbg_vld_cnt,  // 上一窗口 sample_valid 计数（供人工核对 ）
  output reg [11:0] dbg_req_cnt,  // 上一窗口 sample_req 计数
  //=== [Design note] ========================================
  // 组13：把最后两种可能分开（父 agent 指定 ）
  //   背景：组11 = 坏态"输出冻住"；组12 = 两态都是 `330400` ⇒ 供给链完全健康
  //        ⇒ 判读表落在【取用/锁存侧】
  //   本组测【输入端】：
  //     ① `dbg_in_chg_grade`/`dbg_in_chg_cnt`：每 1024 帧窗口里
  //        `sample_left/right` 相对【上一拍】发生了多少次变化
  //        好态 ≈ 每次新样本到就变（应明显非 0 ）；坏态 ≈0 ⇒ 输入端本身就冻 
  //     ② `dbg_lat_grade`/`dbg_lat_cnt`：同窗口里【帧边界锁存脉冲】的次数 
  //        应 ≈1024 ⇒ 证明"锁存动作本身"每帧都在发生 （把"没锁存"排除 ）
  //     ③ `dbg_chg_last`（已在 #fix27 ）：锁存那一拍采到的值是否与上次相同 
  //   影响：只读  不进功能表达式 
  //========================================================================
  output reg [1:0] dbg_in_chg_grade,  // 3=输入活跃 2/1=偏少 0=输入端冻住
  output reg [1:0] dbg_lat_grade,  // 3=锁存脉冲≈1024（每帧都锁 ） 0=几乎没锁 
  output reg [11:0] dbg_in_chg_cnt,  // 上一窗口输入变化次数（供人工核对 ）
  output reg [11:0] dbg_lat_cnt  // 上一窗口锁存脉冲次数 
);

  reg [5:0] bit_cnt;  // 0..63
  reg       req_held;  // [Design note]1 = 本帧请求还举着（等 sample_valid 才放 ）
  // [Design note]观测（只读 ）
  assign dbg_req_held = req_held;
  // [Design note]真停摆判据：req_held 连续 >2000 拍没被 ack 
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

  //==== [Design note]"反复播同一帧"直接测量（只读 ；口径见头注 ）====
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

  //==== [Design note]活计数版"输出是否冻住"（只读 ；口径见头注 ）====
  //   放在模块最末 ⇒ 保证 prev_lat_l/prev_lat_r/latch_now 都已声明 （"先用后声明"会被闸门拦 ）
  localparam integer CHG_WIN = 1024;  // 窗口帧数（1024 帧 ≈ 21ms @48k  够快看清 ）
  reg [10:0] chg_win_f;  // 窗口内已计帧数
  reg [11:0] chg_win_c;  // 窗口内"发生变化"的帧数
  // [Design note] 供数率计数（与 #fix27 同一个窗口  放进同一个 always 块 ⇒ 共用同一 strobe ）
  reg [11:0] sup_vld_c, sup_req_c;
  reg [15:0] held_run, held_max;
  // [Design note] 组13：输入端活动 + 锁存脉冲计数
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
      // [Design note] 每拍计数（sample_valid/sample_req 是音频域脉冲  与 clk 同域 ）
      if (sample_valid) sup_vld_c <= sup_vld_c + 12'd1;
      if (sample_req) sup_req_c <= sup_req_c + 12'd1;
      if (req_held) begin
        if (held_run < 16'hFFFF) held_run <= held_run + 16'd1;
        if ((held_run + 16'd1) > held_max) held_max <= held_run + 16'd1;
      end else held_run <= 16'd0;
      // [Design note] 输入端每拍变化计数（首拍用 in_seen 门控 ）
      if (in_seen && ((sample_left !== prev_in_l) || (sample_right !== prev_in_r)))
        in_chg_c <= in_chg_c + 12'd1;
      in_seen   <= 1'b1;
      prev_in_l <= sample_left;
      prev_in_r <= sample_right;
      // [Design note] 下面 if (latch_now) 嵌在 else 内 （外层 end 移到尾部 ）
      if (latch_now) begin
        if (lat_c < 12'hFFF)
          lat_c <= lat_c + 12'd1;  // [Design note] 锁存脉冲计数（放在窗口块内 ）
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
          // [Design note] 窗口结束 ⇒ 供数率计数落地并清零 
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
          // [Design note] 组13 落地 
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
    end  // [Design note] 关闭 else 
  end

endmodule
