module keypad_scan #(
  parameter SCAN_CYCLES   = 100,    // 列采样窗口 (100 @100MHz = 1us)
  parameter SETTLE_CYCLES = 100,    // 行线建立时间 (1us)
  parameter STABLE_FRAMES = 3,      // 连续一致帧数（消抖）
  // 连按参数的单位是"帧"，不是时钟！一帧 = 4 行 x (建立+采样)。
  // 默认参数下一帧约 8us，所以 3000 帧 ≈ 24ms 的首次延迟。
  // 注意：这两个值必须放得进 16 位（计数器是 16 位，为了缩短加法器）。
  parameter HOLD_INIT     = 3_000,  // 按住多少帧后开始连按
  parameter REPEAT_FRAMES = 500     // 之后每多少帧连按一次
) (
  input  wire        clk,
  input  wire        rst_n,
  input  wire [ 3:0] col,          // 列输入（上拉，按下读 0）
  output reg  [ 3:0] row,          // 行输出（one-hot 低有效，空闲全高）
  output reg  [ 3:0] key_code,     // 0..15 当前键码（仅在受理时更新）
  output reg         key_press,    // 1 拍脉冲，每个"新按键/连按"一次
  // ---- 自检/调试输出（clk 域）----
  output reg  [15:0] raw_image,    // 上一完整帧的 16 键位图
  output reg  [ 1:0] row_now,      // 当前正在驱动的行号
  output reg  [ 3:0] col_now,      // 当前采样的原始列读数
  output reg  [15:0] frame_cnt,    // 帧计数（证明扫描器还活着）
  // ---- 最近一次"按下"事件的锁存值 ----
  // row_now/col_now 刷新太快（每微秒一变），OSD 上根本读不出来，
  // 所以单独锁存按键瞬间的行/列，方便直接读出"这个键接在哪一行哪一列"。
  output reg  [ 1:0] hit_row_lat,
  output reg  [ 3:0] hit_col_lat,
  output reg  [ 3:0] hit_key_lat
);

  // 4x4 薄膜键盘：row0..row3 依次拉低
  localparam [3:0] ROW0 = 4'b1110;
  localparam [3:0] ROW1 = 4'b1101;
  localparam [3:0] ROW2 = 4'b1011;
  localparam [3:0] ROW3 = 4'b0111;

  reg [1:0] st;  // 0=SETTLE 1=SCAN
  reg [1:0] row_idx;
  reg [3:0] col_s1, col_s2;  // 列线两级同步
  reg  [15:0] img_build;  // 本帧正在组装的位图
  reg  [15:0] img_last;  // 上一完整帧位图
  reg  [15:0] img_prev2;  // 再上一帧位图（用于比较，见下）
  reg  [ 2:0] stable_cnt;  // 连续一致帧数
  // 用 16 位计数器（不是 32 位）：加法器每多一位就多一级进位链，
  // 32 位递增器在 100MHz 下本身就接近极限，16 位留足余量。
  reg  [15:0] hold_cnt;  // 按住帧计数（到 HOLD_INIT 后启动连按）
  reg  [15:0] rep_cnt;  // 连按间隔计数（到 REPEAT_FRAMES 触发一次）
  reg         busy;  // 1 = 已受理某键，等待松开
  reg  [18:0] wait_cnt;

  wire [ 3:0] col_sync = col_s2;

  // 列线同步（慢速 GPIO，两级足够）
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_s1 <= 4'hF;
      col_s2 <= 4'hF;
    end else begin
      col_s1 <= col;
      col_s2 <= col_s1;
    end
  end

  // ---------------------------------------------------------------
  // 把本行的列读数转成"本行 4 个键的闭合掩码"
  // 关键：必须逐位判断，不能写成 ~col_sync 后整段塞进 4 位域。
  // 因为未按下的列读数是 1，整段取反会把"空闲的高电平"变成
  // 3 个幻影按键（例如 col 恒低=0100 时 ~col=1011，会在这一行
  // 凭空多出 3 个键）。逐位判断则只承认真正为 0 的那一列。
  // ---------------------------------------------------------------
  reg [3:0] hit;
  always @(*) begin
    hit[0] = ~col_sync[0];
    hit[1] = ~col_sync[1];
    hit[2] = ~col_sync[2];
    hit[3] = ~col_sync[3];
  end

  // (row, col) -> key code
  function [3:0] key_lookup;
    input [1:0] r;
    input [1:0] c;
    begin
      case ({
        r, c
      })
        4'b0000: key_lookup = 4'd1;
        4'b0001: key_lookup = 4'd2;
        4'b0010: key_lookup = 4'd3;
        4'b0011: key_lookup = 4'd10;  // A
        4'b0100: key_lookup = 4'd4;
        4'b0101: key_lookup = 4'd5;
        4'b0110: key_lookup = 4'd6;
        4'b0111: key_lookup = 4'd11;  // B
        4'b1000: key_lookup = 4'd7;
        4'b1001: key_lookup = 4'd8;
        4'b1010: key_lookup = 4'd9;
        4'b1011: key_lookup = 4'd12;  // C
        4'b1100: key_lookup = 4'd14;  // *
        4'b1101: key_lookup = 4'd0;
        4'b1110: key_lookup = 4'd15;  // #
        4'b1111: key_lookup = 4'd13;  // D
        default: key_lookup = 4'd0;
      endcase
    end
  endfunction

  // 从位图取第一个闭合键的索引 {row,col}，没读到则返回 4'hF（哨兵）
  function [3:0] pick_idx;
    input [15:0] img;
    integer k;
    begin
      pick_idx = 4'hF;
      for (k = 15; k >= 0; k = k - 1) if (img[k]) pick_idx = k[3:0];
    end
  endfunction

  wire [3:0] new_idx = pick_idx(img_last);

  // 本帧扫描结束（位图刚好组装完成的那一拍，用组合逻辑避免滞后一拍）
  wire       frame_done = (st == 2'd1) && (wait_cnt >= SCAN_CYCLES[18:0]) && (row_idx == 2'd3);
  // img_last / stable_cnt 都在 frame_done 那一拍更新，所以下面全部采用
  // "上一帧 vs 上上帧" 的结论，判断不会相对计数早一拍或晚一拍：
  //   click         : 最近两帧完全一致（最近一次比较刚刚相等）
  //   stable_enough : 加上本拍还会 +1，正好达到 STABLE_FRAMES
  //   release_stable: 连续两帧都是空图（松手已确认）
  wire       click = (img_last == img_prev2);
  wire       stable_enough = click && (stable_cnt >= (STABLE_FRAMES[2:0] - 3'd1));
  wire       release_stable = click && (img_last == 16'd0);

  // ---------------------------------------------------------------
  // 扫描 + 表决：SETTLE -> SCAN 交替，每帧 4 行。
  // 没有任何"等待释放"的阻塞路径，位图无论多脏都会继续下一帧。
  // 注意：img_build 只在本块里赋值（单一驱动源）。
  // ---------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row        <= 4'hF;
      row_idx    <= 2'd0;
      st         <= 2'd0;
      wait_cnt   <= 19'd0;
      img_build  <= 16'd0;
      img_last   <= 16'd0;
      img_prev2  <= 16'd0;
      row_now    <= 2'd0;
      col_now    <= 4'hF;
      frame_cnt  <= 16'd0;
      stable_cnt <= 3'd0;
    end else begin
      case (st)
        // ---- 行线建立 ----
        2'd0: begin
          case (row_idx)
            2'd0: row <= ROW0;
            2'd1: row <= ROW1;
            2'd2: row <= ROW2;
            2'd3: row <= ROW3;
          endcase
          row_now <= row_idx;
          if (wait_cnt >= SETTLE_CYCLES[18:0]) begin
            wait_cnt <= 19'd0;
            st       <= 2'd1;
          end else begin
            wait_cnt <= wait_cnt + 19'd1;
          end
        end
        // ---- 采样列 + 组装位图 ----
        2'd1: begin
          col_now <= col_sync;
          case (row_idx)
            2'd0:    img_build[3:0]   <= hit;
            2'd1:    img_build[7:4]   <= hit;
            2'd2:    img_build[11:8]  <= hit;
            default: img_build[15:12] <= hit;
          endcase

          if (wait_cnt >= SCAN_CYCLES[18:0]) begin
            wait_cnt <= 19'd0;
            st       <= 2'd0;  // 下一行先建立，再采样
            if (row_idx == 2'd3) begin
              // 第 4 行采完 = 一帧结束：锁存位图 + 帧表决
              raw_image <= img_build;
              frame_cnt <= frame_cnt + 16'd1;
              if (img_build == img_last) begin
                if (stable_cnt != 3'd7) stable_cnt <= stable_cnt + 3'd1;
              end else begin
                stable_cnt <= 3'd0;
              end
              img_prev2 <= img_last;
              img_last  <= img_build;
              img_build <= 16'd0;  // 新一帧从 0 开始组装
              row_idx   <= 2'd0;
            end else begin
              row_idx <= row_idx + 2'd1;
            end
          end else begin
            wait_cnt <= wait_cnt + 19'd1;
          end
        end
        default: st <= 2'd0;
      endcase
    end
  end

  // ---------------------------------------------------------------
  // 事件输出：按下受理 / 连按 / 松开
  // 所有判断都用 "上一帧 vs 上上帧" 的结论（click / release_stable），
  // 与 stable_cnt 的更新严格同拍，不受采样时机影响。
  // ---------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      key_code    <= 4'd0;
      key_press   <= 1'b0;
      hold_cnt    <= 16'd0;
      rep_cnt     <= 16'd0;
      busy        <= 1'b0;
      hit_row_lat <= 2'd0;
      hit_col_lat <= 4'h0;
      hit_key_lat <= 4'd0;
    end else begin
      key_press <= 1'b0;

      if (frame_done) begin
        if (!busy) begin
          hold_cnt <= 16'd0;
          rep_cnt  <= 16'd0;
          // 最近两帧一致，且该图非空、且已稳定足够帧数
          if (click && (img_last != 16'd0) && stable_enough) begin
            key_code    <= key_lookup(new_idx[3:2], new_idx[1:0]);
            key_press   <= 1'b1;
            busy        <= 1'b1;
            // 锁存本次按键的原始行列，供 OSD 直接读数
            hit_row_lat <= new_idx[3:2];
            hit_col_lat <= {2'b00, new_idx[1:0]};
            hit_key_lat <= key_lookup(new_idx[3:2], new_idx[1:0]);
          end
        end else if (release_stable) begin
          // 连续两帧都读不到任何键 = 确认松手，可再次触发
          busy     <= 1'b0;
          hold_cnt <= 16'd0;
          rep_cnt  <= 16'd0;
        end else begin
          // 连按：两个简单递增计数器，绝不用取模！
          // 这一步是修掉最差时序路径的关键（见文件头说明）。
          if (hold_cnt < HOLD_INIT[15:0]) begin
            hold_cnt <= hold_cnt + 16'd1;
          end else if (rep_cnt >= REPEAT_FRAMES[15:0]) begin
            rep_cnt   <= 16'd0;
            key_code  <= key_lookup(new_idx[3:2], new_idx[1:0]);
            key_press <= 1'b1;
          end else begin
            rep_cnt <= rep_cnt + 16'd1;
          end
        end
      end
    end
  end

endmodule
